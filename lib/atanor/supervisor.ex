defmodule Atanor.Supervisor do
  @moduledoc false
  use Supervisor

  require Logger

  alias Atanor.{Config, Registry}

  @data_dir_errors [:data_dir_in_use, :data_dir_case_insensitive, :data_dir_unusable]

  def start_link(%Config{} = config) do
    case Supervisor.start_link(__MODULE__, config, name: Module.concat(config.name, Supervisor)) do
      {:error, {:shutdown, {:failed_to_start_child, {Alambique, _}, reason}}}
      when elem(reason, 0) in @data_dir_errors ->
        Logger.error("atanor: #{data_dir_message(reason)}")
        {:error, reason}

      other ->
        other
    end
  end

  defp data_dir_message({:data_dir_in_use, path}),
    do: "data_dir #{inspect(path)} is held by another running instance; give each instance its own data_dir"

  defp data_dir_message({:data_dir_case_insensitive, path}),
    do: "data_dir #{inspect(path)} is on a case-insensitive file system; use a case-sensitive one"

  defp data_dir_message({:data_dir_unusable, path, reason}),
    do: "data_dir #{inspect(path)} cannot be locked: #{inspect(reason)}"

  @impl true
  def init(config) do
    log_awake_budget(config)

    children =
      [
        {Registry, config},
        {Atanor.Admission, config},
        {Atanor.Wasm.Cache, config}
      ] ++
        auth(config) ++
        [
          # Starts without joining the cluster: the node takes cells when the `ready` task joins it.
          {Alambique, config.alambique_opts},
          {Atanor.Diagnostics, config}
        ] ++
        discovery(config) ++
        disk(config) ++
        [
          # Children stop in reverse order: listeners close, the jobs get `stop.jobs_ms` to finish, the tasks
          # still running are cancelled, then the detector tells the peers that the node leaves, then the
          # cells are handed off, then Alambique stops. The tasks use the tables of the children before them.
          {Atanor.Drain, config},
          # The detector's own tasks (connects, probes) use no table and run from its first tick.
          Atanor.Detector.tasks_spec(config.name),
          {Atanor.Detector, config},
          {Atanor.Tasks, config}
        ] ++
        admin(config) ++
        [
          # The first load of the deployments finishes here, before the node joins (design §2.1).
          {Atanor.Deployments.Watcher, config},
          {Atanor.Jobs.Slots, config},
          {Atanor.Jobs.Drain, config},
          Supervisor.child_spec({Atanor.Sweeps.Supervisor, config}, shutdown: config.stop.sweeps_ms),
          {Atanor.Sweeps.Manager, config},
          {Atanor.Feed.Supervisor, config},
          {Atanor.Alarms.Scheduler, config}
        ] ++
        hot_cells(config) ++
        [
          %{id: :ready, start: {__MODULE__, :ready, [config]}},
          {Atanor.TCP.TLS, config},
          {Atanor.TCP, config},
          {Bandit,
           plug: {Atanor.HTTP, name: config.name},
           scheme: :http,
           ip: config.ip,
           port: config.port,
           startup_log: false,
           http_2_options: [enabled: config.http.http_2],
           thousand_island_options:
             listener_options(config.http) ++
               [
                 shutdown_timeout: config.stop.connections_ms,
                 supervisor_options: [name: Registry.http_listener(config.name)]
               ]}
        ] ++ dashboard(config)

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc false
  # Everything the node needs to serve runs: peers may choose it from here, then the listeners
  # open. Runs in the start of the child, so the next child starts after it and `:ignore` keeps no process.
  def ready(config) do
    :ok = Alambique.join(config.alambique)
    Registry.ready(config.name)
    :ignore
  end

  # ThousandIsland counts connections per acceptor, so the total cap is the rounded-up share of each.
  defp listener_options(%{max_connections: max, acceptors: acceptors, read_timeout_ms: read_timeout_ms}),
    do: [num_acceptors: acceptors, num_connections: div(max + acceptors - 1, acceptors), read_timeout: read_timeout_ms]

  # Connects to the nodes the registry lists (design §8.16); a VM that is not distributed has none to reach.
  defp discovery(%Config{alambique_opts: opts} = config) do
    case Keyword.get(opts, :registry, false) do
      false ->
        []

      registry ->
        if Node.alive?() do
          [
            {Atanor.Discovery,
             instance: config.alambique,
             refresh_ms: Atanor.Discovery.refresh_ms(registry),
             group: Atanor.Discovery.group_of(registry)}
          ]
        else
          Logger.warning("atanor: the registry is on but this VM is not distributed: no peer will be connected")
          []
        end
    end
  end

  defp disk(%Config{disk: %{budget: nil}}), do: []
  defp disk(config), do: [{Atanor.Disk, config}]

  defp auth(%Config{auth: auth}) when map_size(auth) == 0, do: []
  defp auth(config), do: [{Atanor.Auth.Keys, config}]

  defp hot_cells(%Config{hot_cells: %{enabled: false}}), do: []
  defp hot_cells(config), do: [{Atanor.HotCells, config}]

  defp dashboard(%Config{dashboard: nil}), do: []
  defp dashboard(config), do: [{Atanor.Dashboard.Supervisor, config}]

  defp admin(%Config{admin: nil}), do: []

  defp admin(%Config{admin: admin} = config) do
    [
      Supervisor.child_spec(
        {Bandit,
         plug: {Atanor.Admin, name: config.name},
         scheme: :http,
         ip: admin.ip,
         port: admin.port,
         startup_log: false,
         http_2_options: [enabled: admin.http_2],
         thousand_island_options:
           listener_options(admin) ++ [supervisor_options: [name: Atanor.Admin.listener(config.name)]]},
        id: :admin
      )
    ]
  end

  # The ceiling for awake cells may be derived from the node's memory, so say where it came from.
  defp log_awake_budget(config) do
    case config.alambique_opts[:awake][:max_bytes] do
      nil -> :ok
      bytes -> Logger.info("atanor: awake cells limited to #{bytes} bytes (#{config.memory.awake_source})")
    end

    log_wake_limits(config)

    case config.disk do
      %{budget: nil} ->
        Logger.warning(
          "atanor: the disk budget is unknown (no disk: [max_bytes:], and the file system size could not be read)"
        )

      %{budget: bytes, budget_source: source} ->
        wal = config.alambique_opts[:wal]

        Logger.info(
          "atanor: data_dir limited to #{bytes} bytes (#{source}), cells checkpoint at #{wal[:checkpoint_bytes]} " <>
            "bytes of WAL, #{wal[:max_bytes]} bytes of WAL in all"
        )
    end
  end

  # Only when the node has set them (derived from its memory limit, or given by the operator).
  defp log_wake_limits(config) do
    opts = config.alambique_opts

    if wakes = opts[:awake][:max_wakes] do
      Logger.info(
        "atanor: wakes limited to #{wakes} at once; a restore reads ahead " <>
          "#{opts[:restore][:max_inflight_bytes] || "the default"} bytes in flight with " <>
          "#{opts[:restore][:fetch_concurrency] || "the default"} requests"
      )
    end
  end
end
