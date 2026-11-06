defmodule Atanor.HotCells do
  @moduledoc """
  Automatic placement of hot cells (design §8.15).

  A cell has one writer, on one node. When a cell is busy and its node is under
  CPU pressure, the node moves the cell to a less loaded one with
  `Alambique.move/4`, or to a node tagged for it (`hot_cells: [tags:, affinity:]`).
  The loop is off by default (`hot_cells: [enabled: true]`).

  **The owner decides.** Each node samples the cells it serves, so each node
  decides only for its own cells and two nodes never decide for one cell. It
  learns the load of the others from a message every `interval_ms`. Lease and
  epoch fencing keep a single writer whatever the decision; a decision made on
  a stale view costs a useless move at worst.

  **Metrics**, every `interval_ms`: reads and writes per second of each cell
  (counted in `Atanor.Cell`, for the calls this node makes), the calls waiting on
  the cell (`Alambique.load/2`: its mailbox and the callers waiting on a commit), and the CPU use of the node: the
  larger of its schedulers' and the machine's (`Atanor.HotCells.Cpu`). The thresholds have an enter and an exit value; a
  cell must stay hot for `sustain_ms` before anything happens.

  **Hysteresis**: enter and exit thresholds, the sustained window, the margin
  between source and target, a residence time per cell after it moved, a
  cooldown per node, and a cap on moves in progress in the cluster. The nodes
  tell each other when a move starts and ends, so each knows the same state.

  **Read replicas** (`hot_cells: [replicas: true]`, design §19.4). The owner also turns on the read replicas
  of Alambique for a cell that is read at `replica_enter` reads per second or more in the cluster, and
  turns them off after `replica_hold_ms` under `replica_exit`. Reads served on other nodes are not seen by
  the owner, so each node tells its peers, in the load message, the reads per second of the cells it does not
  serve. `move: false` keeps the loop from moving cells and leaves this.

  The decisions are in `Atanor.HotCells.Policy`; this module collects the
  inputs and starts the moves.
  """
  use GenServer

  require Logger

  alias Atanor.{Cell, Detector, Registry}
  alias Atanor.HotCells.{Cpu, Policy}

  @scope Atanor.PG
  @recent 20

  @type address :: Cell.address()

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: server(config.name)]]}}
  end

  defp server(name), do: Module.concat(name, HotCells)
  defp gate(name), do: Module.concat(name, HotCellsGate)
  defp group(prefix), do: {__MODULE__, prefix}

  @doc false
  # Called by `Atanor.Cell` for each call on a cell. A node that does not run the loop has no table.
  @spec count(atom, String.t(), :read | :write) :: :ok
  def count(instance, id, kind) do
    :ets.update_counter(server(instance), id, {if(kind == :read, do: 2, else: 3), 1}, {id, 0, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Holds a caller that would wake or use cell `id` while it moves, up to `timeout_ms` (design §8.15). Without it
  # the calls of a hot cell wake it again on the old node between its hibernate and the wake on the target.
  @spec hold(atom, String.t(), pos_integer) :: :ok
  def hold(instance, id, timeout_ms) do
    if :ets.member(gate(instance), id), do: wait(gate(instance), id, System.monotonic_time(:millisecond) + timeout_ms)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp wait(table, id, deadline) do
    if :ets.member(table, id) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(5)
      wait(table, id, deadline)
    end
  end

  @doc """
  Moves the cell to `node` now, by the same path as the loop: the other nodes are told, so the cap, the
  residence time and the cooldown apply to what follows. Returns what `Alambique.move/4` returns.
  `{:error, :disabled}` when the loop is off.
  """
  @spec move(atom, address, node, atom) :: {:ok, node} | {:error, term}
  def move(instance, address, node, reason \\ :manual) do
    with {:ok, id} <- Cell.id(address) do
      server = server(instance)

      if GenServer.whereis(server) do
        :ok = GenServer.call(server, {:begin, id, node, reason})
        run(instance, address, id, node, reason, Registry.config(instance).hot_cells.move_timeout_ms)
      else
        {:error, :disabled}
      end
    end
  end

  @doc "What this node knows: its load, the hot cells it serves, its peers' load, moves in progress and recent."
  @spec status(atom) :: map | {:error, :disabled}
  def status(instance) do
    if GenServer.whereis(server(instance)), do: GenServer.call(server(instance), :status), else: {:error, :disabled}
  end

  @impl true
  def init(config) do
    cfg = config.hot_cells
    :ets.new(server(config.name), [:named_table, :public, :set, write_concurrency: true])
    :ets.new(gate(config.name), [:named_table, :public, :set, read_concurrency: true])
    :ok = :pg.join(@scope, group(config.prefix), self())
    Cpu.enable()
    send(self(), :tick)

    {:ok,
     %{
       name: config.name,
       prefix: config.prefix,
       cfg: cfg,
       schedulers: Cpu.schedulers(),
       cpu_sample: Cpu.sample(cfg.os_cpu),
       at: now(),
       cpu: 0.0,
       pressured: false,
       reads: 0.0,
       writes: 0.0,
       cells: %{},
       peers: %{},
       replicas: %{},
       remote: %{},
       moving: %{},
       moved: %{},
       cooling: %{},
       recent: []
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.cfg.interval_ms)
    {:noreply, tick(state)}
  end

  # The load message also lists the moves its sender runs, so a node that missed a `:moving` (it had just
  # restarted) learns them within one interval.
  def handle_info({:load, from, load}, state) do
    state = put_in(state.peers[from], Map.put(load, :at, now()))

    {:noreply,
     Enum.reduce(load.moving, state, fn {id, target}, state ->
       if Map.has_key?(state.moving, id), do: state, else: moving(state, id, from, target)
     end)}
  end

  def handle_info({:moving, id, source, target}, state), do: {:noreply, moving(state, id, source, target)}

  def handle_info({:moved, id, source, target}, state), do: {:noreply, finished(state, id, source, target)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:begin, id, target, reason}, _from, state), do: {:reply, :ok, begin(state, id, target, reason)}

  def handle_call(:status, _from, state), do: {:reply, report(state), state}

  @impl true
  def handle_cast({:replicas, id, action, result, reads}, state) do
    :telemetry.execute([:atanor, :hot_cell, :replicas], %{reads: reads}, %{
      instance: state.name,
      cell: elem(Cell.parse(id), 1),
      action: action,
      result: result
    })

    entry = state.replicas[id] && Policy.confirm_replicas(state.replicas[id], action, result == :ok)

    {:noreply,
     %{state | replicas: if(entry, do: Map.put(state.replicas, id, entry), else: Map.delete(state.replicas, id))}}
  end

  def handle_cast({:finished, id, target, record}, state) do
    state = finished(state, id, node(), target)
    announce_finished(state, id, target)
    {:noreply, %{state | recent: Enum.take([record | state.recent], @recent)}}
  end

  # A failure of the loop is logged and the next tick tries again: the loop is an optimization and must not stop the node.
  defp tick(state) do
    state |> sample() |> prune() |> announce() |> decide()
  rescue
    exception ->
      Logger.warning("atanor: hot cell placement failed: " <> Exception.message(exception))
      state
  end

  # The counters of the interval become rates; the hot cells are the ones that stay tracked.
  defp sample(state) do
    now = now()
    elapsed = max(now - state.at, 1)
    cpu_sample = Cpu.sample(state.cfg.os_cpu)
    %{cpu: cpu} = usage = Cpu.utilization(state.cpu_sample, cpu_sample, state.schedulers)
    counts = drain(server(state.name))
    peer_reads = peer_reads(state, now)
    ids = Enum.uniq(Map.keys(counts) ++ Map.keys(state.cells) ++ Map.keys(state.replicas) ++ Map.keys(peer_reads))

    # `pending` counts the callers a cell accepted and has not answered, so writes in the commit pipeline count too.
    samples =
      for id <- ids,
          {:ok, %{pending: queue}} <- [Alambique.load(Registry.config(state.name).alambique, id)],
          into: %{} do
        {reads, writes} = Map.get(counts, id, {0, 0})
        {id, %{reads: reads * 1000 / elapsed, writes: writes * 1000 / elapsed, queue: queue}}
      end

    state = replicas(state, samples, peer_reads, now)

    cells =
      for {id, sample} <- samples, tracked = track(Map.get(state.cells, id), sample, now, state.cfg), into: %{} do
        {id, tracked}
      end

    cells =
      cells |> Enum.sort_by(fn {_, c} -> -Policy.score(c.sample) end) |> Enum.take(state.cfg.max_tracked) |> Map.new()

    pressured = Policy.pressured?(state.pressured, cpu, state.cfg)
    totals = Enum.reduce(samples, {0.0, 0.0}, fn {_, s}, {r, w} -> {r + s.reads, w + s.writes} end)

    :telemetry.execute(
      [:atanor, :hot_cell, :sample],
      %{
        cpu: cpu,
        scheduler: usage.scheduler,
        os: usage.os,
        reads: elem(totals, 0),
        writes: elem(totals, 1),
        hot: map_size(cells)
      },
      %{
        instance: state.name,
        node: node(),
        pressured: pressured
      }
    )

    %{
      state
      | at: now,
        cpu_sample: cpu_sample,
        cpu: cpu,
        pressured: pressured,
        remote: remote_reads(state, counts, samples, elapsed),
        cells: cells,
        reads: elem(totals, 0),
        writes: elem(totals, 1)
    }
  end

  # The reads per second of the cells that this node counted and does not serve, hottest first, for their owners.
  defp remote_reads(%{cfg: %{replicas: false}}, _counts, _samples, _elapsed), do: %{}

  defp remote_reads(state, counts, samples, elapsed) do
    for({id, {reads, _}} <- counts, reads > 0, not is_map_key(samples, id), do: {id, reads * 1000 / elapsed})
    |> Enum.sort_by(&(-elem(&1, 1)))
    |> Enum.take(state.cfg.max_tracked)
    |> Map.new()
  end

  # What the other nodes tell this one about the cells they read and do not serve, summed.
  defp peer_reads(%{cfg: %{replicas: false}}, _now), do: %{}

  defp peer_reads(state, now) do
    for {_peer, %{at: at, reads: reads}} <- state.peers,
        now - at <= state.cfg.stale_ms,
        {id, rate} <- reads,
        reduce: %{} do
      sum -> Map.update(sum, id, rate, &(&1 + rate))
    end
  end

  # The cells this node serves whose reads, here and elsewhere, ask for replicas, or no longer do.
  defp replicas(%{cfg: %{replicas: false}} = state, _samples, _peer_reads, _now), do: state

  defp replicas(state, samples, peer_reads, now) do
    entries =
      for {id, sample} <- samples, into: %{} do
        reads = sample.reads + Map.get(peer_reads, id, 0)
        {entry, action} = Policy.replicas(state.replicas[id], reads, now, state.cfg)
        {id, {entry && if(action, do: %{entry | pending: true}, else: entry), action, reads}}
      end

    for {id, {_, action, reads}} <- entries, action, do: set_replicas(state, id, action, reads)
    %{state | replicas: for({id, {entry, _, _}} <- entries, entry, into: %{}, do: {id, entry})}
  end

  defp set_replicas(state, id, action, reads) do
    instance = state.name
    server = server(instance)
    {:ok, address} = Cell.parse(id)

    Task.Supervisor.start_child(Atanor.Tasks.name(state.name), fn ->
      GenServer.cast(server, {:replicas, id, action, Cell.replicas(instance, address, action == :on), reads})
    end)
  end

  defp track(previous, sample, now, cfg) do
    if Policy.hot?(previous != nil, sample, cfg) do
      %{sample: sample, since: if(previous, do: previous.since, else: now), reason: previous && previous.reason}
    end
  end

  defp drain(table) do
    for key <- :ets.select(table, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        [{^key, reads, writes}] <- [:ets.take(table, key)],
        into: %{} do
      {key, {reads, writes}}
    end
  end

  defp prune(state) do
    now = now()
    cfg = state.cfg
    stuck = cfg.move_timeout_ms + cfg.stale_ms

    {stale, moving} = Enum.split_with(state.moving, fn {_, {_, _, at}} -> now - at >= stuck end)
    for {id, _} <- stale, do: :ets.delete(gate(state.name), id)

    %{
      state
      | moved: Map.reject(state.moved, fn {_, at} -> now - at >= cfg.residence_ms end),
        cooling: Map.reject(state.cooling, fn {_, until} -> until <= now end),
        moving: Map.new(moving)
    }
  end

  defp announce(state) do
    if Registry.state(state.name) == :ready do
      mine = for {id, {source, target, _}} <- state.moving, source == node(), do: {id, target}
      load = %{cpu: state.cpu, hot: map_size(state.cells), tags: state.cfg.tags, reads: state.remote, moving: mine}
      tell(state, {:load, node(), load})
    end

    state
  end

  defp tell(state, message) do
    for pid <- :pg.get_members(@scope, group(state.prefix)), pid != self(), do: send(pid, message)
    :ok
  end

  defp decide(state) do
    if state.cfg.move and Registry.state(state.name) == :ready, do: do_decide(state), else: state
  end

  defp do_decide(state) do
    now = now()
    cfg = state.cfg
    peers = receivers(state, now)
    self = %{node: node(), cpu: state.cpu, tags: cfg.tags, pressured: state.pressured}

    state.cells
    |> Enum.filter(fn {_, c} -> now - c.since >= cfg.sustain_ms end)
    |> Enum.sort_by(fn {_, c} -> -Policy.score(c.sample) end)
    |> Enum.reduce_while(state, fn {id, cell}, state ->
      {:ok, {namespace, _} = address} = Cell.parse(id)

      ctx = %{
        namespace: namespace,
        self: self,
        peers: peers,
        since_move_ms: state.moved[id] && now - state.moved[id],
        moving: map_size(state.moving),
        cooling: for({n, until} <- state.cooling, into: %{}, do: {n, until - now})
      }

      case Policy.decide(ctx, cfg) do
        {:move, target, reason} ->
          decision(state, address, cell, :move, reason, target)
          state = begin(state, id, target, reason)
          start_move(state, address, id, target, reason)
          {:halt, state}

        {:stay, reason} ->
          if cell.reason != reason, do: decision(state, address, cell, :stay, reason, nil)
          {:cont, put_in(state.cells[id].reason, reason)}
      end
    end)
  end

  # Nodes that can receive a cell: heard from lately, and neither down, leaving nor cut off from this node.
  defp receivers(state, now) do
    for {peer, load} <- state.peers,
        now - load.at <= state.cfg.stale_ms,
        not Detector.blocked?(state.name, peer),
        into: %{},
        do: {peer, Map.take(load, [:cpu, :hot, :tags])}
  end

  defp decision(state, address, cell, action, reason, target) do
    :telemetry.execute([:atanor, :hot_cell, :decision], %{hot_ms: now() - cell.since}, %{
      instance: state.name,
      cell: address,
      action: action,
      reason: reason,
      target: target,
      reads: cell.sample.reads,
      writes: cell.sample.writes,
      queue: cell.sample.queue,
      cpu: state.cpu
    })
  end

  defp begin(state, id, target, _reason) do
    tell(state, {:moving, id, node(), target})
    moving(state, id, node(), target)
  end

  defp moving(state, id, source, target) do
    :ets.insert(gate(state.name), {id})
    put_in(state.moving[id], {source, target, now()})
  end

  defp start_move(state, address, id, target, reason) do
    instance = state.name
    timeout = state.cfg.move_timeout_ms

    Task.Supervisor.start_child(Atanor.Tasks.name(state.name), fn ->
      run(instance, address, id, target, reason, timeout)
    end)
  end

  # Runs the move and tells the server and, through it, the peers.
  defp run(instance, address, id, target, reason, timeout) do
    started = System.monotonic_time()
    result = Cell.move(instance, address, target, timeout: timeout)
    duration = System.monotonic_time() - started

    meta = %{
      instance: instance,
      cell: address,
      from: node(),
      to: target,
      reason: reason,
      result: if(match?({:ok, _}, result), do: :ok, else: result)
    }

    :telemetry.execute([:atanor, :hot_cell, :move], %{duration: duration}, meta)

    record = %{
      cell: id,
      to: target,
      reason: reason,
      result: inspect(meta.result),
      at_ms: System.os_time(:millisecond),
      duration_ms: System.convert_time_unit(duration, :native, :millisecond)
    }

    GenServer.cast(server(instance), {:finished, id, target, record})
    result
  end

  defp finished(state, id, source, target) do
    :ets.delete(gate(state.name), id)
    now = now()
    until = now + state.cfg.node_cooldown_ms

    %{
      state
      | moving: Map.delete(state.moving, id),
        moved: Map.put(state.moved, id, now),
        cooling: state.cooling |> Map.put(source, until) |> Map.put(target, until)
    }
  end

  defp announce_finished(state, id, target), do: tell(state, {:moved, id, node(), target})

  defp report(state) do
    now = now()

    %{
      node: node(),
      cpu: Float.round(state.cpu, 1),
      pressured: state.pressured,
      reads_per_s: Float.round(state.reads, 1),
      writes_per_s: Float.round(state.writes, 1),
      hot:
        for(
          {id, c} <- state.cells,
          do: %{cell: id, hot_ms: now - c.since, last_decision: c.reason} |> Map.merge(c.sample)
        ),
      peers:
        for(
          {peer, p} <- state.peers,
          do: %{node: peer, cpu: Float.round(p.cpu, 1), hot: p.hot, tags: p.tags, age_ms: now - p.at}
        ),
      replicas: for({id, %{on: true}} <- state.replicas, do: id),
      moving: for({id, {from, to, _}} <- state.moving, do: %{cell: id, from: from, to: to}),
      recent: state.recent
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
