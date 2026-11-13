defmodule Mix.Tasks.Atanor.Dev do
  @shortdoc "Runs a single local Atanor node"
  @moduledoc """
  Runs a single local Atanor node and blocks until it is stopped.

      mix atanor.dev [--port 4000] [--data-dir DIR] [--store memory|seaweedfs] [--bucket NAME] [--prefix PREFIX] [--manifest FILE]... [--listener NAME=PORT]... [--admin-port PORT --admin-token TOKEN] [--dashboard-port PORT] [--dashboard-token TOKEN] [--no-dashboard] [--connect NODE]...

  The node deploys the native workers of `./atanor.json`, or of each
  `--manifest FILE` (repeatable, replacing `./atanor.json`): it publishes their
  packages into its store, activates them and prints their routes. Their
  modules must be compiled in the current project. Without a manifest every
  request is a 404.

  `--listener NAME=PORT` (repeatable) maps a TCP listener name of the
  manifests to a port; `PORT` 0 picks a free one. The node prints the port of
  each listener a worker claims.

  `--admin-port PORT` starts the admin API on that port (0 picks one) and needs
  `--admin-token TOKEN`, which every request must send as a bearer token.

  The read-only dashboard starts on port 4002 (`--dashboard-port PORT`; 0
  picks one) when your project depends on the packages of
  `Atanor.Dashboard.dependencies/0`; without them the task says so and goes
  on. It needs a token: `--dashboard-token TOKEN`, or a random one that the
  task prints in the URL to open. `--no-dashboard` leaves it out.

  `--connect NODE` (repeatable) connects this VM to another node before the
  instance starts, so nodes started with `--sname` and the same `--cookie`
  form a cluster; see docs/how-to-run-a-cluster.md. With `--store seaweedfs` on a named node the node
  also publishes itself in the bucket and connects to the others it finds there (design §8.16).

  The default store is the in-memory store of the Alambique testkit, which only
  this VM can reach. With `--store seaweedfs` the node uses the bucket
  `--bucket` (default `atanor-dev`) of the container from `mise run
  seaweedfs:up`. Start it with `--admin-port` and `--admin-token` and
  deploy with the `atanor` command (docs/cli.md).
  Without `--data-dir` the node uses `atanor-dev-<port>` in the temporary
  directory, emptied at each start.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          port: :integer,
          data_dir: :string,
          store: :string,
          bucket: :string,
          prefix: :string,
          manifest: :keep,
          listener: :keep,
          admin_port: :integer,
          admin_token: :string,
          dashboard_port: :integer,
          dashboard_token: :string,
          dashboard: :boolean,
          connect: :keep
        ]
      )

    store = store!(opts[:store])
    port = opts[:port] || 4000
    data_dir = opts[:data_dir] || temp_dir(port)

    workers = opts |> manifest_paths() |> Enum.map(&read_manifest!/1)

    connect(opts)

    start_opts = [
      port: port,
      admin: admin(opts),
      dashboard: dashboard(opts),
      data_dir: data_dir,
      store: store,
      workers: workers,
      listeners: listeners(opts),
      bucket: opts[:bucket] || Atanor.Dev.SeaweedFS.dev_bucket()
    ]

    start_opts = if opts[:prefix], do: [prefix: opts[:prefix]] ++ start_opts, else: start_opts

    # Nodes that share the bucket find each other (design §8.16); the memory store is private to a VM.
    start_opts =
      if Node.alive?() and store == :seaweedfs do
        start_opts ++ [alambique: [registry: [advertise: Atom.to_string(node()), ttl_ms: 6_000, renew_ms: 1_000]]]
      else
        start_opts
      end

    case Atanor.Dev.start(start_opts) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("could not start the node: #{inspect(reason)}")
    end

    for {worker, %{error: error}} when error != nil <- Atanor.Deployments.status(Atanor),
        do: Mix.shell().error("worker #{worker} not applied: #{inspect(error)}")

    url = "http://127.0.0.1:#{Atanor.port()}"
    Mix.shell().info("Atanor listening on #{url}")

    for {host, path, worker} <- Atanor.Registry.routes(Atanor), do: Mix.shell().info("  #{host}#{path} -> #{worker}")

    print_dashboard(start_opts[:dashboard])

    for name <- Enum.sort(Atanor.Registry.listeners(Atanor)) do
      {:ok, port} = Atanor.TCP.port(Atanor, name)
      {:ok, deployment} = Atanor.Registry.listener(Atanor, name)
      Mix.shell().info("  tcp #{name} on 127.0.0.1:#{port} -> #{Atanor.Deployment.worker(deployment)}")
    end

    Process.sleep(:infinity)
  end

  defp admin(opts) do
    case {opts[:admin_port], opts[:admin_token]} do
      {nil, nil} -> nil
      {port, token} when is_integer(port) and is_binary(token) -> [port: port, token: token]
      _ -> Mix.raise("--admin-port and --admin-token go together")
    end
  end

  defp dashboard(opts) do
    cond do
      opts[:dashboard] == false ->
        nil

      Atanor.Dashboard.available?() ->
        [port: opts[:dashboard_port] || 4002, token: opts[:dashboard_token] || random_token()]

      opts[:dashboard_port] || opts[:dashboard_token] ->
        Mix.raise(
          "the dashboard needs these dependencies in your project: #{Atanor.Dashboard.dependencies()}; " <>
            "after mix deps.get run mix deps.compile atanor --force"
        )

      true ->
        Mix.shell().info(
          "Dashboard not started: add #{Atanor.Dashboard.dependencies()} to your deps, run mix deps.get and " <>
            "mix deps.compile atanor --force (docs/how-to-open-the-dashboard.md)"
        )

        nil
    end
  end

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp print_dashboard(nil), do: :ok

  defp print_dashboard(dashboard),
    do: Mix.shell().info("Dashboard on http://127.0.0.1:#{Atanor.Dashboard.port()}/workers?token=#{dashboard[:token]}")

  defp connect(opts) do
    for name <- Keyword.get_values(opts, :connect) do
      unless Node.alive?(),
        do: Mix.raise("--connect needs a named node: start with elixir --sname NAME -S mix atanor.dev")

      unless Node.connect(String.to_atom(name)), do: Mix.shell().error("could not connect to #{name}")
    end
  end

  defp listeners(opts) do
    Map.new(Keyword.get_values(opts, :listener), fn entry ->
      with [name, port] <- String.split(entry, "=", parts: 2),
           {port, ""} <- Integer.parse(port) do
        {name, port}
      else
        _ -> Mix.raise("--listener expects NAME=PORT, got #{inspect(entry)}")
      end
    end)
  end

  defp manifest_paths(opts) do
    case Keyword.get_values(opts, :manifest) do
      [] -> if File.regular?("atanor.json"), do: ["atanor.json"], else: []
      paths -> paths
    end
  end

  defp read_manifest!(path) do
    case Atanor.Manifest.read_file(path) do
      {:ok, map} -> map
      {:error, message} -> Mix.raise(message)
    end
  end

  defp store!(nil), do: :memory
  defp store!("memory"), do: :memory
  defp store!("seaweedfs"), do: :seaweedfs
  defp store!(other), do: Mix.raise("unknown store #{inspect(other)}; use memory or seaweedfs")

  # A fresh directory per start: the in-memory store forgets its cells, so
  # their local files must not be reused.
  defp temp_dir(port) do
    dir = Path.join(System.tmp_dir!(), "atanor-dev-#{port}")
    File.rm_rf!(dir)
    dir
  end
end
