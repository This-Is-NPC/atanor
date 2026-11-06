defmodule Atanor.AdminDeployTest do
  use ExUnit.Case, async: true

  alias Atanor.{Deployments, Store}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @operator "operator-secret"

  defp start(opts \\ []) do
    node =
      Node.start([admin: [token: @operator, port: 0] ++ Keyword.get(opts, :admin, [])] ++ Keyword.delete(opts, :admin))

    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp request(node, method, path, opts \\ []) do
    token = Keyword.get(opts, :token, @operator)
    headers = (token && [{"authorization", "Bearer " <> token}]) || []

    Req.request!(
      method: method,
      url: "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path,
      headers: headers ++ Keyword.get(opts, :headers, []),
      body: opts[:body],
      retry: false,
      decode_body: false
    )
  end

  defp json(response), do: Jason.decode!(response.body)

  defp post_json(node, path, body, opts \\ []),
    do: request(node, :post, path, [body: Jason.encode!(body)] ++ opts)

  defp package(worker \\ "w", n \\ 1), do: Manifests.package(Manifests.probe(worker, limits: %{"timeout_ms" => n}))

  defp upload(node, package, opts \\ []) do
    worker = Keyword.get(opts, :worker, package.manifest.name)
    query = if opts[:activate], do: "?activate=true", else: ""
    hash = Keyword.get(opts, :hash, package.id)
    headers = if hash, do: [{"x-package-sha256", hash}], else: []

    request(node, :post, "/workers/#{worker}/packages" <> query,
      body: package.bytes,
      headers: headers,
      token: Keyword.get(opts, :token, @operator)
    )
  end

  defp token!(node, scopes, attrs \\ %{}) do
    response = post_json(node, "/tokens", Map.merge(%{"name" => "ci", "scopes" => scopes}, attrs))
    assert response.status == 201
    json(response)
  end

  defp audit(node), do: node |> request(:get, "/audit") |> json() |> Map.fetch!("entries")

  describe "store errors" do
    @sentinel "<Error><AWSAccessKeyId>AKID-SENTINEL</AWSAccessKeyId></Error>"

    test "are not echoed to a caller that is not authenticated" do
      node = start()
      {_module, config} = node.store

      AlambiqueTestkit.MemoryStore.inject(config,
        kind: :error,
        ops: [:get],
        key: ~r{/tokens/},
        reason: {:http, 403, @sentinel}
      )

      bogus = "atn_" <> String.duplicate("0", 24) <> "_" <> String.duplicate("A", 43)
      response = request(node, :get, "/heads", token: bogus)
      assert response.status == 503
      assert json(response) == %{"error" => "store_unavailable"}
    end

    test "are not echoed to a deploy token" do
      node = start()
      %{"token" => token} = token!(node, ["worker:w:deploy"])
      {_module, config} = node.store

      AlambiqueTestkit.MemoryStore.inject(config,
        kind: :error,
        ops: [:put],
        key: ~r{/packages/},
        reason: {:http, 403, @sentinel}
      )

      response = upload(node, package(), token: token)
      assert response.status == 503
      refute response.body =~ "AKID-SENTINEL"
    end
  end

  describe "upload" do
    test "stores the package after checking hash and manifest; it does not activate" do
      node = start()
      pkg = package()

      response = upload(node, pkg)
      assert response.status == 201

      assert %{"worker" => "w", "package_id" => id, "kind" => "native", "head" => nil} = json(response)
      assert id == pkg.id
      assert {:ok, %{id: ^id}} = Deployments.fetch_package(node.name, id)
      assert {:error, :not_found} = Deployments.head(node.name, "w")
    end

    test "with activate=true it also moves the head" do
      node = start()
      pkg = package()
      assert %{"head" => %{"active" => id, "revision" => 1}} = node |> upload(pkg, activate: true) |> json()
      assert id == pkg.id
    end

    test "a hash that does not match is rejected and nothing is stored" do
      node = start()
      pkg = package()
      response = upload(node, pkg, hash: String.duplicate("0", 64))
      assert response.status == 422
      assert json(response) == %{"error" => "hash_mismatch"}
      assert {:error, :not_found} = Store.get(node.name, "packages/" <> pkg.id)
    end

    test "the hash header is required and must be a SHA-256" do
      node = start()
      assert node |> upload(package(), hash: nil) |> Map.get(:status) == 400
      response = upload(node, package(), hash: "abc")
      assert response.status == 400
      assert json(response)["error"] == "invalid_hash"
    end

    test "bytes that are not a valid package are rejected" do
      node = start()
      junk = "not a package"
      hash = :sha256 |> :crypto.hash(junk) |> Base.encode16(case: :lower)

      response =
        request(node, :post, "/workers/w/packages", body: junk, headers: [{"x-package-sha256", hash}])

      assert response.status == 422
      assert %{"error" => "invalid_package"} = json(response)
      assert {:ok, [], nil} = Store.list(node.name, "packages/")
    end

    test "a package of another worker is rejected" do
      node = start()
      response = upload(node, package("other"), worker: "w")
      assert response.status == 422
      assert json(response) == %{"error" => "package_of_other_worker", "package_worker" => "other"}
      assert {:ok, [], nil} = Store.list(node.name, "packages/")
    end

    test "the size limit is configurable and enforced before storing" do
      node = start(admin: [max_package_bytes: 100])
      pkg = package()
      assert byte_size(pkg.bytes) > 100
      response = upload(node, pkg)
      assert response.status == 413
      assert json(response) == %{"error" => "package_too_large", "max_bytes" => 100}
      assert {:ok, [], nil} = Store.list(node.name, "packages/")
    end

    test "an activation that conflicts with the node is refused with the subject, not with another worker" do
      node = start(hosts: %{"a" => ["127.0.0.1"], "b" => ["127.0.0.1"], "c" => ["a.test"]})
      notes = Manifests.notes_migrations()
      deploy = fn manifest -> assert {:ok, _} = Node.deploy(node, manifest) end

      refuse = fn manifest ->
        node |> upload(Manifests.package(manifest), activate: true) |> then(&{&1.status, json(&1)})
      end

      deploy.(Manifests.probe("a", routes: [{"127.0.0.1", "/x"}], cells: %{"notes" => notes}))

      assert {409, %{"error" => "route_taken", "subject" => "127.0.0.1/x"}} =
               refuse.(Manifests.probe("b", routes: [{"127.0.0.1", "/x"}]))

      assert {409, %{"error" => "namespace_owned", "subject" => "notes"} = body} =
               refuse.(Manifests.probe("b", cells: %{"notes" => notes}))

      refute inspect(body) =~ ~s("a")

      deploy.(Manifests.probe("v", cells: %{"events" => notes ++ [[2, "CREATE TABLE extra (x)"]]}))

      assert {409, %{"error" => "migrations_lowered", "subject" => "events"}} =
               refuse.(Manifests.probe("v", cells: %{"events" => notes}, limits: %{"timeout_ms" => 7}))

      assert {422, %{"error" => "host_not_allowed", "subject" => "b.test"}} =
               refuse.(Manifests.probe("c", routes: [{"b.test", "/"}]))

      assert {422, %{"error" => "listener_not_configured", "subject" => "smtp"}} =
               refuse.(Manifests.probe("t", tcp: ["smtp"]))

      assert {:error, :not_found} = Deployments.head(node.name, "b")
    end

    test "an invalid worker name is a 400" do
      node = start()
      assert node |> upload(package(), worker: "Bad.Name") |> Map.get(:status) == 400
    end
  end

  describe "versions" do
    test "activate, rollback, versions, status and heads" do
      node = start()
      p1 = package("w", 1)
      p2 = package("w", 2)
      upload(node, p1, activate: true)
      upload(node, p2)

      assert %{"active" => id1, "previous" => []} = node |> request(:get, "/workers/w/versions") |> json()
      assert id1 == p1.id

      response = post_json(node, "/workers/w/activate", %{"package_id" => p2.id})
      assert %{"active" => id2, "previous" => [^id1], "revision" => 2} = json(response)
      assert id2 == p2.id

      assert %{"active" => ^id2, "node" => _, "applied" => _} = node |> request(:get, "/workers/w/status") |> json()
      assert %{"workers" => [%{"worker" => "w", "active" => ^id2}]} = node |> request(:get, "/heads") |> json()

      assert %{"active" => ^id1, "previous" => []} = node |> request(:post, "/workers/w/rollback") |> json()
      response = request(node, :post, "/workers/w/rollback")
      assert response.status == 409
      assert json(response) == %{"error" => "no_previous"}
    end

    test "lists the uploaded versions, oldest first, with their state and uploader" do
      node = start()
      %{"id" => tid, "token" => t} = token!(node, ["worker:w:deploy", "worker:w:read"])
      [p1, p2, p3] = for n <- 1..3, do: package("w", n)
      for p <- [p1, p2, p3], do: assert(upload(node, p, token: t).status == 201)
      assert upload(node, p2, token: t).status == 201

      assert %{"active" => nil, "versions" => versions, "next" => nil} =
               node |> request(:get, "/workers/w/versions") |> json()

      assert Enum.map(versions, & &1["package_id"]) == [p1.id, p2.id, p3.id]

      assert [%{"kind" => "native", "state" => nil, "uploaded_at" => _, "size" => size, "uploaded_by" => by} | _] =
               versions

      assert size == byte_size(p1.bytes)
      assert by == %{"type" => "token", "id" => tid, "name" => "ci"}

      assert %{"versions" => [%{"id" => first}, _], "next" => next} =
               node |> request(:get, "/workers/w/versions?limit=2") |> json()

      assert is_binary(next)

      assert %{"versions" => [%{"package_id" => last}], "next" => nil} =
               node |> request(:get, "/workers/w/versions?limit=2&after=" <> next) |> json()

      assert last == p3.id
      assert first < next

      for p <- [p3, p2, p1], do: post_json(node, "/workers/w/activate", %{"package_id" => p.id})
      assert %{"active" => a, "previous" => [_]} = node |> request(:post, "/workers/w/rollback") |> json()
      assert a == p2.id

      %{"versions" => states} = node |> request(:get, "/workers/w/versions") |> json()
      assert Enum.map(states, & &1["state"]) == [nil, "active", "previous"]
      assert request(node, :get, "/workers/w/versions?limit=0").status == 400
    end

    test "an in-process deploy writes the same index" do
      node = start()
      store = Store.handle(node.name)
      assert {:ok, _, _} = Atanor.Deployments.Service.deploy(store, package("w", 7), false, %{"type" => "script"})

      assert %{"versions" => [%{"uploaded_by" => %{"type" => "script"}}]} =
               node |> request(:get, "/workers/w/versions") |> json()
    end

    test "errors are JSON" do
      node = start()
      assert node |> request(:get, "/workers/nope/versions") |> Map.get(:status) == 404
      assert node |> request(:get, "/workers/nope/status") |> Map.get(:status) == 404

      response = post_json(node, "/workers/w/activate", %{"package_id" => String.duplicate("a", 64)})
      assert response.status == 404
      assert json(response) == %{"error" => "package_not_found"}

      assert post_json(node, "/workers/w/activate", %{"package_id" => "x"}).status == 400
      assert request(node, :post, "/workers/w/activate", body: "{").status == 400
    end

    test "a package of another worker cannot be activated" do
      node = start()
      pkg = package("other")
      upload(node, pkg)
      assert post_json(node, "/workers/w/activate", %{"package_id" => pkg.id}).status == 422
    end

    test "a token sees only the heads it may read" do
      node = start()
      for w <- ["a", "b"], do: upload(node, package(w), activate: true)
      %{"token" => t} = token!(node, ["worker:b:read"])
      assert %{"workers" => [%{"worker" => "b"}]} = node |> request(:get, "/heads", token: t) |> json()
      %{"token" => all} = token!(node, ["worker:*:read"])
      assert %{"workers" => [_, _]} = node |> request(:get, "/heads", token: all) |> json()
      %{"token" => none} = token!(node, ["cluster:admin"])
      assert %{"workers" => []} = node |> request(:get, "/heads", token: none) |> json()
    end
  end

  describe "tokens" do
    test "create returns the secret once; the store keeps only a hash" do
      node = start()
      created = token!(node, ["worker:w:deploy", "worker:w:deploy"], %{"description" => "CI for w"})

      assert %{"id" => "atn_" <> _ = id, "token" => secret, "name" => "ci", "scopes" => ["worker:w:deploy"]} = created
      assert %{"created_at" => _, "created_by" => "operator", "expires_at" => nil, "revoked_at" => nil} = created
      refute Map.has_key?(created, "hash")

      {:ok, raw, _, _} = Store.get(node.name, "tokens/" <> id)
      refute raw =~ secret
      refute raw =~ String.replace_prefix(secret, id <> "_", "")

      got = node |> request(:get, "/tokens/" <> id) |> json()
      refute Map.has_key?(got, "token")
      refute Map.has_key?(got, "hash")
      assert got["id"] == id

      assert %{"tokens" => [%{"id" => ^id}], "next" => nil} = node |> request(:get, "/tokens") |> json()
    end

    test "scopes, name and expiry are validated" do
      node = start()
      future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      for attrs <- [
            %{},
            %{"name" => "x"},
            %{"name" => "x", "scopes" => []},
            %{"name" => "x", "scopes" => ["worker:w:delete"]},
            %{"name" => "x", "scopes" => ["worker:*x:read"]},
            %{"name" => "x", "scopes" => "cluster:admin"},
            %{"name" => "", "scopes" => ["cluster:admin"]},
            %{"name" => 1, "scopes" => ["cluster:admin"]},
            %{"name" => "x", "scopes" => ["cluster:admin"], "expires_at" => "tomorrow"},
            %{"name" => "x", "scopes" => ["cluster:admin"], "expires_at" => "2001-01-01T00:00:00Z"}
          ] do
        response = post_json(node, "/tokens", attrs)
        assert response.status == 400, inspect(attrs)
        assert %{"error" => "invalid_token", "reason" => _} = json(response)
      end

      assert post_json(node, "/tokens", %{"name" => "x", "scopes" => ["cluster:admin"], "expires_at" => future}).status ==
               201

      assert request(node, :post, "/tokens", body: "[").status == 400
    end

    test "the number of scopes is limited" do
      node = start(admin: [max_scopes: 2])

      response =
        post_json(node, "/tokens", %{"name" => "x", "scopes" => ["worker:a:read", "worker:b:read", "worker:c:read"]})

      assert response.status == 400
    end

    test "an expired token is rejected" do
      node = start()
      %{"id" => id, "token" => t} = token!(node, ["worker:*:read"])
      assert request(node, :get, "/heads", token: t).status == 200

      {:ok, raw, _, _} = Store.get(node.name, "tokens/" <> id)
      past = DateTime.utc_now() |> DateTime.add(-5) |> DateTime.to_iso8601()
      expired = raw |> Jason.decode!() |> Map.put("expires_at", past) |> Jason.encode!()
      {:ok, _} = Store.put(node.name, "tokens/" <> id, expired)

      response = request(node, :get, "/heads", token: t)
      assert response.status == 401
      assert json(response) == %{"error" => "unauthorized"}
    end

    test "revocation is immediate, idempotent, and seen by every node sharing the store" do
      a = Node.start(admin: [token: @operator, port: 0], prefix: "shared")
      on_exit(fn -> Node.stop(a) end)
      b = Node.start(admin: [token: @operator, port: 0], prefix: "shared", store: a.store)
      on_exit(fn -> Node.stop(b) end)

      %{"id" => id, "token" => t} = token!(a, ["worker:*:read"])
      assert request(b, :get, "/heads", token: t).status == 200

      response = request(a, :post, "/tokens/#{id}/revoke")
      assert response.status == 200
      assert %{"revoked_at" => first} = json(response)

      assert request(a, :get, "/heads", token: t).status == 401
      assert request(b, :get, "/heads", token: t).status == 401
      assert %{"revoked_at" => ^first} = a |> request(:post, "/tokens/#{id}/revoke") |> json()
      assert request(b, :post, "/tokens/atn_000000000000000000000000/revoke").status == 404
    end

    test "only cluster:admin manages tokens and reads the audit log" do
      node = start()
      %{"token" => deployer} = token!(node, ["worker:*:deploy", "worker:*:read"])
      %{"token" => admin} = token!(node, ["cluster:admin"])

      for {method, path} <- [{:get, "/tokens"}, {:get, "/audit"}, {:get, "/workers"}, {:get, "/nodes"}] do
        assert request(node, method, path, token: deployer).status == 403, path
        assert request(node, method, path, token: admin).status == 200, path
      end

      assert post_json(node, "/tokens", %{"name" => "x", "scopes" => ["cluster:admin"]}, token: deployer).status == 403
      assert request(node, :post, "/tokens/atn_000000000000000000000000/revoke", token: deployer).status == 403
      assert request(node, :get, "/health", token: deployer).status == 200
    end

    test "uploading with activate=true needs the activate scope too" do
      node = start()
      %{"token" => t} = token!(node, ["worker:w:deploy"])
      response = upload(node, package(), token: t, activate: true)
      assert response.status == 403
      assert json(response)["required"] == "worker:w:activate"
      assert {:ok, [], nil} = Store.list(node.name, "packages/")
      assert upload(node, package(), token: t).status == 201
    end

    test "the token never appears in an error body" do
      node = start()

      for t <- ["atn_0123456789abcdef01234567_" <> String.duplicate("A", 43), "garbage", @operator <> "x"] do
        response = request(node, :get, "/heads", token: t)
        assert response.status == 401
        refute response.body =~ t
      end
    end
  end

  describe "audit" do
    test "records who did what, with results, including denials" do
      node = start()
      %{"id" => id, "token" => t} = token!(node, ["worker:w:deploy", "worker:w:read"], %{"name" => "ci-w"})
      pkg = package()
      assert upload(node, pkg, token: t).status == 201
      assert post_json(node, "/workers/w/activate", %{"package_id" => pkg.id}, token: t).status == 403
      assert upload(node, pkg, token: t, hash: String.duplicate("1", 64)).status == 422
      request(node, :post, "/workers/w/activate", body: Jason.encode!(%{"package_id" => pkg.id}))

      entries = audit(node)

      assert [
               %{"action" => "token.create", "actor" => %{"type" => "operator"}, "result" => "ok", "target" => ^id}
               | rest
             ] = entries

      assert [
               %{"action" => "package.upload", "worker" => "w", "version" => v, "result" => "ok", "status" => 201} = up,
               %{"action" => "version.activate", "result" => "denied", "status" => 403, "error" => "forbidden"},
               %{"action" => "package.upload", "result" => "failed", "status" => 422, "error" => "hash_mismatch"},
               %{"action" => "version.activate", "actor" => %{"type" => "operator"}, "result" => "ok"}
             ] = rest

      assert v == pkg.id
      assert up["actor"] == %{"type" => "token", "id" => id, "name" => "ci-w"}
      assert up["node"] == to_string(node())
      assert %{"time" => _, "remote_ip" => "127.0.0.1", "id" => _} = up
      refute inspect(entries) =~ "atn_" <> String.duplicate("0", 4) <> "x"
    end

    test "is paginated within the configured limits" do
      node = start(admin: [default_limit: 2, max_limit: 3])
      for _ <- 1..6, do: token!(node, ["cluster:admin"])

      assert %{"entries" => [_, _], "next" => next} = node |> request(:get, "/audit") |> json()
      assert is_binary(next)

      assert %{"entries" => [_, _, _], "next" => next2} =
               node |> request(:get, "/audit?limit=3&after=" <> next) |> json()

      assert %{"entries" => [], "next" => nil} = node |> request(:get, "/audit?after=zzz") |> json()
      assert request(node, :get, "/audit?limit=4").status == 400
      assert request(node, :get, "/audit?limit=0").status == 400
      assert is_binary(next2)
    end

    test "a burst of events is kept complete" do
      node = start()
      for _ <- 1..6, do: token!(node, ["cluster:admin"])
      assert length(audit(node)) == 6
    end
  end
end
