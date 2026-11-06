defmodule Atanor.Detector do
  @moduledoc """
  Failure detection between the nodes of an instance (design §8.6 to §8.10).

  Each node sends a heartbeat to its peers every `interval_ms` over Erlang
  distribution and keeps a phi accrual detector per peer. When phi of a peer
  reaches `phi_threshold` the peer is *suspect*: this node pings it and asks up
  to `indirect.k` other peers to ping it too. If nobody reaches it, it is
  *down*; if some peer does, the link between this node and the peer is
  *broken*. Heartbeats that resume make the peer *alive* again.

  A node that is down is not forwarded to and is disconnected, so calls in
  flight to it fail at once instead of waiting for `net_ticktime`. A node that
  stops gracefully announces it first, and the platform can say that a node is
  gone (`gone/2`). Both skip the wait for phi. The cells of a node that is down
  are taken over lazily, one per call that needs them (`Atanor.Takeover`).
  """
  use GenServer

  alias Atanor.Detector.Phi

  @scope Atanor.PG

  @type state :: :alive | :suspect | :link_broken | :down

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: server(config.name)]]}}
  end

  defp server(name), do: Module.concat(name, Detector)

  @doc """
  Child spec of the detector's task supervisor. It starts before the detector, which runs tasks from its
  first tick; they use no instance table, so it may stop after it (`Atanor.Tasks` does stop before it).
  """
  def tasks_spec(name), do: Supervisor.child_spec({Task.Supervisor, name: tasks(name)}, id: :detector_tasks)

  defp tasks(name), do: Module.concat(name, DetectorTasks)
  defp group(prefix), do: {__MODULE__, prefix}

  @doc "Whether calls must not be forwarded to `node`: it is down, or the link to it is broken."
  @spec blocked?(atom, node) :: boolean
  def blocked?(name, node), do: :ets.member(server(name), node)

  @doc """
  Whether `node` announced that it leaves. It serves the cells it still holds while it
  hands them off (design §8.11), so an idempotent call may still go to it.
  """
  @spec left?(atom, node) :: boolean
  def left?(name, node), do: :ets.match(server(name), {node, :down, :left}) != []

  @doc "Whether any node announced that it leaves."
  @spec any_left?(atom) :: boolean
  def any_left?(name), do: :ets.match(server(name), {:_, :down, :left}) != []

  @doc """
  The node that runs under the Alambique node id `owner` when it is confirmed
  *down* (not merely `link_broken`: that node is alive and its cells are still
  served), with the reason. `Atanor.Takeover` asks it before taking a cell.
  """
  @spec down_owner(atom, String.t()) :: {:ok, node, term} | :error
  def down_owner(name, owner) do
    case Enum.find(:ets.match_object(server(name), {:_, :down, :_}), fn {node, _, _} ->
           Atom.to_string(node) == owner
         end) do
      {node, :down, reason} -> {:ok, node, reason}
      nil -> :error
    end
  end

  @doc """
  Whether this node and the peers it hears from have been a strict majority of
  the nodes it knows for at least `takeover.settle_ms`. A node cut off from the
  others is a minority and must not take their cells (`Atanor.Takeover`); the
  settle time keeps a node that is rejoining from acting on a partial view, when
  one peer is back and another is not yet. A peer counts as heard when it is
  `alive` and its phi, taken now, is under the threshold. A peer that left or that
  the platform says is gone is known to be absent rather than lost, and is not
  among the nodes it knows.
  """
  @spec quorum?(atom) :: boolean
  def quorum?(name), do: GenServer.call(server(name), :quorum?)

  @doc """
  Confirms that `node` is down: stops routing to it, disconnects it and
  emits `[:atanor, :node, :down]`. This is the one place that acts on a
  suspicion that was confirmed, whoever confirmed it. It marks the node; its
  cells are taken over one by one, when a call needs one (`Atanor.Takeover`).
  """
  @spec confirmed_down(atom, node, term) :: :ok
  def confirmed_down(name, node, reason), do: GenServer.call(server(name), {:confirmed_down, node, reason})

  @doc """
  The platform says `node` is gone: it is confirmed down here and at the peers
  without waiting for phi. `{:error, :unknown_node}` for a node this one does not know.
  """
  @spec gone(atom, node) :: :ok | {:error, :unknown_node}
  def gone(name, node), do: GenServer.call(server(name), {:gone, node})

  @doc "What this node knows of its peers, sorted by node."
  @spec peers(atom) :: [map]
  def peers(name), do: GenServer.call(server(name), :peers)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    d = config.detector
    :ets.new(server(config.name), [:named_table, :protected, :set, read_concurrency: true])
    :ok = :pg.join(@scope, group(config.prefix), self())
    :net_kernel.monitor_nodes(true, [:nodedown_reason])
    send(self(), :tick)

    {:ok,
     %{
       name: config.name,
       server: server(config.name),
       group: group(config.prefix),
       d: d,
       interval: ms_to_us(d.interval_ms),
       peers: %{},
       settle_ms: config.takeover.settle_ms,
       majority: true,
       majority_since: now() - ms_to_us(config.takeover.settle_ms),
       active: now()
     }}
  end

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  def handle_call(:peers, _from, state), do: {:reply, report(state), state}

  def handle_call(:quorum?, _from, state) do
    state = track_majority(state)
    {:reply, state.majority and now() - state.majority_since >= ms_to_us(state.settle_ms), state}
  end

  def handle_call({:confirmed_down, node, reason}, _from, state), do: {:reply, :ok, down(state, node, reason)}

  def handle_call({:gone, node}, _from, state) do
    if is_map_key(state.peers, node) do
      tell(state, state.peers |> Map.keys() |> List.delete(node), {:gone, node})
      {:reply, :ok, down(state, node, :platform_hint)}
    else
      {:reply, {:error, :unknown_node}, state}
    end
  end

  @impl true
  def handle_info(message, state) do
    at = now()
    state = if at - state.active > state.d.stall_intervals * state.interval, do: resumed(state, at), else: state
    {:noreply, handle(message, %{state | active: at})}
  end

  @impl true
  def terminate(reason, state) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
      do: tell(state, Map.keys(state.peers), {:leaving, node()})
  end

  defp handle(:tick, state) do
    Process.send_after(self(), :tick, state.d.interval_ms)
    state |> discover() |> heartbeats() |> reconnect() |> evaluate() |> forget() |> track_majority()
  end

  defp handle({:heartbeat, from}, state), do: heartbeat(state, from)
  defp handle({:leaving, from}, state), do: down(state, from, :left)
  defp handle({:gone, node}, state) when node != node(), do: down(state, node, :platform_hint)

  defp handle({:nodedown, node, info}, state) do
    case state.peers do
      %{^node => %{state: :alive}} -> suspect(state, node, {:nodedown, info[:nodedown_reason]})
      _ -> state
    end
  end

  defp handle({:probe, ref, target, from}, state) do
    ping_later(state, {state.server, from}, ref, target)
    state
  end

  defp handle({:probe_result, ref, who, reached?}, state) do
    case Enum.find(state.peers, fn {_, peer} -> match?(%{ref: ^ref}, peer.round) end) do
      {node, peer} -> probed(state, node, peer, who, reached?)
      nil -> state
    end
  end

  defp handle({:round_timeout, ref}, state) do
    case Enum.find(state.peers, fn {_, peer} -> match?(%{ref: ^ref}, peer.round) end) do
      {node, peer} -> down(state, node, peer.reason)
      nil -> state
    end
  end

  defp handle(_message, state), do: state

  # This node was stalled (paused, or starved): what it did not hear says
  # nothing about its peers. Heartbeats waiting in the mailbox are not intervals,
  # but they show the peer is up: one suspected or down meanwhile is alive again.
  defp resumed(state, at) do
    state = Enum.reduce(drain(), state, &heard(&2, &1, at))
    %{state | peers: Map.new(state.peers, fn {node, peer} -> {node, %{peer | phi: Phi.touch(peer.phi, at)}} end)}
  end

  defp drain do
    receive do
      {:heartbeat, from} -> [from | drain()]
    after
      0 -> []
    end
  end

  defp heard(state, node, at) do
    state = touch(state, node, at)

    case state.peers do
      %{^node => %{state: :alive}} -> state
      %{^node => _} -> alive(state, node)
      _ -> state
    end
  end

  defp touch(state, node, at) do
    case state.peers do
      %{^node => peer} -> put_in(state.peers[node], %{peer | phi: Phi.touch(peer.phi, at)})
      _ -> state
    end
  end

  # Whether this node hears a strict majority of the nodes it knows, and since when.
  # A peer that left or that the platform says is gone is not among the nodes it knows.
  defp track_majority(state) do
    known = Enum.reject(report(state), &(&1.state == :down and &1.reason in [:left, :platform_hint]))
    heard = Enum.count(known, &(&1.state == :alive and &1.phi < state.d.phi_threshold))
    majority = (heard + 1) * 2 > length(known) + 1

    cond do
      majority == state.majority -> state
      true -> %{state | majority: majority, majority_since: now()}
    end
  end

  # Peers

  defp discover(state) do
    members = for pid <- :pg.get_members(@scope, state.group), node(pid) != node(), uniq: true, do: node(pid)
    Enum.reduce(members, state, &ensure(&2, &1))
  end

  defp ensure(state, node) do
    if is_map_key(state.peers, node) do
      state
    else
      peer = %{
        phi: Phi.new(now(), state.interval, state.d.window, state.d.seed_spread),
        state: :alive,
        reason: nil,
        since: now(),
        round: nil,
        probed: 0,
        reconnect: nil,
        reconnect_at: nil
      }

      put_in(state.peers[node], peer)
    end
  end

  defp heartbeats(state) do
    for node <- Map.keys(state.peers), do: send_to(state, node, {:heartbeat, node()})
    state
  end

  defp tell(state, nodes, message), do: for(node <- nodes, do: send_to(state, node, message))

  # Never connects and never waits: a peer that cannot take a message now gets none.
  defp send_to(state, node, message), do: :erlang.send({state.server, node}, message, [:noconnect, :nosuspend])

  # A peer that is not connected is reached again by connecting, in the background.
  defp reconnect(state) do
    connected = Node.list()
    at = now()

    peers =
      Map.new(state.peers, fn {node, peer} ->
        busy? = peer.reconnect != nil and Process.alive?(peer.reconnect)

        if node in connected or busy? or recent?(peer.reconnect_at, at, state.d.reconnect_ms) do
          {node, peer}
        else
          {:ok, pid} =
            Task.Supervisor.start_child(tasks(state.name), fn -> :net_kernel.connect_node(node) end)

          {node, %{peer | reconnect: pid, reconnect_at: at}}
        end
      end)

    %{state | peers: peers}
  end

  # `nil` is never. Monotonic time can be negative, so 0 is not "long ago".
  defp recent?(nil, _at, _ms), do: false
  defp recent?(since, at, ms), do: at - since < ms_to_us(ms)

  defp forget(state) do
    limit = now() - ms_to_us(state.d.forget_after_ms)
    %{state | peers: Map.reject(state.peers, fn {_, p} -> p.state == :down and p.since < limit end)}
  end

  defp evaluate(state) do
    at = now()

    Enum.reduce(state.peers, state, fn {node, peer}, state ->
      phi = phi(state, peer, at)

      cond do
        phi < state.d.phi_threshold ->
          state

        peer.state == :alive ->
          suspect(state, node, {:phi, Float.round(phi, 1)})

        peer.state == :link_broken and peer.round == nil and at - peer.probed >= ms_to_us(state.d.reprobe_ms) ->
          probe(state, node)

        true ->
          state
      end
    end)
  end

  defp heartbeat(state, node) do
    state = ensure(state, node)
    peer = state.peers[node]
    at = now()
    phi = if peer.state == :alive, do: Phi.heartbeat(peer.phi, at), else: Phi.touch(peer.phi, at)
    state = put_in(state.peers[node], %{peer | phi: phi})
    if peer.state == :alive, do: state, else: alive(state, node)
  end

  defp phi(state, peer, at),
    do: Phi.phi(peer.phi, at, ms_to_us(state.d.min_std_ms), ms_to_us(state.d.acceptable_pause_ms))

  # Transitions. Each one updates the table that Dispatch reads and emits the event.

  defp alive(state, node) do
    peer = state.peers[node]
    :ets.delete(state.server, node)
    state = put_in(state.peers[node], %{peer | state: :alive, reason: nil, since: now(), round: nil})
    event(state, :alive, node, %{from: peer.state})
  end

  defp suspect(state, node, reason) do
    peer = state.peers[node]
    state = put_in(state.peers[node], %{peer | state: :suspect, reason: reason, since: now()})
    state |> event(:suspect, node, %{reason: reason}) |> probe(node)
  end

  # The single place that acts on a confirmed failure.
  defp down(state, node, reason) do
    state = ensure(state, node)

    case state.peers[node] do
      %{state: :down} ->
        state

      peer ->
        :ets.insert(state.server, {node, :down, reason})
        # A node that left hands its cells off over the connection that is still up.
        if reason != :left, do: :erlang.disconnect_node(node)
        state = put_in(state.peers[node], %{peer | state: :down, reason: reason, since: now(), round: nil})
        event(state, :down, node, %{reason: reason})
    end
  end

  defp link_broken(state, node, via) do
    peer = state.peers[node]
    :ets.insert(state.server, {node, :link_broken, via})
    changed? = peer.state != :link_broken

    state =
      put_in(state.peers[node], %{
        peer
        | state: :link_broken,
          since: if(changed?, do: now(), else: peer.since),
          round: nil,
          probed: now()
      })

    if changed?, do: event(state, :link_broken, node, %{via: via}), else: state
  end

  defp event(state, name, node, meta) do
    phi = phi(state, state.peers[node], now())
    :telemetry.execute([:atanor, :node, name], %{phi: phi}, Map.merge(meta, %{instance: state.name, node: node}))
    state
  end

  # Indirect probes

  defp probe(state, node) do
    ref = make_ref()
    witnesses = for {n, %{state: :alive}} <- state.peers, n != node, do: n
    witnesses = Enum.take_random(witnesses, state.d.indirect_k)
    ping_later(state, {state.server, node()}, ref, node)
    tell(state, witnesses, {:probe, ref, node, node()})
    Process.send_after(self(), {:round_timeout, ref}, state.d.indirect_round_timeout_ms)

    round = %{ref: ref, pending: MapSet.new([node() | witnesses])}
    update_in(state.peers[node], &%{&1 | round: round, probed: now()})
  end

  # This node reached the peer itself: its heartbeats were late, not lost.
  defp probed(state, node, _peer, who, true) when who == node(), do: state |> touch(node, now()) |> alive(node)
  defp probed(state, node, _peer, who, true), do: link_broken(state, node, who)

  defp probed(state, node, peer, who, false) do
    pending = MapSet.delete(peer.round.pending, who)

    if MapSet.size(pending) == 0,
      do: down(state, node, peer.reason),
      else: put_in(state.peers[node].round.pending, pending)
  end

  # Pings `target`'s detector from a task and sends the answer to `reply`.
  defp ping_later(state, reply, ref, target) do
    server = state.server
    timeout = state.d.indirect_timeout_ms

    Task.Supervisor.start_child(tasks(state.name), fn ->
      reached? =
        try do
          GenServer.call({server, target}, :ping, timeout) == :pong
        catch
          :exit, _ -> false
        end

      send(reply, {:probe_result, ref, node(), reached?})
    end)
  end

  # Report

  defp report(state) do
    at = now()

    for {node, peer} <- Enum.sort(state.peers) do
      %{
        node: node,
        state: peer.state,
        phi: Float.round(phi(state, peer, at), 2),
        last_heartbeat_ms: div(Phi.elapsed(peer.phi, at), 1_000),
        reason: peer.reason
      }
    end
  end

  defp now, do: System.monotonic_time(:microsecond)
  defp ms_to_us(ms), do: ms * 1_000
end
