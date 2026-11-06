defmodule Atanor.BindingsTest do
  use ExUnit.Case, async: true

  alias Atanor.{Request, Response}
  alias Atanor.Test.{Await, HTTPTarget, Manifests}
  alias AtanorTestkit.Node

  @notes Manifests.notes_migrations()
  @host "127.0.0.1"

  defp start(workers, opts \\ []) do
    node = Node.start([workers: workers] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp routed(name, opts \\ []), do: Manifests.probe(name, [routes: [{@host, "/#{name}"}]] ++ opts)

  # Calls the probe worker `name`; returns its JSON reply.
  defp ask(node, name, path, opts \\ []) do
    resp = Req.request!([url: "#{node.url}/#{name}#{path}", retry: false] ++ opts)
    assert resp.status == 200
    resp.body
  end

  defp cell(node, name, op, ns, key, sql, params \\ []) do
    body = %{op: op, ns: ns, key: key, sql: sql, params: params}
    ask(node, name, "/cell", method: :post, json: body)
  end

  describe "cells" do
    setup do
      %{node: start([routed("w", cells: %{"notes" => @notes})])}
    end

    test "granted namespaces work, with the manifest's migrations applied", %{node: node} do
      assert %{"ok" => _} = cell(node, "w", "execute", "notes", "a", "INSERT INTO notes (body) VALUES (?)", ["hi"])
      assert %{"ok" => %{"rows" => [["hi"]]}} = cell(node, "w", "query", "notes", "a", "SELECT body FROM notes")
      assert %{"ok" => _} = cell(node, "w", "transaction", "notes", "a", "DELETE FROM notes")
      assert %{"ok" => %{"rows" => []}} = cell(node, "w", "query", "notes", "a", "SELECT body FROM notes")

      assert %{"ok" => %{"rows" => [[1]]}} =
               cell(node, "w", "query", "notes", "b", "PRAGMA user_version")
    end

    test "ungranted namespaces are refused, even when another worker grants them", %{node: node} do
      {:ok, _} = Node.deploy(node, routed("v", cells: %{"other" => []}))

      for op <- ["query", "execute", "transaction"] do
        assert %{"error" => ~s({:not_granted, {:cell, "other"}})} = cell(node, "w", op, "other", "a", "SELECT 1")
      end

      assert %{"ok" => _} = cell(node, "v", "query", "other", "a", "SELECT 1")
      assert %{"error" => ~s({:not_granted, {:cell, "notes"}})} = cell(node, "v", "query", "notes", "a", "SELECT 1")
    end

    test "a namespace shared by two workers needs identical migrations" do
      node = start([routed("w", cells: %{"notes" => @notes})], namespaces: %{"notes" => ["w", "v", "x"]})
      assert {:ok, _} = Node.deploy(node, routed("v", cells: %{"notes" => @notes}))

      other = routed("x", cells: %{"notes" => @notes ++ [[2, "CREATE TABLE extra (x)"]]})
      assert {:error, {:namespace_conflict, "notes", conflicting}} = Node.deploy(node, other)
      assert conflicting in ["w", "v"]
      assert {:error, :not_found} = Atanor.Deployments.head(node.name, "x")
    end

    test "migrations cannot be lowered, and a namespace leaves with its last worker", %{node: node} do
      v2 = routed("w", cells: %{"notes" => @notes ++ [[2, "CREATE TABLE extra (x)"]]})
      assert {:ok, _} = Node.deploy(node, v2)

      assert {:error, {:migrations_lowered, "notes"}} =
               Node.deploy(node, routed("w", cells: %{"notes" => @notes}))

      {:ok, _} = Node.undeploy(node, "w")
      assert {:error, {:unknown_namespace, "notes"}} = Atanor.Cell.query(node.name, {"notes", "a"}, "SELECT 1")
    end

    test "a later worker version upgrades the cells that are awake", %{node: node} do
      :telemetry.attach(
        {__MODULE__, node.name},
        [:atanor, :cells, :migrate],
        fn _, measurements, meta, test -> send(test, {:migrated, measurements, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, node.name}) end)

      cell(node, "w", "execute", "notes", "a", "INSERT INTO notes (body) VALUES ('old')")
      v2 = routed("w", cells: %{"notes" => @notes ++ [[2, "ALTER TABLE notes ADD COLUMN tag TEXT"]]})
      {:ok, _} = Node.deploy(node, v2)

      assert %{"ok" => %{"rows" => [["old", nil]]}} =
               Await.until(
                 fn ->
                   with %{"ok" => _} = reply <- cell(node, "w", "query", "notes", "a", "SELECT body, tag FROM notes") do
                     reply
                   else
                     _ -> nil
                   end
                 end,
                 10_000
               )

      assert_receive {:migrated, %{count: 1}, %{namespace: "notes"}}, 5_000
    end
  end

  describe "secrets" do
    setup do
      secrets = %{"w" => %{"TOKEN" => "s3cr3t", "NOT_IN_MANIFEST" => "hidden"}, "v" => %{"TOKEN" => "other"}}
      node = start([routed("w", secrets: ["TOKEN", "UNSET"]), routed("v", secrets: ["TOKEN"])], secrets: secrets)
      %{node: node}
    end

    test "granted secrets come from the operator's config", %{node: node} do
      assert ask(node, "w", "/secret?name=TOKEN") == %{"ok" => "s3cr3t"}
      assert ask(node, "v", "/secret?name=TOKEN") == %{"ok" => "other"}
    end

    test "names outside the manifest are not granted, even when the operator supplied them", %{node: node} do
      assert ask(node, "w", "/secret?name=NOT_IN_MANIFEST") == %{
               "error" => ~s({:not_granted, {:secret, "NOT_IN_MANIFEST"}})
             }
    end

    test "a granted secret the operator did not supply is reported", %{node: node} do
      assert ask(node, "w", "/secret?name=UNSET") == %{"error" => ~s({:missing_secret, "UNSET"})}
    end

    test "values are in neither the manifest nor the config's inspect output", %{node: node} do
      {:ok, deployment} = Atanor.Registry.deployment(node.name, "w")
      refute inspect(deployment) =~ "s3cr3t"
      refute inspect(Atanor.Registry.config(node.name)) =~ "s3cr3t"
    end
  end

  describe "outbound HTTP" do
    setup do
      {_target, port} = HTTPTarget.start(self())
      node = start([routed("w", allow: [@host]), routed("none")], allow_private_hosts: [@host])
      %{node: node, target: "http://#{@host}:#{port}", denied: "http://localhost:#{port}"}
    end

    defp fetch(node, name, url), do: ask(node, name, "/fetch?" <> URI.encode_query(url: url))

    test "reaches an allowed host", %{node: node, target: target} do
      assert %{"ok" => %{"status" => 200, "body" => "hello"}} = fetch(node, "w", target <> "/ok")
      assert_received {:target_hit, "/ok"}
    end

    test "refuses other hosts without connecting", %{node: node, target: target, denied: denied} do
      assert %{"error" => ~s({:not_granted, {:http, "localhost"}})} = fetch(node, "w", denied <> "/ok")
      assert %{"error" => ~s({:not_granted, {:http, "127.0.0.1"}})} = fetch(node, "none", target <> "/ok")
      assert %{"error" => ~s({:not_granted, {:http, "example.invalid"}})} = fetch(node, "w", "http://example.invalid/")
      refute_received {:target_hit, _}
    end

    test "matches hosts exactly, ignoring case", %{node: node} do
      assert %{"error" => ~s({:not_granted, {:http, "x.127.0.0.1"}})} = fetch(node, "w", "http://X.127.0.0.1/")
    end

    test "follows redirects to allowed hosts", %{node: node, target: target} do
      assert %{"ok" => %{"status" => 200, "body" => "hello"}} = fetch(node, "w", target <> "/redirect-in")
      assert_received {:target_hit, "/redirect-in"}
      assert_received {:target_hit, "/ok"}
    end

    test "refuses a redirect to a host that is not allowed", %{node: node, target: target} do
      assert %{"error" => ~s({:not_granted, {:http, "localhost"}})} = fetch(node, "w", target <> "/redirect-out")
      assert_received {:target_hit, "/redirect-out"}
      refute_received {:target_hit, "/ok"}
    end

    test "stops redirects at the configured limit", %{target: target} do
      node = start([routed("w", allow: [@host])], allow_private_hosts: [@host], calls: [max_redirects: 2])
      assert %{"error" => ":too_many_redirects"} = fetch(node, "w", target <> "/redirect-loop")
    end

    test "refuses an allowed name that resolves to a private address, without connecting", %{denied: denied} do
      node = start([routed("w", allow: ["localhost"])])
      assert %{"error" => error} = fetch(node, "w", denied <> "/ok")
      assert error =~ ~s({:private_address, "localhost", )
      refute_received {:target_hit, _}
    end

    test "connects to private addresses the operator permits, by name or by CIDR", %{target: target, denied: denied} do
      by_name = start([routed("w", allow: ["localhost"])], allow_private_hosts: ["localhost"])
      assert %{"ok" => %{"status" => 200}} = fetch(by_name, "w", denied <> "/by-name")
      assert_received {:target_hit, "/by-name"}

      by_cidr = start([routed("w", allow: [@host])], allow_private_hosts: ["127.0.0.0/8"])
      assert %{"ok" => %{"status" => 200}} = fetch(by_cidr, "w", target <> "/by-cidr")
      assert_received {:target_hit, "/by-cidr"}

      other = start([routed("w", allow: [@host])], allow_private_hosts: ["10.0.0.0/8"])
      assert %{"error" => error} = fetch(other, "w", target <> "/refused")
      assert error =~ ~s({:private_address, "127.0.0.1", "127.0.0.1"})
      refute_received {:target_hit, "/refused"}
    end

    test "grants by scheme and port", %{target: target} do
      port = URI.parse(target).port
      ok = start([routed("w", allow: ["http://#{@host}:#{port}"])], allow_private_hosts: [@host])
      assert %{"ok" => %{"status" => 200}} = fetch(ok, "w", target <> "/scheme")

      for allow <- ["https://#{@host}:#{port}", "#{@host}:#{port + 1}", "http://#{@host}"] do
        node = start([routed("w", allow: [allow])], allow_private_hosts: [@host])
        assert %{"error" => ~s({:not_granted, {:http, "127.0.0.1"}})} = fetch(node, "w", target <> "/scheme")
      end
    end

    test "Env.fetch takes a request struct and returns a response struct", %{node: node, target: target} do
      {:ok, deployment} = Atanor.Registry.deployment(node.name, "w")
      env = Atanor.Env.new(node.name, deployment)
      uri = URI.parse(target)
      request = %Request{host: uri.host, port: uri.port, path: "/ok", headers: [{"x-a", "b"}]}
      assert {:ok, %Response{status: 200, body: "hello", headers: headers}} = Atanor.Env.fetch(env, request)
      assert List.keyfind(headers, "content-length", 0)
      assert {:error, {:unsupported_scheme, "ftp"}} = Atanor.Env.fetch(env, %{request | scheme: "ftp"})
      assert {:error, {:unsupported_method, "BREW"}} = Atanor.Env.fetch(env, %{request | method: "BREW"})
    end
  end

  describe "worker calls" do
    setup do
      node =
        start([
          routed("caller", workers: ["callee", "rec", "missing", "web"]),
          routed("callee", callable_by: ["caller"]),
          routed("rec", workers: ["rec"]),
          routed("lonely"),
          Manifests.probe("web", module: Atanor.Test.PlugWorker, callable_by: ["caller"])
        ])

      %{node: node}
    end

    defp call(node, worker, path \\ "/echo"),
      do: ask(node, "caller", "/call?" <> URI.encode_query(worker: worker, path: path))

    test "reach a granted worker's active deployment", %{node: node} do
      assert %{"ok" => %{"status" => 200, "body" => body}} = call(node, "callee")
      assert %{"worker" => "callee"} = Jason.decode!(body)
    end

    test "a caller cannot set the identity of the end user in the callee", %{node: node} do
      {:ok, deployment} = Atanor.Registry.deployment(node.name, "caller")
      forged = Atanor.Auth.encode_claims(%{"sub" => "admin"})
      headers = [{Atanor.Auth.claims_header(), forged}, {Atanor.Auth.claims_header(), forged}, {"x-other", "kept"}]
      request = %Request{path: "/callee/headers", headers: headers}

      assert {:ok, %{body: body}} = Atanor.Env.call(Atanor.Env.new(node.name, deployment), "callee", request)
      assert Jason.decode!(body)["headers"] == %{"x-other" => "kept"}
    end

    test "the callee does not get the websocket of the caller", %{node: node} do
      {:ok, deployment} = Atanor.Registry.deployment(node.name, "caller")
      env = %{Atanor.Env.new(node.name, deployment) | socket: self()}

      assert {:ok, %{body: body}} = Atanor.Env.call(env, "callee", %Request{path: "/callee/socket"})
      assert Jason.decode!(body) == %{"socket" => "nil"}
    end

    test "refuse workers that are not granted", %{node: node} do
      assert call(node, "lonely") == %{"error" => ~s({:not_granted, {:worker, "lonely"}})}
    end

    test "report granted workers that are not active or have no request handler", %{node: node} do
      assert call(node, "missing") == %{"error" => ~s({:unknown_worker, "missing"})}
      assert call(node, "web") == %{"error" => ~s({:no_request_handler, "web"})}
    end

    test "stop at the depth limit", %{node: node} do
      # Each nested call wraps the callee's reply as the body of an ok.
      assert nesting(ask(node, "rec", "/recurse"), 0) == {8, %{"error" => ":max_call_depth"}}
    end

    test "stop at the configured depth limit" do
      node =
        start(
          [routed("caller", workers: ["rec"]), routed("rec", workers: ["rec"])],
          calls: [max_depth: 2]
        )

      assert nesting(ask(node, "rec", "/recurse"), 0) == {2, %{"error" => ":max_call_depth"}}
    end
  end

  defp nesting(%{"ok" => %{"body" => body}}, depth), do: nesting(Jason.decode!(body), depth + 1)
  defp nesting(other, depth), do: {depth, other}
end
