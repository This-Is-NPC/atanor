defmodule Atanor.AdminTest do
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias Atanor.Test.{LineWorker, Manifests}
  alias AtanorTestkit.Node

  @token "s3cret-token"

  defp start(workers \\ [], opts \\ []) do
    node = Node.start([workers: workers, admin: [token: @token, port: 0]] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp get(node, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [{"authorization", "Bearer " <> @token}])
    url = "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path
    Req.request!(method: Keyword.get(opts, :method, :get), url: url, headers: headers, retry: false, decode_body: false)
  end

  defp json(response), do: Jason.decode!(response.body)

  defp post(node, path, body) do
    url = "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path

    Req.post!(url,
      body: Jason.encode!(body),
      headers: [{"authorization", "Bearer " <> @token}, {"content-type", "application/json"}],
      retry: false,
      decode_body: false
    )
  end

  defp notes(name, opts \\ []),
    do:
      Manifests.probe(
        name,
        [cells: %{"notes" => Manifests.notes_migrations()}, routes: [{"127.0.0.1", "/#{name}"}]] ++ opts
      )

  describe "options" do
    test "the admin listener needs a token" do
      for admin <- [[], [port: 0], [token: ""], [token: :atom], [token: "t", extra: 1], [token: "t", port: -1]] do
        assert_raise ArgumentError, fn ->
          Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, admin: admin)
        end
      end
    end

    test "the token stays out of inspect output" do
      config = Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, admin: [token: @token])
      refute inspect(config) =~ @token
      assert config.admin.ip == {127, 0, 0, 1}
    end

    test "store credentials stay out of inspect output" do
      s3 = %{
        endpoint: "http://127.0.0.1:1",
        bucket: "b",
        access_key_id: "AKID-SENTINEL",
        secret_access_key: "SK-SENTINEL"
      }

      config = Atanor.Config.build(data_dir: "/tmp/x", store: {Alambique.Store.S3, s3})
      for term <- [config, config.meta_store, config.alambique_opts], do: refute(inspect(term) =~ "SK-SENTINEL")

      placed = Atanor.Config.build(data_dir: "/tmp/x", placement: {Mod, s3}, meta_store: {Alambique.Store.S3, s3})
      for term <- [placed, placed.meta_store], do: refute(inspect(term) =~ "SK-SENTINEL")
    end

    test "a listener on a public address needs a token of 32 bytes" do
      for key <- [:admin, :dashboard], ip <- [{0, 0, 0, 0}, {10, 0, 0, 5}, {0, 0, 0, 0, 0, 0, 0, 0}] do
        opts = [data_dir: "/tmp/x", store: {Mod, nil}] ++ [{key, [token: String.duplicate("a", 31), ip: ip]}]
        assert_raise ArgumentError, ~r/at least 32 bytes/, fn -> Atanor.Config.build(opts) end
        opts = [data_dir: "/tmp/x", store: {Mod, nil}] ++ [{key, [token: String.duplicate("a", 32), ip: ip]}]
        assert %Atanor.Config{} = Atanor.Config.build(opts)
      end

      # Loopback keeps short tokens for development.
      assert %Atanor.Config{} = Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, admin: [token: "x"])
    end

    test "without the option there is no admin listener" do
      node = Node.start()
      on_exit(fn -> Node.stop(node) end)
      assert catch_exit(Atanor.admin_port(node.name))
    end
  end

  describe "unknown tokens" do
    test "a token that does not exist is read from the store once, then refused from memory" do
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      {:ok, _} = start_supervised({AlambiqueTestkit.MemoryStore, name: name})

      store =
        Atanor.Test.CountingStore.wrap(
          {AlambiqueTestkit.MemoryStore, AlambiqueTestkit.MemoryStore.config(name)},
          "tokens/"
        )

      node = Node.start(store: store, admin: [token: @token, port: 0, unknown_token_ms: 60_000])
      on_exit(fn -> Node.stop(node) end)
      bearer = "atn_" <> String.duplicate("0", 24) <> "_" <> String.duplicate("A", 43)

      for _ <- 1..30 do
        assert get(node, "/heads", headers: [{"authorization", "Bearer " <> bearer}]).status == 401
      end

      assert Atanor.Test.CountingStore.reads(store) == 1

      # Another id is another read.
      other = "atn_" <> String.duplicate("1", 24) <> "_" <> String.duplicate("A", 43)
      assert get(node, "/heads", headers: [{"authorization", "Bearer " <> other}]).status == 401
      assert Atanor.Test.CountingStore.reads(store) == 2
    end
  end

  describe "nodes" do
    test "a node alone has no peers, and the hint needs a known node and the token" do
      node = start()
      assert %{"nodes" => []} = node |> get("/nodes") |> json()
      assert get(node, "/nodes/nobody@nowhere/gone", method: :post).status == 404
      assert get(node, "/nodes/nobody@nowhere/gone", method: :post, headers: []).status == 401
    end
  end

  describe "authentication" do
    test "every request needs the bearer token" do
      node = start()

      for headers <- [
            [],
            [{"authorization", "Bearer wrong"}],
            [{"authorization", @token}],
            [{"authorization", "Basic " <> @token}]
          ] do
        response = get(node, "/health", headers: headers)
        assert response.status == 401
        assert json(response) == %{"error" => "unauthorized"}
        assert response.headers["www-authenticate"] == ["Bearer"]
      end

      assert get(node, "/health").status == 200
      assert get(node, "/nothing", headers: []).status == 401
    end

    test "unknown paths are 404 and a read endpoint refuses POST" do
      node = start()
      assert get(node, "/workers", method: :post).status == 405
      assert get(node, "/nothing").status == 404
    end
  end

  describe "jobs and operations" do
    defp job_node do
      start([Manifests.jobs("jobs")],
        alarms: [tick_ms: 20],
        sweeps: [
          poll_ms: 50,
          lease_ttl_ms: 2_000,
          renew_ms: 500,
          cell_timeout_ms: 1_000,
          rate_per_s: 100,
          concurrency: 2,
          page_size: 10,
          cell_attempts: 1,
          retry_ms: 10
        ]
      )
    end

    test "jobs: count, a cell page, and retry of a dead job" do
      node = job_node()
      {:ok, _} = Atanor.Cell.query(node.name, {"jobs", "a"}, "SELECT 1")
      assert {:ok, _} = Atanor.Jobs.enqueue_direct(node.name, "jobs", {"jobs", "a"}, %{kind: "test", payload: "ok"})

      assert until(fn ->
               match?(
                 {:ok, %{rows: [["done"]]}},
                 Atanor.Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs")
               )
             end)

      %{"nodes" => nodes, "total" => 0} = json(get(node, "/jobs"))
      assert map_size(nodes) == 1

      %{"jobs" => [job]} = json(get(node, "/jobs/jobs/a"))
      assert job["state"] == "done"
      assert json(get(node, "/jobs/jobs/a/#{job["id"]}"))["id"] == job["id"]

      assert {:ok, _} =
               Atanor.Jobs.enqueue_direct(node.name, "jobs", {"jobs", "a"}, %{
                 kind: "fail",
                 payload: "fail",
                 max_attempts: 1
               })

      assert until(fn ->
               match?(
                 {:ok, %{rows: [["dead"]]}},
                 Atanor.Cell.query(
                   node.name,
                   {"jobs", "a"},
                   "SELECT state FROM _atanor_jobs WHERE last_error IS NOT NULL"
                 )
               )
             end)

      dead = json(get(node, "/jobs/jobs/a?state=dead"))["jobs"] |> hd()
      assert post(node, "/jobs/jobs/a/#{dead["id"]}/retry", %{}).status == 200
    end

    test "operations: create, list, pause and cancel" do
      node = job_node()

      # Enough cells at one dispatch per second: the operation cannot finish
      # before pause, so pause is not a race against its last page.
      keys = ["a" | for(i <- 1..29, do: "k#{i}")]
      for key <- keys, do: {:ok, _} = Atanor.Cell.query(node.name, {"jobs", key}, "SELECT 1")

      attrs = %{
        "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
        "action" => %{
          "worker" => "jobs",
          "kind" => "sweep",
          "payload_base64" => Base.encode64("x")
        },
        "rate_per_s" => 1,
        "concurrency" => 1,
        "page_size" => 1
      }

      assert %{"id" => id, "state" => "running"} = response = json(post(node, "/operations", attrs))
      assert response["selector"]["kind"] == "namespace"
      assert %{"operations" => [_]} = json(get(node, "/operations"))
      assert json(get(node, "/operations/#{id}"))["id"] == id

      assert %{"state" => "paused"} = json(post(node, "/operations/#{id}/pause", %{}))
      assert %{"state" => "cancelled"} = json(post(node, "/operations/#{id}/cancel", %{}))
      assert post(node, "/operations/missing/pause", %{}).status == 404

      assert post(node, "/operations", %{
               "selector" => %{"kind" => "namespace", "namespace" => "missing"},
               "action" => %{"worker" => "jobs", "kind" => "x"}
             }).status == 400
    end
  end

  describe "canary confirmation" do
    test "continue confirms an operation that waits for its canary" do
      node = job_node()
      for key <- ~w(a b), do: {:ok, _} = Atanor.Cell.query(node.name, {"jobs", key}, "SELECT 1")

      attrs = %{
        "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
        "action" => %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("x")},
        "canary_size" => 1,
        "canary_gate" => "pause"
      }

      assert %{"id" => id, "canary" => %{"gate" => "pause"}} = json(post(node, "/operations", attrs))
      assert post(node, "/operations/missing/continue", %{}).status == 404

      assert until(fn -> json(get(node, "/operations/#{id}"))["state"] == "awaiting_confirmation" end)

      assert %{"state" => "running", "canary" => %{"passed" => true}} =
               json(post(node, "/operations/#{id}/continue", %{}))

      assert post(node, "/operations/#{id}/continue", %{}).status == 409
    end
  end

  describe "endpoints" do
    test "health" do
      node = start([notes("a")])
      assert %{"status" => "ok", "node" => _, "nodes" => [_], "workers" => 1} = json(get(node, "/health"))
    end

    test "workers: the heads of the store" do
      node = start([notes("a"), notes("b")], namespaces: %{"notes" => ["a", "b"]})
      %{"workers" => workers} = json(get(node, "/workers"))
      assert [%{"worker" => "a", "revision" => 1, "previous" => []}, %{"worker" => "b"}] = workers
      {:ok, active} = Atanor.Registry.deployment(node.name, "a")
      assert hd(workers)["active"] == active.id
    end

    test "a worker: its head and the deployment this node serves" do
      node = start([notes("a", sockets: false, secrets: ["API"], allow: ["api.example.com"])])
      {:ok, active} = Atanor.Registry.deployment(node.name, "a")
      body = json(get(node, "/workers/a"))

      assert body["active"] == active.id
      %{"id" => id, "kind" => "native", "bindings" => bindings, "routes" => routes} = body["deployment"]
      assert id == active.id
      assert %{"cells" => %{"notes" => _}, "secrets" => ["API"], "http" => %{"allow" => ["api.example.com"]}} = bindings
      assert routes == [%{"http" => %{"host" => "127.0.0.1", "path" => "/a"}}]
      assert get(node, "/workers/missing").status == 404
    end

    test "deployments: the status of every node, with the reason a head was not applied" do
      node = start([notes("a")], listeners: %{"smtp" => 0})
      bad = Manifests.probe("bad", module: LineWorker, tcp: ["nolistener"])
      assert %{error: {:listener_not_configured, "nolistener"}} = Manifests.forge_head(node, bad)

      body = json(get(node, "/deployments"))
      assert body["partial"] == false
      assert [{name, %{"status" => "ok", "workers" => workers}}] = Map.to_list(body["nodes"])
      assert name == Atom.to_string(node())

      assert %{"worker" => "a", "error" => nil, "serving" => id, "applied" => id, "head" => id} =
               Enum.find(workers, &(&1["worker"] == "a"))

      assert %{"worker" => "bad", "serving" => nil, "applied" => nil, "error" => error} =
               Enum.find(workers, &(&1["worker"] == "bad"))

      assert error =~ "listener_not_configured"
    end

    test "routes: HTTP routes and TCP listeners" do
      node =
        start(
          [
            notes("a"),
            Manifests.probe("mail", module: LineWorker, cells: %{"mail" => LineWorker.migrations()}, tcp: ["smtp"])
          ],
          listeners: %{"smtp" => 0}
        )

      {:ok, port} = Atanor.TCP.port(node.name, "smtp")

      assert %{"http" => [%{"host" => "127.0.0.1", "path" => "/a", "worker" => "a"}], "tcp" => [tcp]} =
               json(get(node, "/routes"))

      assert tcp == %{"listener" => "smtp", "port" => port, "worker" => "mail"}
    end

    test "cells: counts, then pages of the live cells of a node" do
      node = start([notes("a")])
      for key <- ~w(c1 c2 c3 c4 c5), do: {:ok, _} = Atanor.Cell.query(node.name, {"notes", key}, "SELECT 1")
      me = Atom.to_string(node())
      # The live-cell index follows the registry by a message.
      assert until(fn -> json(get(node, "/cells"))["total"] == 5 end)

      assert %{"total" => 5, "partial" => false, "nodes" => %{^me => %{"status" => "ok", "count" => 5}}} =
               json(get(node, "/cells"))

      first = json(get(node, "/cells?node=#{me}&limit=2"))
      assert first["node"] == me
      assert Enum.map(first["cells"], & &1["key"]) == ["c1", "c2"]
      assert hd(first["cells"]) == %{"namespace" => "notes", "key" => "c1", "id" => "notes.c1"}
      assert first["next"] == "notes.c2"

      second = json(get(node, "/cells?node=#{me}&limit=2&after=notes.c2"))
      assert Enum.map(second["cells"], & &1["key"]) == ["c3", "c4"]

      last = json(get(node, "/cells?node=#{me}&limit=2&after=notes.c4"))
      assert Enum.map(last["cells"], & &1["key"]) == ["c5"]
      assert last["next"] == nil

      assert get(node, "/cells?node=#{me}&limit=0").status == 400
      assert get(node, "/cells?node=#{me}&limit=1001").status == 400
      assert get(node, "/cells?node=nobody@nowhere").status == 404
    end

    test "the default and maximum page sizes come from :admin" do
      node =
        Node.start(
          workers: [notes("a")],
          admin: [token: @token, port: 0, default_limit: 2, max_limit: 2]
        )

      on_exit(fn -> Node.stop(node) end)
      for key <- ~w(c1 c2 c3 c4 c5), do: {:ok, _} = Atanor.Cell.query(node.name, {"notes", key}, "SELECT 1")
      me = Atom.to_string(node())
      assert until(fn -> json(get(node, "/cells"))["total"] == 5 end)

      default = json(get(node, "/cells?node=#{me}"))
      assert Enum.map(default["cells"], & &1["key"]) == ["c1", "c2"]
      assert get(node, "/cells?node=#{me}&limit=3").status == 400
      assert json(get(node, "/cells?node=#{me}&limit=2"))["next"] == "notes.c2"
    end
  end
end
