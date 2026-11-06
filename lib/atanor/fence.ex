defmodule Atanor.Fence do
  @moduledoc false
  # Stops a handler that can outlive its node's lease on the cell (design §8.13, §15.11).
  #
  # The node remembers, per cell, the epoch and expiry of its own lease from the last successful
  # `Alambique.lease/3` read. Renewals only extend the expiry and a takeover changes the owner or the
  # epoch, so the remembered expiry is a lower bound. A handler that cannot learn more is killed, without
  # its cooperation, at `expires_at_ms - skew_margin_ms` on the clock Alambique uses: another node takes the
  # cell only after `expires_at_ms + skew_margin_ms` on its own clock, so with clock skew below the margin
  # the handlers of the two nodes do not overlap. A read that shows another owner or epoch kills it at once.
  #
  # A successful `verify_lease` query is not used: it proves the lease valid when it ran, not until when.
  #
  # The other half is on the node that takes a cell over before the lease ends (the detector's early takeover):
  # it starts no job or alarm handler for the cell until the previous lease's `expires_at_ms + skew_margin_ms`
  # on its own clock, the instant the old owner's fence is over by (`hold/4`, `held?/2`).

  alias Atanor.{Cell, Config, Env, Registry}

  @type reason :: :lost | :local_deadline | :unreadable | :stopped

  @doc """
  Runs `work` (a handler of `kind`, `:job` or `:alarm`, for `cell`) in a task and returns its result, or
  `{:error, :handler_fenced}` when the task was killed or could not start. Emits `[:atanor, :handler, :fenced]`.
  """
  @spec run(Env.t(), atom, Cell.address(), (-> result)) :: result | {:error, :handler_fenced} when result: term
  def run(%Env{instance: instance} = env, kind, cell, work) do
    config = Registry.config(instance)

    if config.routing.fence do
      {:ok, id} = Cell.id(cell)

      case tenure(instance, config, id) do
        {:ok, epoch, deadline} ->
          watch(Task.async(work), %{
            instance: instance,
            config: config,
            id: id,
            epoch: epoch,
            deadline: deadline,
            meta: %{worker: Env.worker(env), cell: cell, kind: kind}
          })

        :error ->
          fenced(instance, %{worker: Env.worker(env), cell: cell, kind: kind}, :unreadable)
      end
    else
      work.()
    end
  end

  @doc """
  Called by the node that took cell `id` over from the lease that expires at `expires_at_ms`: no job or
  alarm handler starts for the cell before `expires_at_ms + skew_margin_ms`.
  """
  @spec hold(Config.t(), String.t(), integer | nil) :: :ok
  def hold(%Config{} = config, id, expires_at_ms) do
    until = expires_at_ms && expires_at_ms + Config.skew_margin_ms(config)

    if config.routing.fence_defer_after_takeover and until != nil and until > now(config),
      do: Registry.fence_put_hold(config.name, id, until, now(config))

    :ok
  end

  @doc "Whether job and alarm handlers must not start for cell `id` yet. Runs where the claim is made: on the owner."
  @spec held?(atom, String.t()) :: boolean
  def held?(instance, id) do
    case Registry.fence_hold(instance, id) do
      nil ->
        false

      until ->
        held? = now(Registry.config(instance)) < until
        unless held?, do: Registry.fence_delete_hold(instance, id, until)
        held?
    end
  end

  # The epoch and the deadline of this node's lease: remembered, or read now.
  defp tenure(instance, config, id) do
    case Registry.fence_entry(instance, id) do
      {_, :owned, epoch, deadline, _} ->
        if now(config) < deadline, do: {:ok, epoch, deadline}, else: read_now(instance, config, id)

      _ ->
        read_now(instance, config, id)
    end
  end

  defp read_now(instance, config, id) do
    started = System.monotonic_time(:millisecond)

    with {:ok, lease} <- read(config, id) do
      record(instance, config, id, lease, started)

      case Registry.fence_entry(instance, id) do
        {_, :owned, epoch, deadline, _} -> if now(config) < deadline, do: {:ok, epoch, deadline}, else: :error
        _ -> :error
      end
    else
      {:error, _} -> :error
    end
  end

  # Waits for the handler until the deadline or the next read, whichever is first, so the bound does not
  # depend on the read interval.
  defp watch(task, f) do
    case step(task, f) do
      {:done, result} -> result
      {:cont, f} -> watch(task, f)
    end
  end

  defp step(task, f) do
    wait = max(0, min(f.deadline - now(f.config), until_read(f)))

    case Task.yield(task, wait) do
      {:ok, result} ->
        {:done, result}

      {:exit, reason} ->
        exit(reason)

      nil ->
        case observe(f) do
          {:kill, reason} -> {:done, kill(task, f, reason)}
          {:ok, f} -> {:cont, read_due(f)}
        end
    end
  rescue
    # The tables are gone: the instance is stopping, and the handler goes with it.
    ArgumentError -> {:done, kill(task, f, :stopped)}
  end

  defp observe(f) do
    case Registry.fence_entry(f.instance, f.id) do
      {_, _, epoch, _, _} when epoch > f.epoch -> {:kill, :lost}
      {_, :lost, epoch, _, _} when epoch == f.epoch -> {:kill, :lost}
      {_, :owned, epoch, deadline, _} when epoch == f.epoch -> expired(%{f | deadline: max(f.deadline, deadline)})
      _ -> expired(f)
    end
  end

  defp expired(f), do: if(now(f.config) >= f.deadline, do: {:kill, :local_deadline}, else: {:ok, f})

  defp kill(task, f, reason) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> fenced(f.instance, f.meta, reason, f.deadline)
    end
  end

  defp fenced(instance, meta, reason, deadline \\ nil) do
    :telemetry.execute(
      [:atanor, :handler, :fenced],
      %{count: 1},
      Map.merge(meta, %{instance: instance, reason: reason, deadline_ms: deadline, node: node()})
    )

    {:error, :handler_fenced}
  end

  defp until_read(f) do
    case Registry.fence_entry(f.instance, f.id) do
      {_, _, _, _, read_at} -> read_at + f.config.routing.fence_check_ms - System.monotonic_time(:millisecond)
      nil -> 0
    end
  end

  # Starts a read of the lease when the last one is older than `routing.fence_check_ms`. One watcher per
  # cell wins the right to read; the table is emptied at its limit, so a missing entry is put back first.
  defp read_due(f) do
    %{instance: instance, config: config, id: id} = f
    every = config.routing.fence_check_ms
    mono = System.monotonic_time(:millisecond)

    entry =
      Registry.fence_entry(instance, id) ||
        Registry.fence_put(instance, config.routing.owner_check_cells, {id, :owned, f.epoch, f.deadline, 0})

    with {_, _, _, _, read_at} <- entry,
         true <- mono - read_at >= every,
         true <- Registry.fence_touch(instance, id, read_at, mono) do
      Task.Supervisor.start_child(Atanor.Tasks.name(instance), fn -> refresh(instance, config, id) end)
    end

    f
  end

  @doc """
  Reads the lease of cell `id` in the background when the last read is three quarters of `routing.owner_check_ms`
  old, so that a busy cell's check finds a fresh read and does not stall the cell (design §8.13).
  """
  @spec refresh_ahead(atom, Config.t(), String.t()) :: :ok
  def refresh_ahead(instance, config, id) do
    routing = config.routing

    if Registry.claim_refresh(instance, id, div(routing.owner_check_ms * 3, 4), routing.owner_check_ms),
      do: Task.Supervisor.start_child(Atanor.Tasks.name(instance), fn -> refresh(instance, config, id) end)

    :ok
  end

  defp refresh(instance, config, id) do
    started = System.monotonic_time(:millisecond)
    with {:ok, lease} <- read(config, id), do: record(instance, config, id, lease, started)
  rescue
    # The tables are gone: the instance is stopping.
    ArgumentError -> :ok
  end

  # The read is bounded by the interval, so reads of one cell do not pile up.
  defp read(config, id), do: Alambique.lease(config.alambique, id, timeout: config.routing.fence_check_ms)

  # `started` is when the read began: the lease was true at some moment after it, so a slow read, or one that
  # straddles a takeover, never counts as fresher than it was asked for.
  defp record(instance, config, id, lease, started) do
    margin = Config.skew_margin_ms(config)

    case view(lease, margin) do
      nil ->
        :ok

      {status, epoch, deadline} ->
        # A read that shows this node as owner is also the fresh lease read that `Dispatch` wants within
        # `routing.owner_check_ms` before it starts a handler: it need not read the lease again (design §8.13).
        Registry.fence_merge(instance, config.routing.owner_check_cells, id, status, epoch, deadline, started)

        # Only while the table still says owned at that epoch: a late read of an older epoch proves nothing.
        with {_, :owned, ^epoch, _, _} <- Registry.fence_entry(instance, id),
             do: Registry.put_verified(instance, id, config.routing.owner_check_cells, started)
    end
  end

  # A released lease of this node says nothing about its expiry.
  defp view(%{owner: owner, released: true}, _margin) when owner == node(), do: nil

  defp view(%{owner: owner, moved_to: nil, epoch: epoch, expires_at_ms: expires}, margin) when owner == node(),
    do: {:owned, epoch, expires - margin}

  defp view(%{epoch: epoch}, _margin), do: {:lost, epoch, nil}

  defp now(config) do
    {clock, clock_config} = Config.lease_clock(config)
    clock.now_ms(clock_config)
  end
end
