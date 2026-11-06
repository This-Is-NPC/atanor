defmodule Atanor.Cluster.UnloadedModuleTest do
  @moduledoc """
  A native worker whose beam file is on a node's code path is applied even when the node did not load
  the module yet (a node in interactive mode loads on demand), and a head refused because the node
  does not have the module is tried again at the next poll (design §5.3).
  """
  use ExUnit.Case, async: false

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 240_000

  # Compiles a worker into a directory of its own (not named like an application): the peers have the beam file but never loaded it, and
  # the name is no atom there.
  setup do
    suffix = System.unique_integer([:positive])
    name = "Atanor.Test.Unloaded#{suffix}"
    dir = Path.join(System.tmp_dir!(), "unloaded-beams-#{suffix}")
    File.mkdir_p!(dir)

    source = """
    defmodule #{name} do
      @behaviour Atanor.Worker
      @impl true
      def handle_request(_request, _env), do: %Atanor.Response{body: "ok"}
    end
    """

    [{module, beam}] = Code.compile_string(source)
    File.write!(Path.join(dir, "#{Atom.to_string(module)}.beam"), beam)

    on_exit(fn ->
      Code.delete_path(dir)
      :code.purge(module)
      :code.delete(module)
      File.rm_rf(dir)
    end)

    %{dir: dir, manifest: Manifests.probe("late", module: module, routes: [{"127.0.0.1", "/"}])}
  end

  test "a peer applies a module it has not loaded, also after it restarts", %{dir: dir, manifest: manifest} do
    Code.prepend_path(dir)
    cluster = start_cluster(workers: [manifest])

    for name <- Cluster.names(cluster), do: assert(%{"late" => %{error: nil}} = Cluster.status(cluster, name))

    Cluster.kill(cluster, :n2)
    :ok = Cluster.restart(cluster, :n2)

    assert %{"late" => %{applied: id, error: nil}} = Cluster.status(cluster, :n2)
    assert is_binary(id)
  end

  test "a head refused because the module is missing is applied once the module is there", %{
    dir: dir,
    manifest: manifest
  } do
    cluster = start_cluster()
    {:ok, id} = Cluster.publish(cluster, manifest)
    assert {:error, errors} = Cluster.activate(cluster, "late", id)
    assert %{n1: {:module_not_loaded, _}} = errors

    for name <- Cluster.names(cluster), do: {:ok, true} = Cluster.call(cluster, name, Code, :prepend_path, [dir])

    # The head did not change: the next poll applies it.
    Await.until(fn ->
      :ok = Cluster.sync(cluster, Cluster.names(cluster))

      Enum.all?(Cluster.names(cluster), &match?(%{"late" => %{applied: ^id, error: nil}}, Cluster.status(cluster, &1)))
    end)
  end

  defp start_cluster(opts \\ []) do
    {:ok, cluster} = Cluster.start_link(opts)
    on_exit(fn -> catch_exit(Cluster.stop(cluster)) end)
    cluster
  end
end
