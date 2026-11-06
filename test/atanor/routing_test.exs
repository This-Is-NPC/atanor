defmodule Atanor.RoutingTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Atanor.Registry
  alias Atanor.Test.{Manifests, PlugWorker}
  alias AtanorTestkit.Node

  defp start(workers \\ [], opts \\ []) do
    node = Node.start([workers: workers] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp get(node, path, opts \\ []), do: Req.request!([url: node.url <> path, retry: false, decode_body: false] ++ opts)
  defp json(resp), do: Jason.decode!(resp.body)

  describe "a cell write whose outcome is unknown" do
    test "makes a failing handler answer 503 unknown_outcome, and leaves a handled error alone" do
      node = start([Manifests.probe("w", routes: [{"localhost", "/"}])])

      resp = get(node, "/unknown?status=500", headers: [{"host", "localhost"}])
      assert {resp.status, json(resp)} == {503, %{"error" => "unknown_outcome", "reason" => "unknown_outcome"}}

      resp = get(node, "/unknown?status=409", headers: [{"host", "localhost"}])
      assert {resp.status, json(resp)} == {409, %{"handled" => true}}

      # The mark belongs to one call: the next request on the same connection is not affected.
      assert get(node, "/echo", headers: [{"host", "localhost"}]).status == 200
    end
  end

  describe "route matching" do
    test "matches by host, then by longest path prefix" do
      node =
        start([
          Manifests.probe("root", routes: [{"localhost", "/"}]),
          Manifests.probe("api", routes: [{"localhost", "/api"}]),
          Manifests.probe("deep", routes: [{"localhost", "/api/v1"}]),
          Manifests.probe("other", routes: [{"127.0.0.1", "/"}])
        ])

      worker = fn host, path ->
        resp = get(node, path, headers: [{"host", host}])
        {resp.status, resp.status == 200 && json(resp)["worker"]}
      end

      assert {404, _} = worker.("unknown.test", "/echo")
      assert {200, "root"} = worker.("localhost", "/echo")
      assert {200, "api"} = worker.("localhost", "/api/echo")
      assert {200, "deep"} = worker.("localhost", "/api/v1/echo")
      assert {200, "deep"} = worker.("localhost", "/api/v1/")
      assert {200, "root"} = worker.("localhost", "/apix/echo")
      assert {200, "other"} = worker.("127.0.0.1", "/echo")
    end

    test "wildcard hosts match subdomains, and an exact host wins" do
      node =
        start([
          Manifests.probe("wild", routes: [{"*.example.test", "/"}]),
          Manifests.probe("exact", routes: [{"a.example.test", "/exact"}])
        ])

      match = fn host, path ->
        with {:ok, d} <- Registry.match_route(node.name, host, path), do: Atanor.Deployment.worker(d)
      end

      assert match.("a.example.test", "/exact/x") == "exact"
      assert match.("a.example.test", "/other") == "wild"
      assert match.("x.y.example.test", "/") == "wild"
      assert match.("example.test", "/") == :error
      assert match.("127.0.0.1", "/") == :error
    end

    test "the catch-all host * has the lowest precedence and matches an IP Host" do
      node =
        start([
          Manifests.probe("all", routes: [{"*", "/"}]),
          Manifests.probe("wild", routes: [{"*.example.test", "/"}]),
          Manifests.probe("exact", routes: [{"a.example.test", "/exact"}])
        ])

      match = fn host, path ->
        with {:ok, d} <- Registry.match_route(node.name, host, path), do: Atanor.Deployment.worker(d)
      end

      assert match.("a.example.test", "/exact/x") == "exact"
      assert match.("a.example.test", "/other") == "wild"
      assert match.("x.example.test", "/") == "wild"
      assert match.("example.test", "/") == "all"
      assert match.("10.1.2.3", "/") == "all"
      assert match.("localhost", "/") == "all"

      # A health probe that sends the node's address as Host, over the wire.
      resp = get(node, "/echo", headers: [{"host", "10.1.2.3"}])
      assert {resp.status, json(resp)["worker"]} == {200, "all"}
    end

    test "the catch-all keeps path prefixes, and falls back to it when a host's paths do not match" do
      node =
        start([
          Manifests.probe("health", routes: [{"*", "/health"}]),
          Manifests.probe("site", routes: [{"site.test", "/app"}])
        ])

      match = fn host, path ->
        with {:ok, d} <- Registry.match_route(node.name, host, path), do: Atanor.Deployment.worker(d)
      end

      assert match.("10.0.0.1", "/health/live") == "health"
      assert match.("10.0.0.1", "/app") == :error
      assert match.("site.test", "/app/x") == "site"
      assert match.("site.test", "/health") == "health"
    end

    test "answers 404 with a JSON body when nothing matches" do
      node = start([Manifests.probe("w", routes: [{"127.0.0.1", "/only"}])])
      resp = get(node, "/other")
      assert resp.status == 404
      assert ["application/json" <> _] = resp.headers["content-type"]
      assert json(resp) == %{"error" => "not_found"}
    end

    test "lists the routes" do
      node = start([Manifests.probe("w", routes: [{"127.0.0.1", "/a/"}, {"*.x.test", "/"}])])
      assert Enum.sort(Registry.routes(node.name)) == [{"*.x.test", "/", "w"}, {"127.0.0.1", "/a", "w"}]
    end

    test "builds the request from the connection" do
      node = start([Manifests.probe("w", routes: [{"127.0.0.1", "/"}])])
      resp = get(node, "/echo?a=1&b=2", headers: [{"x-custom", "v"}], method: :post, body: "payload")

      assert %{"method" => "POST", "scheme" => "http", "path" => "/echo", "query" => "a=1&b=2", "body" => "payload"} =
               json(resp)

      assert json(resp)["headers"]["x-custom"] == "v"
      assert json(resp)["host"] == "127.0.0.1"
    end
  end

  describe "activation" do
    test "deploys and undeploys at runtime, with the package hash as the deployment id" do
      node = start()
      manifest = Manifests.probe("w", routes: [{"127.0.0.1", "/"}])
      assert get(node, "/echo").status == 404

      assert {:ok, deployment} = Node.deploy(node, manifest)
      assert {:ok, package} = Atanor.Package.from_project(manifest)
      assert deployment.id == package.id
      assert get(node, "/echo").status == 200

      # Same manifest and code, same id; another manifest, another id.
      assert {:ok, %{id: same}} = Node.deploy(node, manifest)
      assert same == deployment.id
      assert {:ok, %{id: other}} = Node.deploy(node, put_in(manifest, ["limits", "fuel"], 7))
      assert other != deployment.id

      assert {:ok, %{active: nil}} = Node.undeploy(node, "w")
      assert get(node, "/echo").status == 404
      assert Registry.routes(node.name) == []
      assert {:error, :not_found} = Node.undeploy(node, "nope")
    end

    test "a new version replaces the routes of the old one" do
      node = start([Manifests.probe("w", routes: [{"127.0.0.1", "/a"}, {"127.0.0.1", "/b"}])])
      {:ok, _} = Node.deploy(node, Manifests.probe("w", routes: [{"127.0.0.1", "/a"}]))
      assert Registry.routes(node.name) == [{"127.0.0.1", "/a", "w"}]
    end

    test "refuses what cannot be activated" do
      node = start([Manifests.probe("w", routes: [{"127.0.0.1", "/"}])])

      assert {:error, {:invalid_manifest, ["name"], _}} = Node.deploy(node, %{"manifest_version" => 1, "name" => "Bad"})

      wasm = %{"manifest_version" => 1, "name" => "x", "kind" => "wasm", "component" => "x.wasm"}
      assert {:error, {:component_unreadable, "x.wasm", :enoent}} = Node.deploy(node, wasm)

      missing = Manifests.probe("x", module: Not.Compiled)
      assert {:error, {:module_not_loaded, "Elixir.Not.Compiled"}} = Node.deploy(node, missing)

      assert {:error, {:not_a_worker, String}} = Node.deploy(node, Manifests.probe("x", module: String))

      assert {:error, {:route_taken, "127.0.0.1", "/", "w"}} =
               Node.deploy(node, Manifests.probe("x", routes: [{"127.0.0.1", "/"}]))

      assert Enum.map(Registry.deployments(node.name), &Atanor.Deployment.worker/1) == ["w"]
    end

    test "workers given at start are deployed, and an invalid one stops the start" do
      node = start([Manifests.probe("w", routes: [{"127.0.0.1", "/"}])])
      assert get(node, "/echo").status == 200

      assert_raise RuntimeError, ~r/worker x not deployed: {:module_not_loaded, "Elixir.Not.Compiled"}/, fn ->
        Node.start(workers: [Manifests.probe("x", module: Not.Compiled)])
      end
    end
  end

  describe "pinned deployment (D1)" do
    test "a request finishes on the deployment it started on" do
      node = start([Manifests.probe("w", routes: [{"127.0.0.1", "/"}])])
      {:ok, %{id: a}} = Node.deploy(node, Manifests.probe("w", routes: [{"127.0.0.1", "/"}]))
      pid = Base.encode64(:erlang.term_to_binary(self()))

      task = Task.async(fn -> get(node, "/gate", headers: [{"x-test-pid", pid}]) end)
      assert_receive {:in_handler, handler}, 5_000

      {:ok, %{id: b}} =
        Node.deploy(node, Manifests.probe("w", routes: [{"127.0.0.1", "/"}], limits: %{"fuel" => 1}))

      assert a != b
      send(handler, :go)

      assert json(Task.await(task)) == %{"deployment" => a}
      assert json(get(node, "/echo"))["deployment"] == b
    end
  end

  describe "failures" do
    setup do
      %{node: start([Manifests.probe("w", routes: [{"127.0.0.1", "/"}])])}
    end

    test "a worker that raises or exits gives a 500 without internals, and is logged", %{node: node} do
      for path <- ["/crash", "/exit"] do
        log = capture_log(fn -> assert get(node, path).body == ~s({"error":"internal_error"}) end)
        assert log =~ "worker w (deployment "
        assert log =~ "crashed"
        assert log =~ "secret"
      end

      assert get(node, "/echo").status == 200
    end

    test "a bad return gives a 500", %{node: node} do
      for path <- ["/bad", "/bad-status"] do
        log = capture_log(fn -> assert get(node, path).status == 500 end)
        assert log =~ "returned an invalid response"
      end
    end

    test "a body over the limit gives a 413" do
      node = start([Manifests.probe("w", routes: [{"127.0.0.1", "/"}])], max_body_bytes: 10)
      assert get(node, "/echo", method: :post, body: "0123456789").status == 200
      resp = get(node, "/echo", method: :post, body: "0123456789x")
      assert resp.status == 413
      assert json(resp) == %{"error" => "payload_too_large"}
    end
  end

  describe "plug workers" do
    setup do
      cells = %{"notes" => Manifests.notes_migrations()}
      %{node: start([Manifests.probe("web", module: PlugWorker, cells: cells, routes: [{"127.0.0.1", "/"}])])}
    end

    test "are served the conn with the env in conn.private", %{node: node} do
      resp = get(node, "/page", method: :post, body: "hi")
      assert json(resp) == %{"worker" => "web", "body" => "hi", "ungranted_denied" => true, "claims" => []}
    end

    test "give a 500 when the plug raises", %{node: node} do
      log = capture_log(fn -> assert get(node, "/boom").body == ~s({"error":"internal_error"}) end)
      assert log =~ "worker web (deployment "
    end
  end
end
