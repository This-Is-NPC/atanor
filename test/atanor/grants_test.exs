defmodule Atanor.GrantsTest do
  @moduledoc "What a manifest may grant is bounded by the other side's consent or the operator (design §3.3)."
  use ExUnit.Case, async: true

  alias Atanor.{Deployments, Env, Request, Store}
  alias Atanor.Deployments.Head
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @notes Manifests.notes_migrations()
  @host "127.0.0.1"

  defp start(workers, opts \\ []) do
    node = Node.start([workers: workers] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp routed(name, opts \\ []), do: Manifests.probe(name, [routes: [{@host, "/#{name}"}]] ++ opts)

  defp call(node, caller, callee) do
    {:ok, deployment} = Atanor.Registry.deployment(node.name, caller)
    Env.call(Env.new(node.name, deployment), callee, %Request{path: "/#{callee}/echo"})
  end

  describe "cell namespaces" do
    test "another worker cannot claim a namespace that has an owner" do
      node = start([routed("w", cells: %{"notes" => @notes})])

      assert {:error, {:namespace_owned, "notes", "w"}} =
               Node.deploy(node, routed("evil", cells: %{"notes" => @notes}))

      assert {:error, :not_found} = Deployments.head(node.name, "evil")
    end

    test "the owner keeps the namespace when its worker is not active" do
      node = start([routed("w", cells: %{"notes" => @notes})])
      {:ok, _} = Node.undeploy(node, "w")

      assert {:error, {:namespace_owned, "notes", "w"}} =
               Node.deploy(node, routed("evil", cells: %{"notes" => @notes}))

      assert {:ok, _} = Node.deploy(node, routed("w", cells: %{"notes" => @notes}))
    end

    test "the operator can share a namespace between workers" do
      node = start([routed("w", cells: %{"notes" => @notes})], namespaces: %{"notes" => ["w", "v"]})
      assert {:ok, _} = Node.deploy(node, routed("v", cells: %{"notes" => @notes}))

      assert {:error, {:namespace_not_allowed, "notes", "evil"}} =
               Node.deploy(node, routed("evil", cells: %{"notes" => @notes}))
    end

    test "the operator's list wins over whoever activates first" do
      node = start([], namespaces: %{"notes" => ["w"]})

      assert {:error, {:namespace_not_allowed, "notes", "evil"}} =
               Node.deploy(node, routed("evil", cells: %{"notes" => @notes}))

      assert {:ok, _} = Node.deploy(node, routed("w", cells: %{"notes" => @notes}))
    end

    test "a head that was forged in the store does not take the namespace after a restart" do
      node = start([routed("w", cells: %{"notes" => @notes})])
      store = Store.handle(node.name)

      evil = Manifests.package(routed("aaa-evil", cells: %{"notes" => [[1, "CREATE TABLE other (x)"]]}))
      {:ok, id} = Deployments.publish(store, evil)
      head = %Head{worker: "aaa-evil", active: id, revision: 1}
      {:ok, _} = Store.put(store, "workers/aaa-evil/head", Head.encode(head))

      restarted = Node.start(store: node.store, name: Module.concat(node.name, Restarted))
      on_exit(fn -> Node.stop(restarted) end)

      status = Deployments.status(restarted.name)
      assert %{"w" => %{error: nil, applied: applied}} = status
      assert applied
      assert %{"aaa-evil" => %{error: {:namespace_owned, "notes", "w"}}} = status
    end
  end

  describe "worker calls" do
    setup do
      %{workers: [routed("caller", workers: ["callee"]), routed("callee")]}
    end

    test "the callee must consent", %{workers: workers} do
      node = start(workers)
      assert {:error, {:not_granted, {:worker, "callee"}}} = call(node, "caller", "callee")
    end

    test "the callee's manifest can list its callers" do
      node = start([routed("caller", workers: ["callee"]), routed("callee", callable_by: ["caller"])])
      assert {:ok, %{status: 200}} = call(node, "caller", "callee")
    end

    test "the operator can list the callers of a worker", %{workers: workers} do
      node = start(workers, callers: %{"callee" => ["caller"]})
      assert {:ok, %{status: 200}} = call(node, "caller", "callee")
    end

    test "a worker calls itself" do
      node = start([routed("rec", workers: ["rec"])])
      assert {:ok, %{status: 200}} = call(node, "rec", "rec")
    end
  end

  describe "operator ceilings" do
    test "http_allow bounds the hosts a manifest grants itself" do
      node = start([], http_allow: %{"w" => ["api.example.com", "*.cdn.example.com"]})

      assert {:ok, _} = Node.deploy(node, routed("w", allow: ["https://api.example.com", "img.cdn.example.com"]))
      assert {:error, {:http_not_allowed, "evil.test", "w"}} = Node.deploy(node, routed("w", allow: ["evil.test"]))

      assert {:error, {:http_not_allowed, "*.example.com", "w"}} =
               Node.deploy(node, routed("w", allow: ["*.example.com"]))

      assert {:error, {:http_not_allowed, "api.example.com", "other"}} =
               Node.deploy(node, routed("other", allow: ["api.example.com"]))
    end

    test "an exact http_allow host does not let a manifest grant its subdomains" do
      node = start([], http_allow: %{"w" => ["example.com"], "wide" => ["*.example.com"]})

      assert {:ok, _} = Node.deploy(node, routed("w", allow: ["example.com"]))

      assert {:error, {:http_not_allowed, "*.example.com", "w"}} =
               Node.deploy(node, routed("w", allow: ["*.example.com"]))

      assert {:ok, _} =
               Node.deploy(node, routed("wide", allow: ["*.example.com", "*.cdn.example.com", "a.example.com"]))

      assert {:error, {:http_not_allowed, "example.com", "wide"}} =
               Node.deploy(node, routed("wide", allow: ["example.com"]))
    end

    test "modules bounds the native modules a worker may bind" do
      node = start([], modules: %{"w" => ["Elixir.Atanor.Test.ProbeWorker"]})
      assert {:ok, _} = Node.deploy(node, routed("w"))

      assert {:error, {:module_not_allowed, "Elixir.Atanor.Test.CounterWorker", "w"}} =
               Node.deploy(node, routed("w", module: Atanor.Test.CounterWorker))

      assert {:error, {:module_not_allowed, "Elixir.Atanor.Test.ProbeWorker", "v"}} = Node.deploy(node, routed("v"))
    end
  end
end
