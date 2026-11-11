defmodule Atanor.Registry do
  @moduledoc """
  The node's tables, readable without a process hop (design §2): the instance
  config, the active deployment of each worker, the routes and the cell
  namespaces. The table references live in `:persistent_term`; reads are ETS
  lookups. Writes go through the owning process, which serializes activations
  and checks them against the other workers. One more table, written by any
  process and bounded, holds the pinned deployments of forwarded requests
  (design §8).
  """
  use GenServer

  alias Atanor.{Config, Deployment, Manifest, Route}

  @tables [:state, :workers, :pins, :routes, :listeners, :namespaces, :partitions]
  # Public table written by any process; emptied when it reaches its limit.
  @shared [:pinned, :verified, :fence, :holds, :unknown_tokens, :takeover_throttle, :attempts]

  def child_spec(%Config{} = config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: server(config.name)]]}}
  end

  @doc "The table of the `:no_quorum` event throttle (`Atanor.Takeover.Throttle`)."
  @spec takeover_throttle(atom) :: :ets.table()
  def takeover_throttle(name), do: tables(name).takeover_throttle

  @doc "The config of a running instance. It does not change, so it is kept in `:persistent_term` and not copied."
  @spec config(atom) :: Config.t()
  def config(name), do: tables(name).instance

  @typedoc "The node's lifecycle (design §2.1); `:starting` carries the reason it is not ready."
  @type state :: {:starting, String.t()} | :ready | :draining | :stopping

  @doc "The lifecycle state of the node."
  @spec state(atom) :: state
  def state(name) do
    [{:state, state}] = :ets.lookup(tables(name).state, :state)
    state
  end

  @doc "Sets the lifecycle state of the node."
  @spec put_state(atom, state) :: :ok
  def put_state(name, state), do: GenServer.call(server(name), {:state, state})

  @doc "The node serves: it applied its deployments, joined the cluster and started its jobs and feeds."
  @spec ready(atom) :: :ok
  def ready(name) do
    :ok = put_state(name, :ready)
    :telemetry.execute([:atanor, :node, :ready], %{}, %{instance: name, node: node()})
  end

  @doc "Name of the Bandit listener process of the instance."
  def http_listener(name), do: Module.concat(name, HTTP)

  @doc "The active deployment of a worker."
  @spec deployment(atom, String.t()) :: {:ok, Deployment.t()} | :error
  def deployment(name, worker) do
    case :ets.lookup(tables(name).workers, worker) do
      [{_, deployment}] -> {:ok, deployment}
      [] -> :error
    end
  end

  @doc "The id and the `workers` bindings of the active deployment of a worker; only these are copied."
  @spec pin(atom, String.t()) :: {:ok, String.t(), [String.t()]} | :error
  def pin(name, worker) do
    case :ets.lookup(tables(name).pins, worker) do
      [{_, id, workers}] -> {:ok, id, workers}
      [] -> :error
    end
  end

  @doc "The active deployments of the node."
  @spec deployments(atom) :: [Deployment.t()]
  def deployments(name), do: for({_, d} <- :ets.tab2list(tables(name).workers), do: d)

  @doc "HTTP routes registered on this node as `{host, path, worker}`."
  @spec routes(atom) :: [{String.t(), String.t(), String.t()}]
  def routes(name),
    do: for({{host, path}, d} <- :ets.tab2list(tables(name).routes), do: {host, path, Deployment.worker(d)})

  @doc """
  The deployment that serves a request, for the canonical host and path of `Atanor.Route`: the exact host first, then wildcard
  hosts from the most to the least specific (`*.a.b.test` before `*.b.test`),
  then the catch-all `*`, which matches any host, an IP address included. On
  the first host with a matching route, the longest path prefix decides.
  """
  @spec match_route(atom, String.t(), String.t()) :: {:ok, Deployment.t()} | :error
  def match_route(name, host, path) do
    with {:ok, deployment, _route} <- match(name, host, path), do: {:ok, deployment}
  end

  @doc "As `match_route/3`, also naming the manifest route that matched: `{host_pattern, path_prefix}`."
  @spec match(atom, String.t(), String.t()) :: {:ok, Deployment.t(), {String.t(), String.t()}} | :error
  def match(name, host, path) do
    routes = tables(name).routes
    prefixes = Route.path_prefixes(path)
    Enum.find_value(Route.host_candidates(host), :error, &match_path(routes, &1, prefixes))
  end

  @doc "The deployment that claims TCP listener `listener`."
  @spec listener(atom, String.t()) :: {:ok, Deployment.t()} | :error
  def listener(name, listener) do
    case :ets.lookup(tables(name).listeners, listener) do
      [{_, deployment}] -> {:ok, deployment}
      [] -> :error
    end
  end

  @doc "The names of the TCP listeners claimed by active deployments."
  @spec listeners(atom) :: [String.t()]
  def listeners(name), do: for({listener, _} <- :ets.tab2list(tables(name).listeners), do: listener)

  @doc """
  The migrations of a cell namespace granted by an active worker or, failing
  that, by the pinned deployment with the most migrations (design §8.3).
  """
  @spec namespace(atom, String.t()) :: {:ok, [Atanor.Manifest.migration()]} | :error
  def namespace(name, ns) do
    tables = tables(name)

    case :ets.lookup(tables.namespaces, ns) do
      [{_, migrations}] -> {:ok, migrations}
      [] -> pinned_namespace(tables.pinned, ns)
    end
  end

  @doc """
  The number of partitions of a namespace (design §4.2): `nil` when it is not
  partitioned. Answers from the active workers and, failing that, from the
  pinned deployments, like `namespace/2`.
  """
  @spec partitions(atom, String.t()) :: pos_integer | nil
  def partitions(name, ns) do
    tables = tables(name)

    case :ets.lookup(tables.partitions, ns) do
      [{_, n}] ->
        n

      [] ->
        # A namespace of an active worker without partitions has no entry; the pinned ones count only without it.
        if :ets.member(tables.namespaces, ns),
          do: nil,
          else: Enum.find_value(:ets.tab2list(tables.pinned), fn {_, d} -> d.manifest.partitions[ns] end)
    end
  end

  defp pinned_namespace(pinned, ns) do
    lists = for {_, d} <- :ets.tab2list(pinned), migrations = d.manifest.cells[ns], do: migrations

    case lists do
      [] -> :error
      _ -> {:ok, Enum.max_by(lists, &length/1)}
    end
  end

  @doc "A deployment that is not active on this node but that a forwarded request is pinned to (design §8)."
  @spec pinned(atom, String.t()) :: {:ok, Deployment.t()} | :error
  def pinned(name, id) do
    case :ets.lookup(tables(name).pinned, id) do
      [{_, deployment}] -> {:ok, deployment}
      [] -> :error
    end
  end

  @doc "Whether this node read the lease of cell `id` from the store within the last `within_ms`."
  @spec verified?(atom, String.t(), pos_integer) :: boolean
  def verified?(name, id, within_ms) do
    case :ets.lookup(tables(name).verified, id) do
      [{_, at, _}] -> System.monotonic_time(:millisecond) - at < within_ms
      [] -> false
    end
  end

  @doc """
  Records that the lease of cell `id` was read from the store, keeping at most `limit` cells. `at` is when the
  read started (monotonic ms, default now).
  """
  @spec put_verified(atom, String.t(), pos_integer, integer) :: true
  def put_verified(name, id, limit, at \\ System.monotonic_time(:millisecond)),
    do: insert(tables(name).verified, limit, {id, at, nil})

  @doc """
  Whether the caller may read the lease of cell `id` ahead of time: the last read is `age_ms` old or more, and
  no other process claimed a read within `retry_ms`. One caller wins; a read that is stored clears the claim.
  """
  @spec claim_refresh(atom, String.t(), non_neg_integer, pos_integer) :: boolean
  def claim_refresh(name, id, age_ms, retry_ms) do
    table = tables(name).verified
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, id) do
      [{_, at, claim}] when now - at >= age_ms and (claim == nil or now - claim >= retry_ms) ->
        :ets.select_replace(table, [{{id, at, claim}, [], [{{id, at, now}}]}]) == 1

      _ ->
        false
    end
  end

  @doc "Whether this node found no admin token `id` in the store within the last `within_ms`."
  @spec unknown_token?(atom, String.t(), pos_integer) :: boolean
  def unknown_token?(name, id, within_ms) do
    case :ets.lookup(tables(name).unknown_tokens, id) do
      [{_, at}] -> System.monotonic_time(:millisecond) - at < within_ms
      [] -> false
    end
  end

  @doc "Records that the store has no admin token `id`, keeping at most `limit` ids."
  @spec put_unknown_token(atom, String.t(), pos_integer) :: true
  def put_unknown_token(name, id, limit),
    do: insert(tables(name).unknown_tokens, limit, {id, System.monotonic_time(:millisecond)})

  @doc "The table of failed token attempts per client address (`Atanor.Admin.Throttle`)."
  @spec attempts(atom) :: :ets.table()
  def attempts(name), do: tables(name).attempts

  @doc "The lease of cell `id` this node last read: `{id, :owned | :lost, epoch, deadline_ms, read_at}`, or nil."
  @spec fence_entry(atom, String.t()) :: tuple | nil
  def fence_entry(name, id) do
    case :ets.lookup(tables(name).fence, id) do
      [entry] -> entry
      [] -> nil
    end
  end

  @doc "Until when (lease clock) this node starts no job or alarm handler for cell `id`, or nil."
  @spec fence_hold(atom, String.t()) :: integer | nil
  def fence_hold(name, id) do
    case :ets.lookup(tables(name).holds, id) do
      [{_, until}] -> until
      [] -> nil
    end
  end

  @doc """
  Holds the job and alarm handlers of cell `id` until `until`. Holds are not a cache: the bound of the other
  tables never evicts one. Those that ended before `now` are deleted here, so the table holds the live ones.
  """
  @spec fence_put_hold(atom, String.t(), integer, integer) :: true
  def fence_put_hold(name, id, until, now) do
    table = tables(name).holds
    :ets.select_delete(table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    :ets.insert(table, {id, until})
  end

  @doc "Forgets the hold of cell `id` that ended at `until`, unless a later one replaced it."
  @spec fence_delete_hold(atom, String.t(), integer) :: true
  def fence_delete_hold(name, id, until), do: :ets.match_delete(tables(name).holds, {id, until})

  @doc "Stores a lease entry of `Atanor.Fence`, keeping at most `limit` cells, and returns it."
  @spec fence_put(atom, pos_integer, tuple) :: tuple
  def fence_put(name, limit, entry) do
    insert(tables(name).fence, limit, entry)
    entry
  end

  @doc "Moves the read time of cell `id` from `from` to `to`; false when another process did it first."
  @spec fence_touch(atom, String.t(), integer, integer) :: boolean
  def fence_touch(name, id, from, to) do
    spec = [{{id, :"$1", :"$2", :"$3", from}, [], [{{id, :"$1", :"$2", :"$3", to}}]}]
    :ets.select_replace(tables(name).fence, spec) == 1
  end

  @doc """
  Records a lease read of cell `id`. Within an epoch the expiry only grows and a loss stays; a higher epoch
  replaces the entry and a lower one is ignored. A late write that lowers an expiry is safe: it is a bound.
  """
  @spec fence_merge(atom, pos_integer, String.t(), :owned | :lost, non_neg_integer, integer | nil, integer) :: true
  def fence_merge(name, limit, id, status, epoch, deadline, read_at) do
    entry =
      case fence_entry(name, id) do
        {_, _, old, _, _} when old > epoch -> nil
        {_, :lost, ^epoch, _, _} = kept -> put_elem(kept, 4, read_at)
        {_, :owned, ^epoch, old, _} when status == :owned -> {id, :owned, epoch, max(old, deadline), read_at}
        _ -> {id, status, epoch, deadline, read_at}
      end

    if entry, do: insert(tables(name).fence, limit, entry), else: true
  end

  @doc "Keeps a pinned deployment for later forwarded requests, up to `:routing`'s `:pinned_limit`."
  @spec put_pinned(atom, Deployment.t()) :: true
  def put_pinned(name, %Deployment{id: id} = deployment),
    do: insert(tables(name).pinned, config(name).routing.pinned_limit, {id, deployment})

  @doc """
  Makes `deployment` the active one of its worker. Refused when a namespace it
  grants has other migrations than another worker's or fewer than its own
  previous version, when a route belongs to another worker, or when the
  operator's `:hosts`, `:listeners`, `:http_allow` and `:modules` do not allow
  what the manifest asks (design §3.3, §7). Returns the namespaces that are
  new or got more migrations.
  """
  @spec put(atom, Deployment.t()) :: {:ok, [String.t()]} | {:error, term}
  def put(name, %Deployment{} = deployment), do: GenServer.call(server(name), {:put, deployment})

  @doc """
  Runs the checks of `put/2` for `manifest` without changing anything, so that
  an activation that this node would refuse is refused before its head is
  written (design §5.2).
  """
  @spec check(atom, Manifest.t()) :: :ok | {:error, term}
  def check(name, %Manifest{} = manifest), do: GenServer.call(server(name), {:check, manifest})

  @doc "Removes a worker and its routes."
  @spec delete(atom, String.t()) :: :ok | {:error, :not_active}
  def delete(name, worker), do: GenServer.call(server(name), {:delete, worker})

  # At the bound a sixteenth of the table goes, so a working set past the bound keeps most of its entries.
  defp insert(table, limit, entry) do
    if :ets.info(table, :size) >= limit, do: evict(table, max(div(limit, 16), 1))
    :ets.insert(table, entry)
  end

  # Other processes write the table meanwhile, so the objects are selected and deleted one by one: a walk with
  # `:ets.next/2` raises when its key has gone.
  @doc false
  def evict(table, count) do
    case :ets.select(table, [{:"$1", [], [:"$1"]}], count) do
      {objects, _continuation} -> Enum.each(objects, &:ets.delete_object(table, &1))
      :"$end_of_table" -> :ok
    end
  end

  defp server(name), do: Module.concat(name, Registrar)
  defp tables(name), do: :persistent_term.get({__MODULE__, name})

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    tables =
      Map.new(@tables, &{&1, :ets.new(&1, [:set, :protected, read_concurrency: true])})
      |> Map.merge(Map.new(@shared, &{&1, :ets.new(&1, [:set, :public, read_concurrency: true])}))

    tables = Map.put(tables, :instance, config)
    :persistent_term.put({__MODULE__, config.name}, tables)
    :ets.insert(tables.state, {:state, {:starting, "deployments not loaded"}})
    {:ok, tables}
  end

  @impl true
  def handle_call({:state, state}, _from, tables) do
    :ets.insert(tables.state, {:state, state})
    {:reply, :ok, tables}
  end

  def handle_call({:put, deployment}, _from, tables), do: {:reply, put_deployment(tables, deployment), tables}

  def handle_call({:check, manifest}, _from, tables),
    do:
      {:reply, with({:ok, _} <- validate(tables, %Deployment{id: nil, module: nil, manifest: manifest}), do: :ok),
       tables}

  def handle_call({:delete, worker}, _from, tables) do
    reply =
      case :ets.lookup(tables.workers, worker) do
        [{_, deployment}] ->
          :ets.delete(tables.workers, worker)
          :ets.delete(tables.pins, worker)
          for key <- route_keys(deployment), do: :ets.delete(tables.routes, key)
          for listener <- listener_names(deployment), do: :ets.delete(tables.listeners, listener)
          with {:ok, _} <- refresh_namespaces(tables), do: :ok

        [] ->
          {:error, :not_active}
      end

    {:reply, reply, tables}
  end

  @impl true
  def terminate(_reason, tables), do: :persistent_term.erase({__MODULE__, tables.instance.name})

  defp validate(tables, %Deployment{manifest: manifest} = deployment) do
    previous =
      case :ets.lookup(tables.workers, manifest.name) do
        [{_, d}] -> d
        [] -> nil
      end

    others = for {w, d} <- :ets.tab2list(tables.workers), w != manifest.name, do: d

    with :ok <- check_namespaces(manifest, previous, others),
         :ok <- check_approved(tables.instance, manifest),
         :ok <- check_routes(tables, deployment),
         do: {:ok, previous}
  end

  defp put_deployment(tables, %Deployment{manifest: manifest} = deployment) do
    with {:ok, previous} <- validate(tables, deployment) do
      keys = route_keys(deployment)
      for key <- keys, do: :ets.insert(tables.routes, {key, deployment})
      listeners = listener_names(deployment)
      for listener <- listeners, do: :ets.insert(tables.listeners, {listener, deployment})
      :ets.insert(tables.workers, {manifest.name, deployment})
      :ets.insert(tables.pins, {manifest.name, deployment.id, manifest.workers})

      if previous do
        for key <- route_keys(previous) -- keys, do: :ets.delete(tables.routes, key)
        for listener <- listener_names(previous) -- listeners, do: :ets.delete(tables.listeners, listener)
      end

      refresh_namespaces(tables)
    end
  end

  defp check_namespaces(manifest, previous, others) do
    Enum.find_value(manifest.cells, :ok, fn {ns, migrations} ->
      conflict =
        Enum.find(others, fn other ->
          is_map_key(other.manifest.cells, ns) and
            (other.manifest.cells[ns] != migrations or other.manifest.partitions[ns] != manifest.partitions[ns])
        end)

      lowered? = previous && length(Map.get(previous.manifest.cells, ns, [])) > length(migrations)

      cond do
        conflict -> {:error, {:namespace_conflict, ns, Deployment.worker(conflict)}}
        lowered? -> {:error, {:migrations_lowered, ns}}
        true -> nil
      end
    end)
  end

  # The manifest declares routes and grants; they are active only when the operator allows them.
  defp check_approved(config, manifest) do
    with :ok <- check_routes_approved(config, manifest),
         :ok <- check_http_allow(config, manifest),
         do: check_module(config, manifest)
  end

  defp check_routes_approved(config, manifest) do
    Enum.find_value(manifest.routes, :ok, fn
      {:http, host, _path} ->
        allowed? =
          config.hosts == nil or Enum.any?(Map.get(config.hosts, manifest.name, []), &Manifest.host_covered?(&1, host))

        if allowed?, do: nil, else: {:error, {:host_not_allowed, host, manifest.name}}

      {:tcp, listener, protocol} ->
        case Map.get(config.listeners, listener) do
          nil ->
            {:error, {:listener_not_configured, listener}}

          %{protocol: configured} when configured != protocol ->
            {:error, {:listener_protocol_mismatch, listener, protocol, configured}}

          %{workers: workers} when is_list(workers) ->
            if manifest.name in workers, do: nil, else: {:error, {:listener_not_allowed, listener, manifest.name}}

          _ ->
            nil
        end
    end)
  end

  # The operator's ceiling on what a worker may grant itself in `http.allow`.
  defp check_http_allow(%{http_allow: nil}, _manifest), do: :ok

  defp check_http_allow(%{http_allow: ceiling}, manifest) do
    patterns = Map.get(ceiling, manifest.name, [])

    Enum.find_value(manifest.http_allow, :ok, fn {_scheme, host, _port} ->
      if Enum.any?(patterns, &Manifest.allow_covered?(&1, host)),
        do: nil,
        else: {:error, {:http_not_allowed, host, manifest.name}}
    end)
  end

  # The operator's list of the native modules a worker may bind.
  defp check_module(%{modules: nil}, _manifest), do: :ok
  defp check_module(_config, %Manifest{kind: :wasm}), do: :ok

  defp check_module(%{modules: modules}, manifest) do
    if manifest.module in Map.get(modules, manifest.name, []),
      do: :ok,
      else: {:error, {:module_not_allowed, manifest.module, manifest.name}}
  end

  defp check_routes(tables, deployment) do
    worker = Deployment.worker(deployment)

    http =
      Enum.find_value(route_keys(deployment), fn {host, path} = key ->
        case :ets.lookup(tables.routes, key) do
          [{_, other}] when other.manifest.name != worker ->
            {:error, {:route_taken, host, path, Deployment.worker(other)}}

          _ ->
            nil
        end
      end)

    http ||
      Enum.find_value(listener_names(deployment), :ok, fn listener ->
        case :ets.lookup(tables.listeners, listener) do
          [{_, other}] when other.manifest.name != worker ->
            {:error, {:listener_taken, listener, Deployment.worker(other)}}

          _ ->
            nil
        end
      end)
  end

  defp route_keys(deployment), do: for({:http, host, path} <- deployment.manifest.routes, do: {host, path})
  defp listener_names(deployment), do: for({:tcp, listener, _protocol} <- deployment.manifest.routes, do: listener)

  defp refresh_namespaces(tables) do
    current =
      for {_, d} <- :ets.tab2list(tables.workers), {ns, migrations} <- d.manifest.cells, into: %{}, do: {ns, migrations}

    previous = Map.new(:ets.tab2list(tables.namespaces))
    for {ns, migrations} <- current, do: :ets.insert(tables.namespaces, {ns, migrations})
    for {ns, _} <- previous, not is_map_key(current, ns), do: :ets.delete(tables.namespaces, ns)

    partitions = for {_, d} <- :ets.tab2list(tables.workers), {ns, n} <- d.manifest.partitions, into: %{}, do: {ns, n}
    :ets.insert(tables.partitions, Map.to_list(partitions))

    for {ns, _} <- :ets.tab2list(tables.partitions),
        not is_map_key(partitions, ns),
        do: :ets.delete(tables.partitions, ns)

    {:ok,
     for(
       {ns, migrations} <- current,
       length(migrations) > length(Map.get(previous, ns, [])) or not is_map_key(previous, ns),
       do: ns
     )}
  end

  defp match_path(routes, host, prefixes) do
    Enum.find_value(prefixes, fn prefix ->
      case :ets.lookup(routes, {host, prefix}) do
        [{_, deployment}] -> {:ok, deployment, {host, prefix}}
        [] -> nil
      end
    end)
  end
end
