defmodule AtanorTestkit.Cluster do
  @moduledoc """
  A cluster of peer nodes, each running an Atanor instance with the same name
  and prefix over one `AlambiqueTestkit.MemoryStore` that lives on the test
  node (design §11). It mirrors `AlambiqueTestkit.Cluster`, which starts only
  an Alambique instance and cannot start Atanor beside it.

      {:ok, cluster} = Cluster.start_link(names: [:n1, :n2], ttl_ms: 2_000, skew_margin_ms: 400)
      {:ok, id} = Cluster.deploy(cluster, manifest)
      Req.get!(Cluster.url(cluster, :n1) <> "/path")
      Cluster.kill(cluster, :n1)

  Every peer has an ephemeral HTTP port and an admin listener (token
  `"cluster-token"`, ephemeral port). Worker modules must be compiled to disk
  (the library and `test/support`): peers load code from the test VM's paths.

  ## What can go wrong

    * `kill/2` halts the VM at once and `restart/2` starts it again with the
      same node name and data directory (new ports).
    * `kill_process/2` sends SIGKILL to the peer's operating system process,
      `pause/2` SIGSTOP and `resume/2` SIGCONT. A stopped peer keeps its
      connections open and answers nothing, like a machine that disappeared
      without closing them. Only the processes of peers started here are
      signalled.
    * `partition_store/2` makes every store request of one node fail, and
      `inject/3` adds any other `MemoryStore` fault.
    * `partition_nodes/3` cuts the distribution link between two peers and
      keeps it cut (they cannot connect again); `heal_nodes/3` undoes it.
    * `set_clock_offset/3` skews the clock one node gives to leases.

  ## Telemetry

  Every `[:atanor, ...]` and `[:alambique, :cell | :router | :lease |
  :replication, ...]` event of every peer, and the `[:alambique, :replica, :read | :stop]`
  events, are forwarded to the cluster.
  `events/1` returns them as `%{node: name, event: [atom], measurements: map,
  meta: map, at: microseconds}` in arrival order; `at` is the operating system
  clock, which the peers share, taken when the event was emitted.
  """

  use GenServer

  alias AlambiqueTestkit.MemoryStore
  alias Atanor.{Deployments, Package, Store}

  @forwarded [
    [:atanor, :call],
    [:atanor, :forward],
    [:atanor, :foreign_store],
    [:atanor, :cells, :migrate],
    [:atanor, :node, :suspect],
    [:atanor, :node, :down],
    [:atanor, :node, :link_broken],
    [:atanor, :node, :alive],
    [:atanor, :node, :drain],
    [:atanor, :deployments, :loaded],
    [:atanor, :node, :ready],
    [:atanor, :cell, :take_over],
    [:atanor, :hot_cell, :decision],
    [:atanor, :hot_cell, :move],
    [:atanor, :hot_cell, :replicas],
    [:atanor, :http, :reject],
    [:atanor, :alarm, :fired],
    [:atanor, :alarm, :failed],
    [:atanor, :job, :enqueued],
    [:atanor, :job, :started],
    [:atanor, :job, :finished],
    [:atanor, :job, :dead],
    [:atanor, :job, :released],
    [:atanor, :job, :unconfirmed],
    [:atanor, :handler, :fenced],
    [:atanor, :sweep, :started],
    [:atanor, :sweep, :paused],
    [:atanor, :sweep, :resumed],
    [:atanor, :sweep, :cancelled],
    [:atanor, :sweep, :continued],
    [:atanor, :sweep, :awaiting_confirmation],
    [:atanor, :sweep, :canary_passed],
    [:atanor, :sweep, :halted],
    [:atanor, :sweep, :done],
    [:atanor, :sweep, :failed],
    [:atanor, :sweep, :page],
    [:atanor, :sweep, :lease_lost],
    [:atanor, :admin, :action],
    [:atanor, :crash, :detected],
    [:atanor, :tcp, :connect],
    [:atanor, :tcp, :disconnect],
    [:atanor, :ws, :connect],
    [:atanor, :ws, :disconnect],
    [:atanor, :channel, :publish],
    [:atanor, :channel, :rejected],
    [:atanor, :wasm, :invoke],
    [:atanor, :wasm, :limit],
    [:alambique, :cell, :wake],
    [:alambique, :cell, :hibernate],
    [:alambique, :cell, :commit],
    [:alambique, :cell, :stop],
    [:alambique, :router, :forward],
    [:alambique, :lease, :acquire],
    [:alambique, :lease, :renew],
    [:alambique, :lease, :lost],
    [:alambique, :lease, :take_over],
    [:alambique, :replication, :fenced],
    [:alambique, :replica, :read],
    [:alambique, :replica, :stop]
  ]

  @token "cluster-token"
  # Bounds the wait for a peer's instance to start, which the peer reports itself. A loaded host needs minutes.
  @boot_timeout_ms 120_000
  # The cluster process is busy while it restarts or cuts a peer, so a lookup waits that long. Only a failure bound.
  @call_ms 120_000

  # Client

  @doc """
  Starts the cluster and waits until every peer runs its instance.

  Options:

    * `:names` - peer names (default `[:n1, :n2, :n3]`)
    * `:instance` - Atanor instance name (default `:atanor_cluster`)
    * `:prefix` - Atanor prefix (default `"cluster"`)
    * `:ttl_ms`, `:skew_margin_ms`, `:idle_timeout_ms`, `:op_timeout_ms` -
      lease and cell timings of the Alambique instances
    * `:boot_timeout_ms` - how long to wait for a peer's instance to start
      (default 120 000); only a failure bound
    * `:workers` - manifest maps deployed before this returns (see `deploy/3`)
    * `:atanor` - any other option of `Atanor` (for example `:alarms`,
      `:poll_interval_ms`, `:listeners`)
    * `:peer_atanor` - `%{name => options}` merged over `:atanor` for one peer,
      for example a `:release` of its own
    * `:wasm` - the `:atanor, :wasm` application environment of the peers
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with {:ok, cluster} <- GenServer.start_link(__MODULE__, opts) do
      case deploy_all(cluster, Keyword.get(opts, :workers, [])) do
        :ok ->
          {:ok, cluster}

        {:error, reason} ->
          GenServer.stop(cluster)
          {:error, {:worker_not_deployed, reason}}
      end
    end
  end

  @doc "Stops every peer, the store and the data directories."
  @spec stop(GenServer.server()) :: :ok
  def stop(cluster), do: GenServer.stop(cluster)

  @doc "Name of the Atanor instance that every peer runs."
  @spec instance(GenServer.server()) :: atom
  def instance(cluster), do: GenServer.call(cluster, :instance, @call_ms)

  @doc "`{module, config}` of the shared store."
  @spec store(GenServer.server()) :: {module, MemoryStore.config()}
  def store(cluster), do: GenServer.call(cluster, :store, @call_ms)

  @doc "Peer names."
  @spec names(GenServer.server()) :: [atom]
  def names(cluster), do: GenServer.call(cluster, :names, @call_ms)

  @doc "Node name of a peer."
  @spec node(GenServer.server(), atom) :: node
  def node(cluster, name), do: GenServer.call(cluster, {:peer, name}, @call_ms).node

  @doc "Whether the peer's VM is running."
  @spec alive?(GenServer.server(), atom) :: boolean
  def alive?(cluster, name), do: GenServer.call(cluster, {:peer, name}, @call_ms).peer != nil

  @doc "Base URL of the peer's HTTP ingress; the port changes when the peer restarts."
  @spec url(GenServer.server(), atom) :: String.t()
  def url(cluster, name), do: "http://127.0.0.1:#{GenServer.call(cluster, {:peer, name}, @call_ms).port}"

  @doc "Base URL of the peer's admin API."
  @spec admin_url(GenServer.server(), atom) :: String.t()
  def admin_url(cluster, name), do: "http://127.0.0.1:#{GenServer.call(cluster, {:peer, name}, @call_ms).admin_port}"

  @doc "The bearer token of the admin APIs."
  @spec admin_token() :: String.t()
  def admin_token, do: @token

  @doc """
  Runs `module.function(args)` on a peer. A dead or unreachable peer gives
  `{:error, {:erpc, reason}}`; otherwise the result is returned as `{:ok, result}`.
  """
  @spec call(GenServer.server(), atom, module, atom, list, timeout) :: {:ok, term} | {:error, term}
  def call(cluster, name, module, function, args, timeout \\ 30_000) do
    {:ok, :erpc.call(node(cluster, name), module, function, args, timeout)}
  catch
    :error, {:erpc, reason} -> {:error, {:erpc, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Publishes the package of a worker (a manifest map, as for
  `AtanorTestkit.Node.deploy/2`; `dir` holds a WASM component), activates it
  through a live peer and waits until every live peer applied it. Returns the
  package id, or the errors by peer.
  """
  @spec deploy(GenServer.server(), map, Path.t()) :: {:ok, String.t()} | {:error, term}
  def deploy(cluster, manifest_map, dir \\ ".") do
    with {:ok, id} <- publish(cluster, manifest_map, dir),
         do: activate(cluster, manifest_map["name"], id)
  end

  @doc "Publishes the package of a worker into the store without activating it. Returns its id."
  @spec publish(GenServer.server(), map, Path.t()) :: {:ok, String.t()} | {:error, term}
  def publish(cluster, manifest_map, dir \\ ".") do
    with {:ok, package} <- Package.from_project(manifest_map, dir),
         do: Deployments.publish(handle(cluster), package)
  end

  @doc """
  Makes package `id` the active one of `worker` and waits for every live peer
  to apply it. With `only: [names]` the change is made through the store, which
  tells nobody, and only those peers reload: the others keep the old
  deployment until `sync/2` or their next poll.
  """
  @spec activate(GenServer.server(), String.t(), String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def activate(cluster, worker, id, opts \\ []) do
    with {:ok, _head} <- change(cluster, opts, :activate, [worker, id]),
         do: applied(cluster, worker, id, peers(cluster, opts))
  end

  @doc "Returns `worker` to its previous package (`Atanor.Deployments.rollback/2`); options as for `activate/4`."
  @spec rollback(GenServer.server(), String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def rollback(cluster, worker, opts \\ []) do
    with {:ok, head} <- change(cluster, opts, :rollback, [worker]),
         do: applied(cluster, worker, head.active, peers(cluster, opts))
  end

  @doc "Makes the given peers reload the heads now."
  @spec sync(GenServer.server(), [atom]) :: :ok
  def sync(cluster, names) do
    for name <- names, do: {:ok, :ok} = call(cluster, name, Deployments, :sync, [instance(cluster)])
    :ok
  end

  @doc "What a peer applied for each worker: see `Atanor.Deployments.status/1`."
  @spec status(GenServer.server(), atom) :: map
  def status(cluster, name) do
    {:ok, status} = call(cluster, name, Deployments, :status, [instance(cluster)])
    status
  end

  @doc "Halts the peer's VM without any shutdown."
  @spec kill(GenServer.server(), atom) :: :ok
  def kill(cluster, name), do: GenServer.call(cluster, {:kill, name}, @call_ms)

  @doc "SIGKILL to the peer's operating system process: its connections close, as when it crashes."
  @spec kill_process(GenServer.server(), atom) :: :ok
  def kill_process(cluster, name), do: GenServer.call(cluster, {:kill_process, name}, @call_ms)

  @doc "SIGSTOP to the peer's operating system process: it stops answering and keeps its connections."
  @spec pause(GenServer.server(), atom) :: :ok
  def pause(cluster, name), do: GenServer.call(cluster, {:signal, name, "STOP"}, @call_ms)

  @doc "SIGCONT to a peer stopped by `pause/2`."
  @spec resume(GenServer.server(), atom) :: :ok
  def resume(cluster, name), do: GenServer.call(cluster, {:signal, name, "CONT"}, @call_ms)

  @doc """
  Starts a killed peer again with the same name and data directory. The peer
  is connected to the others before its instance starts, as a restarted
  machine is. The call returns when the instance runs. `admin_port:` gives
  the admin listener a port the caller knows, to watch `/health/ready` while
  the instance starts. `atanor:` replaces the options the peer had from
  `:peer_atanor`, as a new release does.
  """
  @spec restart(GenServer.server(), atom, keyword) :: :ok
  def restart(cluster, name, opts \\ []), do: GenServer.call(cluster, {:restart, name, opts}, 120_000)

  @doc "Every store request of the peer fails with `{:error, :partitioned}` until healed."
  @spec partition_store(GenServer.server(), atom) :: :ok
  def partition_store(cluster, name), do: GenServer.call(cluster, {:partition_store, name}, @call_ms)

  @doc "Ends `partition_store/2`."
  @spec heal_store(GenServer.server(), atom) :: :ok
  def heal_store(cluster, name), do: GenServer.call(cluster, {:heal_store, name}, @call_ms)

  @doc "Injects a `MemoryStore` fault (`MemoryStore.inject/2` options) for requests of the peer."
  @spec inject(GenServer.server(), atom, keyword) :: :ok
  def inject(cluster, name, opts), do: GenServer.call(cluster, {:inject, name, opts}, @call_ms)

  @doc "Cuts the link between two peers until `heal_nodes/3`."
  @spec partition_nodes(GenServer.server(), atom, atom) :: :ok
  def partition_nodes(cluster, a, b), do: GenServer.call(cluster, {:partition_nodes, a, b}, 120_000)

  @doc "Restores the link between two peers."
  @spec heal_nodes(GenServer.server(), atom, atom) :: :ok
  def heal_nodes(cluster, a, b), do: GenServer.call(cluster, {:heal_nodes, a, b}, 120_000)

  @doc "Moves the peer's lease clock `ms` away from the real time."
  @spec set_clock_offset(GenServer.server(), atom, integer) :: :ok
  def set_clock_offset(cluster, name, ms), do: GenServer.call(cluster, {:offset, name, ms}, @call_ms)

  @doc "Removes every store fault and restores every link; dead peers stay dead."
  @spec heal_all(GenServer.server()) :: :ok
  def heal_all(cluster), do: GenServer.call(cluster, :heal_all, 120_000)

  @doc "Telemetry events of all peers so far."
  @spec events(GenServer.server()) :: [map]
  def events(cluster), do: GenServer.call(cluster, :events, @call_ms)

  defp handle(cluster) do
    {mod, config} = store(cluster)
    Store.open({mod, config}, GenServer.call(cluster, :prefix, @call_ms))
  end

  defp deploy_all(cluster, manifests) do
    Enum.reduce_while(manifests, :ok, fn manifest, :ok ->
      case deploy(cluster, manifest) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {manifest["name"], reason}}}
      end
    end)
  end

  defp peers(cluster, opts), do: opts[:only] || Enum.filter(names(cluster), &alive?(cluster, &1))

  # A change made through a peer's instance notifies all the others; one made
  # through the store handle tells nobody.
  defp change(cluster, opts, function, args) do
    if opts[:only] do
      apply(Deployments, function, [handle(cluster) | args])
    else
      case Enum.find(names(cluster), &alive?(cluster, &1)) do
        nil -> {:error, :no_live_peer}
        name -> with {:ok, result} <- call(cluster, name, Deployments, function, [instance(cluster) | args]), do: result
      end
    end
  end

  # Every given peer reloads the heads now and must serve `id`.
  defp applied(cluster, worker, id, names) do
    errors =
      for name <- names, reduce: %{} do
        errors ->
          with :ok <- sync(cluster, [name]),
               %{^worker => %{applied: ^id, error: nil}} <- status(cluster, name) do
            errors
          else
            %{^worker => %{error: error}} -> Map.put(errors, name, error)
            other -> Map.put(errors, name, other)
          end
      end

    if errors == %{}, do: {:ok, id}, else: {:error, errors}
  end

  # Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ensure_distributed!()

    names = Keyword.get(opts, :names, [:n1, :n2, :n3])
    {:ok, store_pid} = MemoryStore.start_link()
    run_id = "#{System.pid()}_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "atanor-cluster-#{run_id}")
    File.mkdir_p!(dir)

    state = %{
      store_pid: store_pid,
      store: MemoryStore.config(store_pid),
      dir: dir,
      instance: Keyword.get(opts, :instance, :atanor_cluster),
      prefix: Keyword.get(opts, :prefix, "cluster"),
      opts: opts,
      peer_atanor: Keyword.get(opts, :peer_atanor, %{}),
      cookie: Node.get_cookie(),
      id: run_id,
      peers: %{},
      offsets: %{},
      cuts: MapSet.new(),
      faults: %{},
      events: []
    }

    {:ok, Enum.reduce(names, state, fn name, acc -> start_peer(acc, name) end)}
  end

  @impl true
  def handle_call(:instance, _from, state), do: {:reply, state.instance, state}
  def handle_call(:prefix, _from, state), do: {:reply, state.prefix, state}
  def handle_call(:store, _from, state), do: {:reply, {MemoryStore, state.store}, state}
  def handle_call(:names, _from, state), do: {:reply, state.peers |> Map.keys() |> Enum.sort(), state}
  def handle_call({:peer, name}, _from, state), do: {:reply, state.peers[name], state}
  def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}

  def handle_call({:kill, name}, _from, state) do
    %{peer: peer, node: node} = state.peers[name]
    if peer, do: halt(peer, node)
    {:reply, :ok, put_in(state.peers[name].peer, nil)}
  end

  def handle_call({:kill_process, name}, _from, state) do
    %{os_pid: os_pid} = state.peers[name]
    signal(os_pid, "KILL")
    {:reply, :ok, put_in(state.peers[name].peer, nil)}
  end

  def handle_call({:signal, name, signal}, _from, state) do
    signal(state.peers[name].os_pid, signal)
    {:reply, :ok, state}
  end

  def handle_call({:restart, name, opts}, _from, state) do
    state = if opts[:atanor], do: put_in(state.peer_atanor[name], opts[:atanor]), else: state
    {:reply, :ok, start_peer(state, name, opts)}
  end

  # A second partition of the same peer changes nothing: one heal must end it.
  def handle_call({:partition_store, name}, _from, state) do
    if Map.has_key?(state.faults, {:partition, name}) do
      {:reply, :ok, state}
    else
      id = MemoryStore.partition(state.store, state.peers[name].node)
      {:reply, :ok, put_in(state.faults[{:partition, name}], id)}
    end
  end

  def handle_call({:heal_store, name}, _from, state) do
    {id, faults} = Map.pop(state.faults, {:partition, name})
    if id, do: MemoryStore.remove(state.store, id)
    {:reply, :ok, %{state | faults: faults}}
  end

  def handle_call({:inject, name, opts}, _from, state) do
    id = MemoryStore.inject(state.store, Keyword.put(opts, :node, state.peers[name].node))
    {:reply, :ok, put_in(state.faults[{:fault, make_ref()}], id)}
  end

  def handle_call({:partition_nodes, a, b}, _from, state), do: {:reply, :ok, cut(state, a, b)}
  def handle_call({:heal_nodes, a, b}, _from, state), do: {:reply, :ok, mend(state, a, b)}

  def handle_call({:offset, name, ms}, _from, state) do
    state = put_in(state.offsets[name], ms)
    if state.peers[name].peer, do: set_offset(state.peers[name].node, ms)
    {:reply, :ok, state}
  end

  def handle_call(:heal_all, _from, state) do
    MemoryStore.clear(state.store)
    state = Enum.reduce(state.cuts, %{state | faults: %{}}, fn {a, b}, acc -> mend(acc, a, b) end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:telemetry, name, event, measurements, meta, at}, state) do
    entry = %{node: name, event: event, measurements: measurements, meta: meta, at: at}
    {:noreply, %{state | events: [entry | state.events]}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_name, %{peer: peer, node: node, os_pid: os_pid}} <- state.peers, peer != nil do
      # A stopped process would never answer the stop.
      signal(os_pid, "CONT")

      try do
        cover_flush(node)
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end

    File.rm_rf(state.dir)
  end

  # Peers

  defp start_peer(state, name, opts \\ []) do
    old_node = state.peers[name][:node]

    peer_name =
      if old_node,
        do: old_node |> Atom.to_string() |> String.split("@") |> hd(),
        else: "atanor_#{state.id}_#{name}"

    args = Enum.flat_map(:code.get_path(), &[~c"-pz", &1]) ++ [~c"-connect_all", ~c"false"]

    {peer, node} =
      start_with_retry(%{
        name: String.to_charlist(peer_name),
        host: ~c"127.0.0.1",
        longnames: true,
        args: args,
        wait_boot: 30_000
      })

    cover_start(node)
    os_pid = :erpc.call(node, :os, :getpid, [])
    state = put_in(state.peers[name], %{peer: peer, node: node, os_pid: os_pid, port: nil, admin_port: nil})

    for {other, %{peer: other_peer, node: other_node}} <- state.peers,
        other != name,
        other_peer != nil,
        not cut?(state, name, other) do
      :erpc.call(node, Node, :connect, [other_node])
    end

    {port, admin_port} = boot(state, name, node, opts)
    update_in(state.peers[name], &%{&1 | port: port, admin_port: admin_port})
  end

  # A restarted VM reuses its name; the old registration may take a moment to go.
  defp start_with_retry(opts, attempts \\ 50) do
    case :peer.start(opts) do
      {:ok, peer, node} ->
        {peer, node}

      {:error, _} when attempts > 1 ->
        Process.sleep(100)
        start_with_retry(opts, attempts - 1)

      {:error, reason} ->
        raise "could not start peer: #{inspect(reason)}"
    end
  end

  defp boot(state, name, node, restart_opts) do
    opts = state.opts

    alambique =
      Keyword.merge(
        [
          clock: {AlambiqueTestkit.Clock, nil},
          lease_ttl_ms: Keyword.get(opts, :ttl_ms, 2_000),
          skew_margin_ms: Keyword.get(opts, :skew_margin_ms, 400),
          idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000),
          op_timeout_ms: Keyword.get(opts, :op_timeout_ms, 1_500)
        ],
        Keyword.get(opts[:atanor] || [], :alambique, [])
      )

    own = Map.get(state.peer_atanor, name, [])

    atanor_opts =
      Keyword.merge(
        [poll_interval_ms: 500, port: 0, admin: [token: @token, port: restart_opts[:admin_port] || 0]],
        Keyword.merge(Keyword.drop(opts[:atanor] || [], [:alambique]), own)
      ) ++
        [
          name: state.instance,
          prefix: state.prefix,
          data_dir: Path.join(state.dir, node |> Atom.to_string() |> String.split("@") |> hd()),
          store: {MemoryStore, state.store},
          alambique: alambique
        ]

    boot_ms = Keyword.get(opts, :boot_timeout_ms, @boot_timeout_ms)
    boot_args = [atanor_opts, Keyword.get(opts, :wasm), self(), name, @forwarded, boot_ms]
    ports = :erpc.call(node, __MODULE__.Boot, :start, boot_args, boot_ms + 30_000)
    set_offset(node, Map.get(state.offsets, name, 0))
    ports
  end

  # Under `mix test --cover` the peers count the code they run too; flush/1 merges their counters into the
  # test VM before the peer stops. A peer that is killed or halted loses its counters.
  defp cover_start(node), do: if(Process.whereis(:cover_server), do: :cover.start([node]))
  defp cover_flush(node), do: if(Process.whereis(:cover_server), do: :cover.flush(node))

  defp signal(os_pid, signal), do: System.cmd("kill", ["-" <> signal, List.to_string(os_pid)], stderr_to_stdout: true)

  defp set_offset(node, ms), do: :erpc.call(node, AlambiqueTestkit.Clock, :set_offset, [ms])

  defp halt(peer, node) do
    :erpc.cast(node, :erlang, :halt, [1, [flush: false]])

    try do
      :peer.stop(peer)
    catch
      _, _ -> :ok
    end
  end

  # Links

  defp cut(state, a, b) do
    na = state.peers[a].node
    nb = state.peers[b].node

    for {from, to_node} <- [{na, nb}, {nb, na}], running?(state, from) do
      link_call(from, :erlang, :set_cookie, [to_node, partitioned_cookie(from)])
      link_call(from, Node, :disconnect, [to_node])
    end

    %{state | cuts: MapSet.put(state.cuts, key(a, b))}
  end

  # Each side gets another cookie for the other, so that no handshake succeeds,
  # whoever tries to connect.
  defp partitioned_cookie(node), do: String.to_atom("atanor_partitioned_" <> Atom.to_string(node))

  defp mend(state, a, b) do
    na = state.peers[a].node
    nb = state.peers[b].node

    # Casts are queued even for a paused peer, so the cut is lifted and it
    # reconnects by itself once resumed. Only the connect can wait.
    for {from, to_node} <- [{na, nb}, {nb, na}], running?(state, from) do
      :erpc.cast(from, :erlang, :set_cookie, [to_node, state.cookie])
    end

    if running?(state, na) and running?(state, nb), do: link_call(na, Node, :connect, [nb])
    %{state | cuts: MapSet.delete(state.cuts, key(a, b))}
  end

  defp cut?(state, a, b), do: MapSet.member?(state.cuts, key(a, b))
  defp key(a, b), do: if(a < b, do: {a, b}, else: {b, a})

  defp running?(state, node), do: Enum.any?(state.peers, fn {_, p} -> p.node == node and p.peer != nil end)

  # A paused or half-connected peer can stall a handshake for net_setuptime
  # (7 s) or more, so link calls are bounded and a timeout is not fatal.
  defp link_call(node, m, f, a) do
    :erpc.call(node, m, f, a, 10_000)
  catch
    :error, {:erpc, _} -> :error
  end

  defp ensure_distributed! do
    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])
      {:ok, _} = Node.start(:"atanor_test_#{System.pid()}@127.0.0.1", :longnames)
    end
  end

  defmodule Boot do
    @moduledoc false
    # Runs on a peer: starts the application, the instance and the telemetry relay.
    # On a boot timeout it reports where the instance supervisor tree is stuck.

    @ring :atanor_boot_ring
    @ring_size 30
    @max_procs 40
    @depth 6

    def start(atanor_opts, wasm, collector, name, events, boot_ms) do
      if wasm, do: Application.put_env(:atanor, :wasm, wasm)
      {:ok, _} = Application.ensure_all_started(:atanor)
      # The console shows errors only; the ring keeps warnings and errors for a timeout report.
      :logger.set_primary_config(:level, :warning)
      :logger.set_handler_config(:default, :level, :error)
      ensure_ring()
      :logger.add_handler(@ring, __MODULE__, %{level: :warning})
      :telemetry.attach_many({__MODULE__, name}, events, &__MODULE__.relay/4, {collector, name})

      parent = self()

      {starter, ref} =
        spawn_monitor(fn ->
          # Temporary: a stopped instance stays stopped, as after a release stop. A permanent
          # child would be restarted at once and serve (and fail) requests before it applied a worker.
          child = Supervisor.child_spec({Atanor, atanor_opts}, restart: :temporary)
          send(parent, {:started, Supervisor.start_link([child], strategy: :one_for_one)})
          Process.sleep(:infinity)
        end)

      :ok = await(starter, ref, boot_ms)
      instance = Keyword.fetch!(atanor_opts, :name)
      {Atanor.port(instance), Atanor.admin_port(instance)}
    end

    @doc false
    # Waits for the start the `starter` reports. A starter that dies first (a module that fails to
    # load, a crash before the supervisor) is reported at once instead of after `boot_ms`.
    def await(starter, ref, boot_ms) do
      receive do
        {:started, {:ok, _}} ->
          Process.demonitor(ref, [:flush])
          :ok

        {:started, error} ->
          raise "instance did not start: #{inspect(error)}"

        {:DOWN, ^ref, :process, ^starter, reason} ->
          raise "instance starter exited before the instance started: #{inspect(reason)}"
      after
        boot_ms -> raise "instance did not start within #{boot_ms} ms\n#{report(starter)}"
      end
    end

    def relay(event, measurements, meta, {collector, name}),
      do: send(collector, {:telemetry, name, event, measurements, meta, System.os_time(:microsecond)})

    # :logger handler callback: keeps the last @ring_size events.
    def log(event, _config) do
      :ets.insert(@ring, {System.unique_integer([:monotonic]), format(event)})
      if :ets.info(@ring, :size) > @ring_size, do: :ets.delete(@ring, :ets.first(@ring))
      :ok
    rescue
      _ -> :ok
    end

    defp format(%{level: level, msg: msg, meta: meta}) do
      text =
        case msg do
          {:string, s} -> IO.chardata_to_string(s)
          {:report, r} -> inspect(r, limit: 20, printable_limit: 400)
          {fmt, args} -> fmt |> :io_lib.format(args) |> IO.chardata_to_string()
        end

      "[#{level}] #{inspect(meta[:pid])} #{String.slice(text, 0, 1500)}"
    end

    defp ensure_ring,
      do: if(:ets.whereis(@ring) == :undefined, do: :ets.new(@ring, [:named_table, :public, :ordered_set]))

    @doc false
    # The processes under the starter that are not idle, with their stacks, and the recent logs.
    def report(starter) do
      ensure_ring()
      {procs, _} = walk([starter], MapSet.new([starter]), 0, [])
      shown = procs |> Enum.reverse() |> Enum.take(@max_procs)
      logs = for {_, line} <- :ets.tab2list(@ring), do: "  " <> line

      "Stuck processes (supervisor tree from the starter, idle ones left out):\n" <>
        Enum.map_join(shown, "\n", &describe/1) <>
        "\nRecent peer log (oldest first):\n" <> Enum.join(logs, "\n")
    end

    defp walk(_pids, _seen, @depth, acc), do: {acc, nil}

    defp walk(pids, seen, depth, acc) do
      {next, seen, acc} =
        Enum.reduce(pids, {[], seen, acc}, fn pid, {next, seen, acc} ->
          info = Process.info(pid, [:links, :registered_name, :current_stacktrace, :message_queue_len, :status])
          if info == nil, do: {next, seen, acc}, else: step(pid, info, depth, {next, seen, acc})
        end)

      walk(next, seen, depth + 1, acc)
    end

    defp step(pid, info, depth, {next, seen, acc}) do
      children = for p <- info[:links], is_pid(p), p not in seen, node(p) == node(), do: p
      acc = if idle?(info[:current_stacktrace]), do: acc, else: [{pid, depth, info} | acc]
      {children ++ next, Enum.into(children, seen), acc}
    end

    defp idle?([{mod, fun, _, _} | _]),
      do: {mod, fun} in [{:gen_server, :loop}, {:gen_statem, :loop_receive}, {:supervisor, :loop}]

    defp idle?(_), do: false

    defp describe({pid, depth, info}) do
      stack = info[:current_stacktrace] |> Enum.take(12) |> Exception.format_stacktrace() |> String.trim_trailing()
      name = if info[:registered_name] in [nil, []], do: "", else: " #{inspect(info[:registered_name])}"

      "- #{inspect(pid)}#{name} depth=#{depth} status=#{info[:status]} mql=#{info[:message_queue_len]}\n#{stack}"
    end
  end
end
