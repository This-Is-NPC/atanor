defmodule Atanor.PropagationTest do
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias Atanor.{Deployments, Package, Registry, Store}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @route [{"127.0.0.1", "/"}]

  defp manifest(n, opts \\ []), do: Manifests.probe("w", opts ++ [routes: @route, limits: %{"timeout_ms" => n}])

  defp start(opts \\ []) do
    node = Node.start(opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  # A second node over the first one's store; stopped before it (on_exit runs last in, first out).
  defp join(node, opts) do
    start([store: node.store] ++ opts)
  end

  defp serving(node), do: with({:ok, d} <- Registry.deployment(node.name, "w"), do: d.id, else: (:error -> nil))
  defp reply(node), do: Req.get!(node.url <> "/echo", retry: false).body

  describe "switches reach the other nodes" do
    test "through the :pg notice, without waiting for a poll" do
      a = start()
      b = join(a, poll_interval_ms: :timer.minutes(10))
      assert {:ok, %{id: v1}} = Node.deploy(a, manifest(1))

      assert until(fn -> serving(b) == v1 end)
      assert reply(b)["deployment"] == v1

      assert {:ok, %{id: v2}} = Node.deploy(a, manifest(2))
      assert until(fn -> serving(b) == v2 end)
      assert reply(b)["deployment"] == v2
    end

    test "through polling when the notice is missed, as with a change made by the CLI" do
      a = start()
      b = join(a, poll_interval_ms: 20)
      handle = Store.handle(a.name)
      package = Manifests.package(manifest(1))

      {:ok, id} = Deployments.publish(handle, package)
      {:ok, _} = Deployments.activate(handle, "w", id)

      assert until(fn -> serving(b) == id and serving(a) == id end)
    end

    test "when a node starts, it loads the heads that are already in the store" do
      a = start()
      {:ok, %{id: v1}} = Node.deploy(a, manifest(1))

      c = join(a, [])
      assert serving(c) == v1
      assert reply(c)["deployment"] == v1
    end

    test "rollback and deactivation propagate too" do
      a = start()
      b = join(a, [])
      {:ok, %{id: v1}} = Node.deploy(a, manifest(1))
      {:ok, %{id: v2}} = Node.deploy(a, manifest(2))
      assert until(fn -> serving(b) == v2 end)

      assert {:ok, %{active: ^v1}} = Deployments.rollback(a.name, "w")
      assert until(fn -> serving(b) == v1 end)

      assert {:ok, %{active: nil}} = Deployments.deactivate(a.name, "w")
      assert until(fn -> serving(b) == nil end)
      assert Registry.routes(b.name) == []
      assert %{"w" => %{head: nil, applied: nil, error: nil}} = Deployments.status(b.name)
    end

    test "nodes over different prefixes do not see each other's workers" do
      a = start(prefix: "one")
      b = join(a, prefix: "two", poll_interval_ms: 20)
      {:ok, _} = Node.deploy(a, manifest(1))
      assert :ok = Deployments.sync(b.name)
      assert serving(b) == nil
    end
  end

  describe "native code that the node does not have" do
    test "keeps the previous deployment serving and reports the mismatch" do
      a = start()
      b = join(a, [])
      {:ok, %{id: v1}} = Node.deploy(a, manifest(1))
      assert until(fn -> serving(b) == v1 end)

      zeros = String.duplicate("0", 32)
      loaded = Atanor.Test.ProbeWorker.module_info(:md5) |> Base.encode16(case: :lower)
      {:ok, stale} = Package.build(manifest(2), {:native, zeros})
      {:ok, bad} = Deployments.publish(a.name, stale)
      {:ok, _} = Deployments.activate(a.name, "w", bad)

      expected = {:code_mismatch, zeros, loaded}
      assert until(fn -> match?(%{"w" => %{error: ^expected}}, Deployments.status(b.name)) end)
      assert %{"w" => %{head: ^bad, applied: ^v1, error: ^expected}} = Deployments.status(b.name)
      assert %{"w" => %{head: ^bad, applied: ^v1, error: ^expected}} = Deployments.status(a.name)

      for node <- [a, b] do
        assert serving(node) == v1
        assert reply(node)["deployment"] == v1
      end

      # A later good version clears the error.
      {:ok, %{id: v3}} = Node.deploy(a, manifest(3))
      assert until(fn -> serving(b) == v3 end)
      assert %{"w" => %{head: ^v3, applied: ^v3, error: nil}} = Deployments.status(b.name)
    end
  end

  describe "packages that cannot be applied" do
    test "a head that names a missing package is reported, and the node recovers at the next head" do
      a = start()
      {:ok, %{id: v1}} = Node.deploy(a, manifest(1))
      missing = String.duplicate("f", 64)

      {mod, config, prefix} = Store.handle(a.name)
      {:ok, json, _, _} = mod.get(config, prefix <> "workers/w/head")
      forged = json |> Jason.decode!() |> Map.merge(%{"active" => missing, "revision" => 9}) |> Jason.encode!()
      {:ok, _} = mod.put(config, prefix <> "workers/w/head", forged, :none, %{})

      :ok = Deployments.sync(a.name)
      assert %{"w" => %{head: ^missing, applied: ^v1, error: :not_found}} = Deployments.status(a.name)
      assert serving(a) == v1
    end
  end

  describe "operator approval of routes" do
    test "http hosts are active only when the worker's patterns cover them" do
      node = start(hosts: %{"w" => ["*.example.test", "exact.test"]})
      route = fn host -> manifest(1, routes: [{host, "/"}]) end

      assert {:ok, _} = Node.deploy(node, route.("a.example.test"))
      assert {:ok, _} = Node.deploy(node, route.("*.sub.example.test"))
      assert {:ok, _} = Node.deploy(node, route.("exact.test"))

      for host <- ["example.test", "other.test", "x.exact.test", "*.test"] do
        manifest = manifest(2, routes: [{host, "/"}])
        assert {:error, {:host_not_allowed, ^host, "w"}} = Node.deploy(node, manifest), host
      end

      # The refused version did not replace the serving one.
      assert Registry.routes(node.name) == [{"exact.test", "/", "w"}]
    end

    test "the catch-all * needs the operator's * and conflicts only with another catch-all" do
      node = start(hosts: %{"w" => ["*.example.test"], "all" => ["*"], "other" => ["*"]})

      assert {:error, {:host_not_allowed, "*", "w"}} = Node.deploy(node, manifest(1, routes: [{"*", "/"}]))

      all = Manifests.probe("all", routes: [{"*", "/"}, {"x.test", "/"}])
      assert {:ok, _} = Node.deploy(node, all)
      assert {:ok, _} = Node.deploy(node, manifest(1, routes: [{"a.example.test", "/"}]))

      # Same host and path in another worker is a conflict; another path is not.
      assert {:error, {:route_taken, "*", "/", "all"}} =
               Node.deploy(node, Manifests.probe("other", routes: [{"*", "/"}]))

      assert {:error, {:route_taken, "x.test", "/", "all"}} =
               Node.deploy(node, Manifests.probe("other", routes: [{"x.test", "/"}]))

      assert {:ok, _} = Node.deploy(node, Manifests.probe("other", routes: [{"*", "/other"}]))
    end

    test "a worker without patterns claims no host, and without the option any host is allowed" do
      strict = start(hosts: %{"other" => ["*.example.test"]})

      assert {:error, {:host_not_allowed, "a.example.test", "w"}} =
               Node.deploy(strict, manifest(1, routes: [{"a.example.test", "/"}]))

      open = start()
      assert {:ok, _} = Node.deploy(open, manifest(1, routes: [{"anything.test", "/"}]))
    end

    test "tcp listeners are active only when the operator maps their names" do
      node = start(listeners: %{"smtp" => 2525})
      assert {:ok, _} = Node.deploy(node, manifest(1, tcp: ["smtp"], module: Atanor.Test.LineWorker))

      assert {:error, {:listener_not_configured, "imap"}} =
               Node.deploy(node, manifest(2, tcp: ["smtp", "imap"], module: Atanor.Test.LineWorker))

      assert %{"smtp" => %{port: 2525, protocol: :thousand_island}} =
               Map.new(Atanor.Registry.config(node.name).listeners, fn {name, l} ->
                 {name, %{port: l.port, protocol: l.protocol}}
               end)

      none = start()

      assert {:error, {:listener_not_configured, "smtp"}} =
               Node.deploy(none, manifest(1, tcp: ["smtp"], module: Atanor.Test.LineWorker))
    end
  end
end
