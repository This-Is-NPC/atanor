defmodule Atanor.Rebalance do
  @moduledoc """
  Moves awake cells to the node that now prefers them when the membership changes (design §8.1).

  The preferred node of a cell is rendezvous hashing over the members, and it decides only where a cell wakes.
  A cell that is awake stays on its node, and is forwarded there while it is called, so a node that joins would
  get nothing but new cells. Each node therefore looks, after a membership change, at the cells it serves and
  moves those whose preferred node is another one, with `Alambique.move/4` through `Atanor.HotCells.move/4`
  (which gates the callers while the cell moves).

  **A plan per membership.** A change of the members, or of this node being ready, starts the wait of
  `start_delay_ms`; a change during the wait or the plan starts it again, so a node that joins and leaves
  quickly moves nothing. The plan lists the cells awake here whose preferred node is another, coldest
  first (`Alambique.cells/2`, `last_used`), and moves one at a time, at most `max_moves_per_s` a second.

  **What is left alone.** A cell with a call in flight (`Alambique.load/2`, `pending`) waits a few steps and,
  if it stays busy, is left for the next round of the plan. A round runs five seconds after the last one ended,
  twelve at most, and the plan ends with the first round that finds nothing to move. A cell the plan handed out
  is never handed out again while the membership stays, so a cell that comes back, or whose move failed, is not
  chased: it keeps working where it is. The cells that `Atanor.HotCells.pinned/1` names, the hot ones and those that moved within
  `residence_ms`, are not touched: the hot-cell loop wins, and a cell moved by pressure or by a rebalance
  elsewhere is not moved back. A target that the detector blocks is skipped.

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

    send(self(), :tick)

    {:ok,
     %{
       name: config.name,
       alambique: config.alambique,
       cfg: cfg,
       step_ms: div(1000, cfg.max_moves_per_s),
       key: nil,
       members: [],
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

  def handle_info(_message, state), do: {:noreply, state}

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

    state = %{state | in_flight: nil, total: bump(state.total, ok?)}
    {:noreply, if(epoch == state.epoch, do: count(state, ok?), else: state)}
  end

  defp bump(total, true), do: %{total | moved: total.moved + 1}
  defp bump(total, false), do: %{total | failed: total.failed + 1}

  defp count(state, true), do: %{state | moved: state.moved + 1}
  defp count(state, false), do: %{state | failed: state.failed + 1}

  # A change of the members, or of whether this node serves, makes a new plan that waits for the delay.
  defp observe(state) do
    members = Alambique.Membership.nodes(Alambique.Config.fetch!(state.alambique))
    active? = Registry.state(state.name) == :ready and node() in members
    key = {members, active?}
    if key == state.key, do: state, else: changed(state, key, members, active?)
  end

  defp changed(state, key, members, active?) do
    state = if state.phase in [:running, :between_rounds], do: stop(state, :membership_changed), else: state

    %{
      state
      | key: key,
        members: members,
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
    config = Alambique.Config.fetch!(state.alambique)
    preferred = &Alambique.Membership.preferred(config, &1)
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
    config = Alambique.Config.fetch!(state.alambique)
    pinned = HotCells.pinned(state.name)

    case Plan.next(state.plan, &check(state, config, pinned, &1)) do
      {{:move, id, target}, plan} ->
        start_move(state, id, target)
        %{state | plan: plan, in_flight: id}

      {:none, plan} ->
        state = %{state | plan: plan}
        if Plan.pending(plan) == 0, do: round_done(state), else: state
    end
  end

  # What a cell is now: it may have gone to sleep, been pinned, or have a call running.
  defp check(state, config, pinned, id) do
    with false <- MapSet.member?(pinned, id),
         target = Alambique.Membership.preferred(config, id),
         true <- target != node() and not Detector.blocked?(state.name, target),
         {:ok, %{pending: 0, waking: false}} <- Alambique.load(state.alambique, id) do
      {:move, target}
    else
      {:ok, _busy} -> :busy
      _ -> :stay
    end
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
