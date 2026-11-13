defmodule Atanor.Test.Manifests do
  @moduledoc "Builds manifest maps for tests."

  @notes [[1, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"]]

  def notes_migrations, do: @notes

  @doc """
  A native manifest for `Atanor.Test.ProbeWorker`. Options: `:module`,
  `:cells` (namespace to migrations), `:secrets`, `:allow`, `:workers`, `:callable_by`,
  `:partitions` (namespace to number of partitions), `:alarms`, `:sockets` (booleans), `:routes` (`{host, path}`), `:tcp`
  (listener names), `:limits`.
  """
  def probe(name, opts \\ []) do
    %{
      "manifest_version" => 1,
      "name" => name,
      "kind" => "native",
      "module" => Atom.to_string(Keyword.get(opts, :module, Atanor.Test.ProbeWorker)),
      "bindings" => %{
        "cells" =>
          Map.new(Keyword.get(opts, :cells, %{}), fn {ns, migs} -> {ns, cell(migs, opts[:partitions][ns])} end),
        "secrets" => Keyword.get(opts, :secrets, []),
        "http" => %{"allow" => Keyword.get(opts, :allow, [])},
        "workers" => Keyword.get(opts, :workers, []),
        "alarms" => Keyword.get(opts, :alarms, false),
        "sockets" => Keyword.get(opts, :sockets, false),
        "jobs" => Keyword.get(opts, :jobs, false)
      },
      "routes" =>
        for({host, path} <- Keyword.get(opts, :routes, []), do: %{"http" => %{"host" => host, "path" => path}}) ++
          for(route <- Keyword.get(opts, :tcp, []), do: tcp_route(route)),
      "limits" => Keyword.get(opts, :limits, %{})
    }
    |> then(fn manifest ->
      if opts[:callable_by], do: Map.put(manifest, "callable_by", opts[:callable_by]), else: manifest
    end)
  end

  defp cell(migrations, nil), do: %{"migrations" => migrations}
  defp cell(migrations, n), do: %{"migrations" => migrations, "partitions" => n}

  defp tcp_route({listener, protocol}),
    do: %{"tcp" => %{"listener" => listener, "protocol" => Atom.to_string(protocol)}}

  defp tcp_route(listener), do: %{"tcp" => %{"listener" => listener}}

  @doc "A manifest for `Atanor.Test.JobWorker`; options are those of `probe/2`."
  def jobs(name, opts \\ []) do
    probe(
      name,
      Keyword.merge(
        [
          module: Atanor.Test.JobWorker,
          jobs: true,
          cells: %{"jobs" => Atanor.Test.JobWorker.migrations()},
          routes: [{"127.0.0.1", "/"}]
        ],
        opts
      )
    )
  end

  @doc "A manifest for `Atanor.Test.CounterWorker`; options are those of `probe/2`."
  def counter(name, opts \\ []) do
    probe(
      name,
      Keyword.merge(
        [
          module: Atanor.Test.CounterWorker,
          cells: %{"log" => Atanor.Test.CounterWorker.migrations()},
          routes: [{"127.0.0.1", "/c"}, {"127.0.0.1", "/r"}, {"127.0.0.1", "/v"}]
        ],
        opts
      )
    )
  end

  @doc """
  A manifest for `Atanor.Test.PartitionWorker` whose namespace `events` has `partitions`
  partitions; options are those of `probe/2`.
  """
  def partitioned(name, partitions, opts \\ []) do
    probe(
      name,
      Keyword.merge(
        [
          module: Atanor.Test.PartitionWorker,
          cells: %{"events" => Atanor.Test.PartitionWorker.migrations()},
          partitions: %{"events" => partitions},
          routes: [{"127.0.0.1", "/"}]
        ],
        opts
      )
    )
  end

  @doc "The package of a manifest map whose native module is compiled in the test VM."
  def package(manifest_map) do
    {:ok, package} = Atanor.Package.from_project(manifest_map)
    package
  end

  @doc """
  Writes the head of a worker straight into the node's store, as one that did not go through
  `Atanor.Deployments.activate/4` would be, and has the node apply it. Returns the node's status of the worker.
  """
  def forge_head(node, manifest_map) do
    store = Atanor.Store.handle(node.name)
    package = package(manifest_map)
    worker = package.manifest.name
    {:ok, id} = Atanor.Deployments.publish(store, package)
    head = %Atanor.Deployments.Head{worker: worker, active: id, revision: 1}
    {:ok, _} = Atanor.Store.put(store, "workers/#{worker}/head", Atanor.Deployments.Head.encode(head))
    :ok = Atanor.Deployments.sync(node.name)
    Atanor.Deployments.status(node.name)[worker]
  end

  @doc "A store handle on a fresh in-memory store; the store is linked to the test."
  def memory_store(prefix \\ "atanor") do
    {:ok, pid} = AlambiqueTestkit.MemoryStore.start_link()
    Atanor.Store.open({AlambiqueTestkit.MemoryStore, AlambiqueTestkit.MemoryStore.config(pid)}, prefix)
  end

  @doc """
  A WASM manifest for the guest component `<guest>.wasm`, to deploy with
  `deploy_wasm/2`. Options are those of `probe/2`, without `:module`.
  """
  def wasm(name, guest, opts \\ []) do
    probe(name, Keyword.delete(opts, :module))
    |> Map.delete("module")
    |> Map.merge(%{"kind" => "wasm", "component" => "#{guest}.wasm"})
  end

  @doc "Deploys WASM manifests (see `wasm/3`) from the compiled test guests."
  def deploy_wasm(node, manifests) do
    for manifest <- List.wrap(manifests) do
      {:ok, _} = Atanor.Dev.deploy(node.name, manifest, Path.expand("test/fixtures/wasm"))
    end

    :ok
  end
end
