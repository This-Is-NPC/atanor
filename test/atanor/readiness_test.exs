defmodule Atanor.ReadinessTest do
  @moduledoc """
  A node joins the cluster only after it applied the active deployments, and
  says so on `/health/ready` (design §2.1).
  """
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias AlambiqueTestkit.MemoryStore
  alias Atanor.{Deployments, Package, Registry}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @token "ready-token"

  defp build(opts), do: Atanor.Config.build([data_dir: "/tmp/x", store: {Mod, nil}] ++ opts)

  defp get(name, path) do
    url = "http://127.0.0.1:#{Atanor.admin_port(name)}" <> path

    Req.get!(url, headers: [{"authorization", "Bearer " <> @token}], retry: false, decode_body: false)
  end

  defp admin_port(name) do
    Atanor.admin_port(name)
  catch
    _, _ -> nil
  end

  # An instance over `store` that starts in a task, since its start waits for the store.
  defp start_over(store, opts) do
    id = System.unique_integer([:positive])
    name = Module.concat(__MODULE__, "N#{id}")
    dir = Path.join(System.tmp_dir!(), "atanor-ready-#{id}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    atanor =
      Keyword.merge(
        [
          name: name,
          data_dir: dir,
          store: {MemoryStore, store},
          prefix: "ready",
          port: 0,
          admin: [token: @token, port: 0]
        ],
        opts
      )

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        with {:ok, sup} <- Supervisor.start_link([{Atanor, atanor}], strategy: :one_for_one) do
          Process.unlink(sup)
          {:ok, sup}
        end
      end)

    {name, task}
  end

  defp store do
    {:ok, pid} = MemoryStore.start_link()
    MemoryStore.config(pid)
  end

  describe "options" do
    test "default to a minute to wait and a second between tries" do
      assert build([]).ready == %{timeout_ms: 60_000, retry_ms: 1_000}
    end

    test "are validated" do
      assert build(ready: [timeout_ms: 5_000]).ready == %{timeout_ms: 5_000, retry_ms: 1_000}

      for ready <- [
            [timeout_ms: 0],
            [retry_ms: -1],
            [timeout_ms: "1"],
            [other: 1],
            [timeout_ms: 100, retry_ms: 200],
            :x
          ] do
        assert_raise ArgumentError, fn -> build(ready: ready) end
      end
    end
  end

  describe "a node that has applied its deployments" do
    test "is ready and says so" do
      node = Node.start(admin: [token: @token, port: 0])
      on_exit(fn -> Node.stop(node) end)

      assert Registry.state(node.name) == :ready
      response = get(node.name, "/health/ready")
      assert response.status == 200
      assert Jason.decode!(response.body)["status"] == "ready"
      assert Jason.decode!(get(node.name, "/health").body)["status"] == "ok"
    end

    test "is serving for a balancer while it has a quorum" do
      node = Node.start(admin: [token: @token, port: 0])
      on_exit(fn -> Node.stop(node) end)

      response = get(node.name, "/health/serving")
      assert response.status == 200
      assert Jason.decode!(response.body)["status"] == "serving"
    end

    test "joins the cluster only when it is ready" do
      node = Node.start()
      on_exit(fn -> Node.stop(node) end)
      cells = Module.concat(node.name, Cells)

      assert Alambique.drain(cells) == {:ok, %{hibernated: 0, errors: []}}
      assert Alambique.join(cells) == :ok
      assert Registry.state(node.name) == :ready
    end
  end

  describe "a node that cannot read the store at start" do
    test "is not ready and opens no ingress, then joins when the store answers" do
      store = store()
      fault = MemoryStore.inject(store, kind: :error)
      {name, task} = start_over(store, ready: [timeout_ms: 30_000, retry_ms: 20])

      port = until(fn -> admin_port(name) end)
      assert port
      assert until(fn -> match?({:starting, "could not list" <> _}, Registry.state(name)) end)

      response = get(name, "/health/ready")
      assert response.status == 503
      assert %{"status" => "starting", "reason" => "could not list" <> _} = Jason.decode!(response.body)
      assert get(name, "/workers").status == 503
      assert get(name, "/health/serving").status == 503
      assert catch_exit(Atanor.port(name))

      MemoryStore.remove(store, fault)
      assert {:ok, sup} = Task.await(task, 30_000)
      assert Registry.state(name) == :ready
      assert get(name, "/health/ready").status == 200
      assert is_integer(Atanor.port(name))

      Supervisor.stop(sup)
    end

    test "does not start after the time the option allows" do
      store = store()
      MemoryStore.inject(store, kind: :error)
      {_name, task} = start_over(store, ready: [timeout_ms: 200, retry_ms: 50])

      assert {:error,
              {:shutdown,
               {:failed_to_start_child, _,
                {:shutdown, {:failed_to_start_child, Atanor.Deployments.Watcher, {:deployments_not_loaded, reason}}}}}} =
               Task.await(task, 30_000)

      assert reason =~ "could not list the workers"
    end
  end

  describe "a worker that cannot be applied" do
    test "does not keep the node out" do
      a = Node.start()
      on_exit(fn -> Node.stop(a) end)

      zeros = String.duplicate("0", 32)
      {:ok, package} = Package.build(Manifests.probe("w", routes: [{"127.0.0.1", "/"}]), {:native, zeros})
      {:ok, id} = Deployments.publish(a.name, package)
      {:ok, _} = Deployments.activate(a.name, "w", id)

      {name, task} =
        start_over(elem(a.store, 1),
          ready: [timeout_ms: 5_000, retry_ms: 20],
          prefix: Atanor.Registry.config(a.name).prefix
        )

      assert {:ok, sup} = Task.await(task, 30_000)

      assert Registry.state(name) == :ready
      assert %{"w" => %{head: ^id, applied: nil, error: {:code_mismatch, ^zeros, _}}} = Deployments.status(name)
      Supervisor.stop(sup)
    end
  end
end
