defmodule Atanor.Cell do
  @moduledoc """
  Cells addressed by `{namespace, key}` (design §4.1).

  The Alambique cell id is `<namespace>.<key>`. A namespace matches
  `[a-z0-9_-]+`; the key follows the placement's id rule. Alambique applies
  the namespace's migrations when the cell wakes (`Atanor.Migrations`), so a
  call on an awake cell is one Alambique call.
  """

  alias Atanor.{Admission, Detector, Dispatch, HotCells, Partition, Registry, Takeover, Unavailable}

  @type address :: {namespace :: String.t(), key :: String.t()}

  @doc "Whether `namespace` is a valid namespace."
  @spec validate_namespace(term) :: :ok | {:error, :invalid_namespace}
  def validate_namespace(ns) when is_binary(ns) and ns != "",
    do: if(namespace?(ns), do: :ok, else: {:error, :invalid_namespace})

  def validate_namespace(_), do: {:error, :invalid_namespace}

  # A byte loop: a regex literal is imported again at each use on OTP 28.
  defp namespace?(<<c, rest::binary>>) when c in ?a..?z or c in ?0..?9 or c in [?_, ?-], do: namespace?(rest)
  defp namespace?(rest), do: rest == ""

  @doc "The Alambique cell id of an address."
  @spec id(address) :: {:ok, String.t()} | {:error, :invalid_namespace | :invalid_key}
  def id({ns, key}) do
    with :ok <- validate_namespace(ns), :ok <- validate_key(key), do: {:ok, ns <> "." <> key}
  end

  def id(_), do: {:error, :invalid_address}

  @doc "The address of an Alambique cell id."
  @spec parse(String.t()) :: {:ok, address} | {:error, :invalid_cell_id}
  def parse(id) when is_binary(id) do
    with [ns, key] <- String.split(id, ".", parts: 2),
         {:ok, ^id} <- id({ns, key}) do
      {:ok, {ns, key}}
    else
      _ -> {:error, :invalid_cell_id}
    end
  end

  @doc """
  Runs a read statement. See `Alambique.query/5`. Pass `verify_lease: true` for
  a read that must not be stale: after a takeover the old owner can answer for a
  short time (design §8.12).
  """
  def query(instance, address, sql, params \\ [], opts \\ []),
    do: call(instance, address, :read, &Alambique.query(&1, &2, sql, params, opts))

  @doc "Runs a write statement. See `Alambique.execute/5`."
  def execute(instance, address, sql, params \\ [], opts \\ []),
    do: call(instance, address, :write, &Alambique.execute(&1, &2, sql, params, opts))

  @doc "Runs `fun` in one transaction. See `Alambique.transaction/4`."
  def transaction(instance, address, fun, opts \\ []),
    do: call(instance, address, :write, &Alambique.transaction(&1, &2, fun, opts))

  @doc """
  Replaces the cell with its state at `target`. See `Alambique.rewind/4`. Design
  §15.10.
  """
  def rewind(instance, address, target, opts \\ []),
    do: call(instance, address, :admin, &Alambique.rewind(&1, &2, target, opts))

  @doc """
  Where the cell's replicated chain ends. See `Alambique.position/3`.
  """
  def position(instance, address, opts \\ []),
    do: call(instance, address, :admin, &Alambique.position(&1, &2, opts))

  @doc """
  Turns the read replicas of a cell on or off in the whole cluster, or reads the switch without waking the
  cell. See `Alambique.replicas/3`. The instance needs `alambique: [replicas: []]`. Design §19.
  """
  @spec replicas(atom, address, boolean) :: :ok | {:error, term}
  def replicas(instance, address, on?) when is_boolean(on?) do
    with {:ok, id} <- id(address), do: Alambique.replicas(Registry.config(instance).alambique, id, on?)
  end

  @spec replicas(atom, address) :: {:ok, boolean} | {:error, term}
  def replicas(instance, address) do
    with {:ok, id} <- id(address), do: Alambique.replicas(Registry.config(instance).alambique, id)
  end

  @doc """
  The node that serves the cell, waking the cell where a call would. See
  `Alambique.touch/3`. Design §8.
  """
  @spec owner(atom, address) :: {:ok, node} | {:error, term}
  def owner(instance, address) do
    with {:ok, id} <- id(address) do
      config = Registry.config(instance)

      with :ok <- wake_gate(instance, config, id) do
        if config.hot_cells.enabled, do: HotCells.hold(instance, id, config.hot_cells.move_timeout_ms)
        Alambique.touch(config.alambique, id)
      end
    end
  end

  # While the node is over its memory mark, a call for a cell that no member holds awake would wake it:
  # it gets `overloaded` instead. A cell awake here or on another node is served or forwarded.
  # `owner/3` with `peers: true` asks the members' registries, never the store, and never wakes a cell.
  defp wake_gate(instance, config, id) do
    if Admission.memory_refusing?(instance) and not match?({:ok, _}, Alambique.owner(config.alambique, id, peers: true)) do
      Admission.refuse_wake(instance)
      unavailable(:overloaded)
    else
      :ok
    end
  end

  # A call waits while its cell moves (design §8.15), then counts for the placement of hot cells.
  defp hot_cells(instance, config, id, kind) do
    HotCells.hold(instance, id, config.hot_cells.move_timeout_ms)
    HotCells.count(instance, id, kind)
  end

  @doc "Puts the cell to sleep. See `Alambique.hibernate/3`."
  def hibernate(instance, address, opts \\ []),
    do: call(instance, address, :admin, &Alambique.hibernate(&1, &2, opts))

  @doc """
  Moves the cell to `node`: its owner hibernates it and `node` wakes it. See `Alambique.move/4`. Use
  `Atanor.HotCells.move/4`, which also tells the other nodes (design §8.15).
  """
  @spec move(atom, address, node, keyword) :: {:ok, node} | {:error, term}
  def move(instance, address, node, opts \\ []),
    do: call(instance, address, :admin, &Alambique.move(&1, &2, node, opts))

  # A call whose owner is a node confirmed down takes the cell over and runs
  # again, here (design §8.10). A wake that lost a takeover race on this node
  # answers `epoch_changed` or `contended` to the calls waiting for it; they did
  # not run, so they are repeated.
  # Reads and writes are counted for the placement of hot cells (design §8.15).
  @unknown {__MODULE__, :unknown_outcome}
  @wrote {__MODULE__, :wrote}

  defp call(instance, address, kind, fun) do
    with {:ok, id} <- id(address), :ok <- granted(instance, address) do
      config = Registry.config(instance)
      # An admin call (hibernate, move, position) is how a node sheds cells: it is not gated.
      with :ok <- if(kind == :admin, do: :ok, else: wake_gate(instance, config, id)) do
        if config.hot_cells.enabled and kind != :admin, do: hot_cells(instance, config, id, kind)
        instance |> run(id, fun, config.takeover.attempts, nil) |> wrote(kind)
      end
    end
  end

  # A handler that had a write acknowledged has part of its effect durable: a later refusal of
  # another call says the call did not run, which is no longer true of the handler, so it is unknown.
  defp wrote({:ok, _} = result, :write) do
    Process.put(@wrote, true)
    result
  end

  defp wrote({:error, _} = error, _kind) do
    if Process.get(@wrote) && Unavailable.from_error(error), do: Process.put(@unknown, true)
    error
  end

  defp wrote(result, _kind), do: result

  @unavailable {__MODULE__, :unavailable_reason}

  @doc false
  # Whether a cell write of the calling process answered `:outcome_unknown` since `clear_unknown/0`.
  def unknown_outcome?, do: Process.get(@unknown, false)

  @doc false
  def clear_unknown do
    Process.delete(@wrote)
    Process.delete(@unknown)
  end

  @doc false
  # Records the availability reason of a failed cell call for `Atanor.Dispatch`.
  def mark_unavailable(reason) when is_atom(reason), do: Process.put(@unavailable, reason)

  @doc false
  # The availability reason of the last failed cell call since `clear_unavailable/0`.
  def unavailable_reason, do: Process.get(@unavailable)

  @doc false
  def clear_unavailable, do: Process.delete(@unavailable)

  @handler {__MODULE__, :handler_deadline}

  @doc false
  # Marks the calling process as running a handler until `end_handler/1`, with the time it has left
  # (`:infinity` when it has no deadline of its own). A cell call from a handler waits for an owner that
  # leaves, like one that `Atanor.Dispatch` routes (design §8.11). Returns what `end_handler/1` restores.
  def begin_handler(left_ms \\ :infinity) do
    previous = Process.get(@handler)
    deadline = if left_ms == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + left_ms
    # Numbers sort before `:infinity`.
    Process.put(@handler, if(previous == nil, do: deadline, else: min(previous, deadline)))
    previous
  end

  @doc false
  def end_handler(nil), do: Process.delete(@handler)
  def end_handler(previous), do: Process.put(@handler, previous)

  @doc false
  # Whether an answer to a cell call says the call did not run because its owner is leaving or has stopped:
  # `:draining` (the router refused it) or `:stopped` (a stopped Alambique instance failed before it looked at
  # the call). `nil` for any other answer.
  def refusal({:error, :draining}), do: :draining
  def refusal({:error, {:forward_failed, {:error, reason}}}), do: stopped(reason)
  def refusal(_), do: nil

  # What Alambique f3aa20c still raises, as `ArgumentError`/`badarg`, for a call that did not run:
  # * `ets:lookup` of the admission table that a stopping instance deletes, the first thing a wake does
  #   (`Config.delete/1` is covered by Alambique, deleting the table alone is not);
  # * the caller's own `Router.erpc/3`, which reads the config of its instance before it sends.
  defp stopped({:exception, :badarg, [{:ets, :lookup, [table, {:failed, _}], _} | _]}) when is_atom(table),
    do: if(String.ends_with?(Atom.to_string(table), ".Admission"), do: :stopped)

  defp stopped(%ArgumentError{message: "no Alambique instance named " <> _}), do: :stopped
  defp stopped(_), do: nil

  # A refused call waits for the handoff while the handler has time and `routing.leave_wait_ms` lasts. A
  # router that is draining says so itself; a stopped instance counts only while a node announced that it
  # leaves, as in `Atanor.Dispatch`.
  defp refused(instance, id, fun, until, result, kind) do
    if Process.get(@handler) != nil and (kind == :draining or Detector.any_left?(instance)) do
      Dispatch.wait(instance, true, 2, until, fn attempts, until ->
        if attempts <= 1 or past_deadline?() do
          unrun(instance, result)
        else
          Process.sleep(Registry.config(instance).routing.retry_ms)
          run(instance, id, fun, Registry.config(instance).takeover.attempts, until)
        end
      end)
    else
      unrun(instance, result)
    end
  end

  defp past_deadline? do
    case Process.get(@handler) do
      deadline when is_integer(deadline) -> System.monotonic_time(:millisecond) >= deadline
      _ -> false
    end
  end

  # The call did not run: the router's own answer stays as it is, a stopped instance is a draining owner.
  defp unrun(instance, {:error, :draining} = result), do: note_outcome(instance, result)
  defp unrun(_instance, _result), do: unavailable(:owner_down)

  defp run(instance, id, fun, attempts, until) do
    alambique = Registry.config(instance).alambique

    case fun.(alambique, id) do
      {:error, {:unavailable, owner, _}} ->
        case Takeover.recover(instance, id, owner) do
          {:ok, _} -> note_outcome(instance, fun.(alambique, id))
          :stale -> note_outcome(instance, fun.(alambique, id))
          :no_quorum -> unavailable(:no_quorum)
          {:error, reason} -> unavailable(Unavailable.reason(reason) || :owner_unreachable)
        end

      {:error, {:epoch_changed, _}} when attempts > 1 ->
        run(instance, id, fun, attempts - 1, until)

      {:error, {:contended, _, _}} when attempts > 1 ->
        run(instance, id, fun, attempts - 1, until)

      {:error, :outcome_unknown} = unknown ->
        Process.put(@unknown, true)
        unknown

      other ->
        case refusal(other) do
          nil ->
            note_outcome(instance, other)
            other

          kind ->
            refused(instance, id, fun, until, other, kind)
        end
    end
  end

  defp unavailable(reason) do
    Process.put(@unavailable, reason)
    {:error, {:unavailable, reason}}
  end

  defp note_outcome(_instance, {:error, :outcome_unknown} = unknown) do
    Process.put(@unknown, true)
    unknown
  end

  # An upload that failed stopped the cell: the batch may have reached the store (Alambique design §8).
  defp note_outcome(_instance, {:error, {:sync_failed, _}} = unknown) do
    Process.put(@unknown, true)
    unknown
  end

  # A call refused because a node of another store is in the cluster is a configuration error,
  # not unavailability. The worker may map it to anything; the ingress still names it (design §8.4).
  defp note_outcome(instance, {:error, {:foreign_store, node}} = error) do
    Unavailable.foreign_store(instance, node)
    Process.put(@unavailable, {:foreign_store, node})
    error
  end

  defp note_outcome(_instance, error) do
    if reason = Unavailable.from_error(error), do: Process.put(@unavailable, reason)
    error
  end

  defp granted(instance, {ns, _} = address) do
    case Registry.namespace(instance, ns) do
      {:ok, _} -> partitioned(instance, address)
      :error -> {:error, {:unknown_namespace, ns}}
    end
  end

  @doc """
  Whether `address` can be used in its namespace: always in one that is not
  partitioned; in a partitioned one only the physical keys of its partitions
  (`{:error, {:partition_required, namespace}}` otherwise, design §4.2).
  """
  @spec partitioned(atom, address) :: :ok | {:error, {:partition_required, String.t()}}
  def partitioned(instance, {ns, key}) do
    case Registry.partitions(instance, ns) do
      nil -> :ok
      n -> if Partition.physical?(key, n), do: :ok, else: {:error, {:partition_required, ns}}
    end
  end

  defp validate_key(key) when is_binary(key) and key != "",
    do: if(String.contains?(key, ["/", <<0>>]), do: {:error, :invalid_key}, else: :ok)

  defp validate_key(_), do: {:error, :invalid_key}
end
