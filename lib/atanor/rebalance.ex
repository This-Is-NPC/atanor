defmodule Atanor.Rebalance do
  @moduledoc """
  Moves awake cells to the node that now prefers them when the membership changes (design §8.1).

  The preferred node of a cell is rendezvous hashing over the members, and it decides only where a cell wakes.
  A cell that is awake stays on its node, and is forwarded there while it is called, so a node that joins would
  get nothing but new cells. Each node therefore looks, after a membership change, at the cells it serves and
  moves those whose preferred node is another one, with `Alambique.move/4` through `Atanor.HotCells.move/4`
  (which gates the callers while the cell moves).

  **A plan per membership.** A change of the members (the `[:alambique, :membership, :changed]` event), or of
  this node being ready, starts the wait of `start_delay_ms`; a change during the wait or the plan starts it
  again, so a node that joins and leaves quickly moves nothing. The plan lists the cells awake here whose
  preferred node is another, coldest first (`Alambique.cells/2`, `last_used`), and moves one at a time, at most
  `max_moves_per_s` a second.

  **What is left alone.** A move asks `only_if_idle`: a cell with a call in flight answers `{:error, :busy}`,
  goes back to the queue and, after a few tries, is left for the next round of the plan. A round runs five seconds after the last one ended,
  twelve at most, and the plan ends with the first round that finds nothing to move. A cell the plan handed out
  is never handed out again while the membership stays, so a cell that comes back, or whose move failed, is not
  chased: it keeps working where it is. The cells that `Atanor.HotCells.pinned/1` names, the hot ones and those that
  the loop moved within `residence_ms`, are not touched: the hot-cell loop wins, and a cell moved by pressure
  is not moved back. A rebalance move starts no residence time, so a cell that arrives by rebalance can move
  on in the next one. A target that the detector blocks is skipped.

  Moves are one at a time, so the cost to the callers is one cell paused at once.
  """
  use GenServer

  require Logger

  alias Atanor.{Cell, Detector, HotCells, Registry}
  alias Atanor.Rebalance.Plan

  # A round that left busy cells waits this long, and there are at most this many rounds.
  @round_ms 5_000
  @rounds 12
  @page 1_000
  @event [:alambique, :membership, :changed]

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: server(config.name)]]}}
  end

  defp server(name), do: Module.concat(name, Rebalance)

  @doc """
  What this node knows (`GET /runtime`): the phase (`idle`, `waiting`, `running`, `between_rounds`, `done`), the
  members, the time since they last changed, the cells still to move, those moved and failed in this plan, and
  the totals since start. `{:error, :disabled}` when the rebalance is off.
  """
  @spec status(atom) :: map | {:error, :disabled}
  def status(instance) do
    if GenServer.whereis(server(instance)), do: GenServer.call(server(instance), :status), else: {:error, :disabled}
  end

  @impl true
  def init(config) do
    cfg = config.rebalance
    Process.flag(:trap_exit, true)

    # Alambique does not emit the first view of the members, so they are read once, after the subscription
    # (a change in between only repeats the event).
    :telemetry.detach(handler(config.name))
    :ok = :telemetry.attach(handler(config.name), @event, &__MODULE__.forward/4, {self(), config.alambique})
    send(self(), :tick)

    {:ok,
     %{
       name: config.name,
       alambique: config.alambique,
       cfg: cfg,
       step_ms: div(1000, cfg.max_moves_per_s),
       key: nil,
       members: Alambique.members(config.alambique),
       epoch: 0,
       changed_at: now(),
       phase: :idle,
       plan: Plan.new(),
       rounds: 0,
       resume_at: nil,
       started_at: nil,
       in_flight: nil,
       moved: 0,
       failed: 0,
       total: %{moved: 0, failed: 0, plans: 0}
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.step_ms)
    {:noreply, state |> observe() |> advance()}
  rescue
    exception ->
      Logger.warning("atanor: rebalance failed: " <> Exception.message(exception))
      {:noreply, state}
  end

  def handle_info({:members, members}, state), do: {:noreply, %{state | members: members}}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: :telemetry.detach(handler(state.name))

  @doc false
  def forward(_event, _measurements, %{instance: instance, members: members}, {pid, instance}),
    do: send(pid, {:members, members})

  def forward(_event, _measurements, _metadata, _config), do: :ok

  defp handler(name), do: {__MODULE__, name}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, report(state), state}

  @impl true
  def handle_cast({:result, epoch, id, target, result, duration}, state) do
    ok? = match?({:ok, _}, result)

    :telemetry.execute([:atanor, :rebalance, :move], %{duration: duration}, %{
      instance: state.name,
      cell: id,
      from: node(),
      to: target,
      result: if(ok?, do: :ok, else: result)
    })

    state = %{state | in_flight: nil}
    current? = epoch == state.epoch

    # A cell with a call in flight stays: it goes back to the plan, and is no failure.
    case result do
      {:error, :busy} -> {:noreply, if(current?, do: %{state | plan: Plan.busy(state.plan, id)}, else: state)}
      _ -> {:noreply, state |> count_total(ok?) |> count(current?, ok?)}
    end
  end

  defp count_total(state, ok?), do: %{state | total: bump(state.total, ok?)}

  defp bump(counts, true), do: %{counts | moved: counts.moved + 1}
  defp bump(counts, false), do: %{counts | failed: counts.failed + 1}

  defp count(state, true, ok?), do: bump(state, ok?)
  defp count(state, false, _ok?), do: state

  # A change of the members, or of whether this node serves, makes a new plan that waits for the delay. The
  # members come from the membership event; whether the node serves is read here.
  defp observe(state) do
    active? = Registry.state(state.name) == :ready and node() in state.members
    key = {state.members, active?}
    if key == state.key, do: state, else: changed(state, key, active?)
  end

  defp changed(state, key, active?) do
    state = if state.phase in [:running, :between_rounds], do: stop(state, :membership_changed), else: state

    %{
      state
      | key: key,
        epoch: state.epoch + 1,
        changed_at: now(),
        phase: if(active?, do: :waiting, else: :idle),
        plan: Plan.new(),
        rounds: 0,
        resume_at: nil,
        moved: 0,
        failed: 0
    }
  end

  defp advance(%{phase: :waiting} = state) do
    if now() - state.changed_at >= state.cfg.start_delay_ms, do: start(state), else: state
  end

  defp advance(%{phase: :between_rounds} = state) do
    if state.in_flight == nil and now() >= state.resume_at, do: state |> next_round() |> settle(), else: state
  end

  defp advance(%{phase: :running, in_flight: nil} = state), do: step(state)
  defp advance(state), do: state

  defp start(state) do
    state = %{state | started_at: now(), total: %{state.total | plans: state.total.plans + 1}}
    state = next_round(state)

    :telemetry.execute([:atanor, :rebalance, :start], %{cells: Plan.pending(state.plan)}, meta(state))
    settle(state)
  end

  # A round with nothing to move ends the plan.
  defp settle(state), do: if(Plan.pending(state.plan) == 0, do: stop(%{state | phase: :done}, :done), else: state)

  defp next_round(state) do
    preferred = &Alambique.preferred(state.alambique, &1)
    plan = Plan.round(state.plan, entries(state.alambique), preferred, node(), HotCells.pinned(state.name))
    %{state | plan: plan, phase: :running, rounds: state.rounds + 1}
  end

  defp entries(instance) do
    nil
    |> Stream.unfold(fn
      :done ->
        nil

      after_id ->
        %{cells: cells, next: next} = Alambique.cells(instance, after: after_id, details: true, limit: @page)
        {Enum.map(cells, &{&1.id, &1.last_used}), next || :done}
    end)
    |> Enum.concat()
  end

  defp step(state) do
    pinned = HotCells.pinned(state.name)

    case Plan.next(state.plan, &check(state, pinned, &1)) do
      {{:move, id, target}, plan} ->
        start_move(state, id, target)
        %{state | plan: plan, in_flight: id}

      {:none, plan} ->
        state = %{state | plan: plan}
        if Plan.pending(plan) == 0, do: round_done(state), else: state
    end
  end

  # What a cell is now: it may have gone to sleep, been pinned, or be preferred here again. A call in flight is
  # not checked here: the move itself answers `{:error, :busy}` (`only_if_idle`).
  defp check(state, pinned, id) do
    target = Alambique.preferred(state.alambique, id)

    if MapSet.member?(pinned, id) or target == node() or Detector.blocked?(state.name, target),
      do: :stay,
      else: {:move, target}
  end

  # The next round finds what this one left (busy cells) or what came back, and ends the plan when it finds nothing.
  defp round_done(%{rounds: rounds} = state) when rounds < @rounds,
    do: %{state | phase: :between_rounds, resume_at: now() + @round_ms}

  defp round_done(state), do: stop(%{state | phase: :done}, :done)

  defp stop(state, reason) do
    :telemetry.execute(
      [:atanor, :rebalance, :stop],
      %{moved: state.moved, failed: state.failed, deferred: state.plan.deferred, duration: now() - state.started_at},
      Map.put(meta(state), :reason, reason)
    )

    state
  end

  defp meta(state), do: %{instance: state.name, node: node(), epoch: state.epoch, members: state.members}

  defp start_move(state, id, target) do
    instance = state.name
    epoch = state.epoch
    server = server(instance)
    {:ok, address} = Cell.parse(id)

    Task.Supervisor.start_child(Atanor.Tasks.name(instance), fn ->
      started = System.monotonic_time()

      result =
        try do
          HotCells.move(instance, address, target, :rebalance)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      duration = System.monotonic_time() - started
      GenServer.cast(server, {:result, epoch, id, target, result, duration})
    end)
  end

  defp report(state) do
    now = now()

    %{
      phase: state.phase,
      epoch: state.epoch,
      members: state.members,
      last_membership_change_ms: now - state.changed_at,
      starts_in_ms: if(state.phase == :waiting, do: max(state.cfg.start_delay_ms - (now - state.changed_at), 0)),
      pending: Plan.pending(state.plan),
      deferred: state.plan.deferred,
      moved: state.moved,
      failed: state.failed,
      rounds: state.rounds,
      moving: state.in_flight,
      total: state.total
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
