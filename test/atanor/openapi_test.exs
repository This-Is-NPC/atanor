defmodule Atanor.OpenAPITest do
  use ExUnit.Case, async: true

  alias Atanor.Test.{JSONSchema, Manifests}
  alias AtanorTestkit.Node

  @operator "operator-secret"
  @spec_path "docs/openapi/admin.json"
  @document @spec_path |> File.read!() |> Jason.decode!()
  # The endpoints the document describes: the first segment, and for workers the last one.
  @family ~w(heads tokens audit drain auth)
  @worker_endpoints ~w(packages activate rollback versions status)

  defp operations do
    for {template, item} <- @document["paths"],
        {method, op} <- item,
        do: {String.upcase(method), template, op}
  end

  # Method and path of the routes the admin plug dispatches, with segments that vary as `{}`.
  defp routes do
    source = File.read!("lib/atanor/admin.ex")

    gets = for [_, path] <- Regex.scan(~r/defp get\(conn, (\[[^\]]*\])/, source), do: {"GET", path}

    others =
      for [_, method, path] <- Regex.scan(~r/defp route\(%\{method: "(\w+)", path_info: (\[[^\]]*\])/, source),
          do: {method, path}

    for {method, path} <- gets ++ others,
        segments = path |> String.slice(1..-2//1) |> String.split(", ", trim: true),
        in_family?(segments) do
      {method,
       "/" <> Enum.map_join(segments, "/", &if(String.starts_with?(&1, "\""), do: String.trim(&1, "\""), else: "{}"))}
    end
  end

  defp in_family?(["\"workers\"", _worker, last]), do: String.trim(last, "\"") in @worker_endpoints
  defp in_family?([first | _]), do: String.trim(first, "\"") in @family

  defp normalize(template), do: Regex.replace(~r/\{[^}]*\}/, template, "{}")

  test "the document is OpenAPI 3.1 with a security scheme and resolvable references" do
    assert @document["openapi"] =~ ~r/\A3\.1\./
    assert @document["components"]["securitySchemes"]["bearer"]["scheme"] == "bearer"

    refs = Regex.scan(~r/"\$ref": "#\/([^"]+)"/, File.read!(@spec_path), capture: :all_but_first)

    for [path] <- refs do
      assert get_in(@document, String.split(path, "/")), "unresolved $ref ##{path}"
    end

    for {method, template, op} <- operations() do
      assert op["operationId"], "#{method} #{template} has no operationId"
      assert op["responses"]["401"], "#{method} #{template} lacks 401"

      assert Enum.all?(Regex.scan(~r/\{(\w+)\}/, template, capture: :all_but_first), fn [name] ->
               Enum.any?(op["parameters"] || [], &(&1["name"] == name and &1["in"] == "path"))
             end)
    end
  end

  test "every route of the admin plug in these families is in the document, and the other way round" do
    from_code = routes() |> Enum.sort()
    from_spec = operations() |> Enum.map(fn {method, template, _} -> {method, normalize(template)} end) |> Enum.sort()

    assert from_code == from_spec
    assert length(from_code) == 14
  end

  test "every example validates against its schema" do
    schemas = @document["components"]["schemas"]

    for {name, schema} <- schemas, example <- schema["examples"] || [] do
      assert :ok == JSONSchema.validate(@document, %{"$ref" => "#/components/schemas/#{name}"}, example), name
    end

    responses =
      Map.values(@document["components"]["responses"]) ++
        for {_, _, op} <- operations(), {_, response} <- op["responses"], is_map_key(response, "content"), do: response

    for %{"content" => %{"application/json" => %{"schema" => schema, "example" => example}}} <- responses do
      assert :ok == JSONSchema.validate(@document, schema, example), inspect(example)
    end
  end

  describe "live answers match the document" do
    setup do
      node = Node.start(admin: [token: @operator, port: 0], stop: [exit: false])
      on_exit(fn -> Node.stop(node) end)
      {:ok, node: node, seen: :ets.new(:seen, [:public, :bag])}
    end

    defp call(node, seen, {method, template}, params, opts) do
      path = Enum.reduce(params, template, fn {k, v}, acc -> String.replace(acc, "{#{k}}", v) end)
      token = Keyword.get(opts, :token, @operator)
      headers = (token && [{"authorization", "Bearer " <> token}]) || []

      response =
        Req.request!(
          method: String.downcase(method) |> String.to_atom(),
          url: "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path <> Keyword.get(opts, :query, ""),
          headers: headers ++ Keyword.get(opts, :headers, []),
          body: opts[:body],
          retry: false,
          decode_body: false
        )

      op = @document["paths"][template][String.downcase(method)]
      declared = op["responses"][Integer.to_string(response.status)]

      assert declared,
             "#{method} #{template} answered #{response.status}, which the document does not declare: #{response.body}"

      declared = Map.get(declared, "$ref") |> resolve(declared)

      schema = declared["content"]["application/json"]["schema"]
      assert schema, "#{method} #{template} #{response.status} has no JSON schema"
      body = Jason.decode!(response.body)

      assert :ok == JSONSchema.validate(@document, schema, body),
             "#{method} #{template} #{response.status}: #{response.body}"

      :ets.insert(seen, {{method, template}, response.status})
      {response.status, body}
    end

    defp resolve(nil, declared), do: declared
    defp resolve("#/" <> path, _), do: get_in(@document, String.split(path, "/"))

    defp json_body(map), do: [body: Jason.encode!(map)]

    test "a session through every operation", %{node: node, seen: seen} do
      c = &call(node, seen, &1, &2, &3)
      pkg = fn n -> Manifests.package(Manifests.probe("w", limits: %{"timeout_ms" => n})) end

      upload = fn p, opts ->
        [body: p.bytes, headers: [{"x-package-sha256", opts[:hash] || p.id}], query: opts[:query] || ""] ++
          Keyword.take(opts, [:token])
      end

      p1 = pkg.(1)
      p2 = pkg.(2)

      assert {201, %{"token" => secret, "id" => id}} =
               c.(
                 {"POST", "/tokens"},
                 [],
                 json_body(%{name: "ci", scopes: ["worker:w:deploy", "worker:w:activate", "worker:w:read"]})
               )

      assert {400, _} = c.({"POST", "/tokens"}, [], json_body(%{name: "ci", scopes: ["bogus"]}))
      assert {200, _} = c.({"GET", "/tokens"}, [], [])
      assert {200, _} = c.({"GET", "/tokens/{id}"}, [id: id], [])
      assert {404, _} = c.({"GET", "/tokens/{id}"}, [id: "atn_" <> String.duplicate("0", 24)], [])

      upload_op = {"POST", "/workers/{worker}/packages"}
      assert {201, %{"head" => nil}} = c.(upload_op, [worker: "w"], upload.(p1, token: secret))

      assert {201, %{"head" => %{"revision" => 1}}} =
               c.(upload_op, [worker: "w"], upload.(p2, token: secret, query: "?activate=true"))

      assert {422, %{"error" => "hash_mismatch"}} =
               c.(upload_op, [worker: "w"], upload.(p1, token: secret, hash: String.duplicate("0", 64)))

      assert {422, %{"error" => "package_of_other_worker"}} = c.(upload_op, [worker: "other"], upload.(p1, []))
      assert {400, _} = c.(upload_op, [worker: "w"], upload.(p1, hash: "abc"))

      assert {403, %{"required" => "worker:w:rollback"}} =
               c.({"POST", "/workers/{worker}/rollback"}, [worker: "w"], token: secret)

      junk = "not a package"
      sha = :sha256 |> :crypto.hash(junk) |> Base.encode16(case: :lower)

      assert {422, %{"error" => "invalid_package"}} =
               c.(upload_op, [worker: "w"], body: junk, headers: [{"x-package-sha256", sha}])

      activate = {"POST", "/workers/{worker}/activate"}

      assert {200, %{"active" => active}} =
               c.(activate, [worker: "w"], [token: secret] ++ json_body(%{package_id: p1.id}))

      assert active == p1.id
      assert {404, _} = c.(activate, [worker: "w"], json_body(%{package_id: String.duplicate("a", 64)}))
      assert {400, _} = c.(activate, [worker: "w"], json_body(%{package_id: "x"}))

      rollback = {"POST", "/workers/{worker}/rollback"}
      assert {200, _} = c.(rollback, [worker: "w"], [])
      assert {409, %{"error" => "no_previous"}} = c.(rollback, [worker: "w"], [])

      versions = {"GET", "/workers/{worker}/versions"}
      assert {200, %{"versions" => [_, _]}} = c.(versions, [worker: "w"], token: secret)
      assert {200, %{"next" => next}} = c.(versions, [worker: "w"], query: "?limit=1")
      assert is_binary(next)
      assert {400, _} = c.(versions, [worker: "w"], query: "?limit=0")
      assert {404, _} = c.(versions, [worker: "nope"], [])

      status = {"GET", "/workers/{worker}/status"}
      assert {200, %{"node" => _}} = c.(status, [worker: "w"], token: secret)
      assert {404, _} = c.(status, [worker: "nope"], [])

      assert {200, %{"workers" => [_]}} = c.({"GET", "/heads"}, [], token: secret)
      assert {401, _} = c.({"GET", "/heads"}, [], token: nil)
      assert {403, _} = c.({"GET", "/tokens"}, [], token: secret)

      flush = {"POST", "/auth/keys/flush"}
      assert {401, _} = c.(flush, [], token: nil)
      assert {403, _} = c.(flush, [], token: secret)
      assert {200, %{"flushed" => 0}} = c.(flush, [], [])

      assert {200, %{"revoked_at" => revoked}} = c.({"POST", "/tokens/{id}/revoke"}, [id: id], [])
      assert is_binary(revoked)
      assert {404, _} = c.({"POST", "/tokens/{id}/revoke"}, [id: "atn_" <> String.duplicate("0", 24)], [])

      assert {200, %{"entries" => [_ | _]}} = c.({"GET", "/audit"}, [], query: "?limit=3")
      assert {400, _} = c.({"GET", "/audit"}, [], query: "?limit=0")
      assert {200, _} = c.({"GET", "/tokens"}, [], query: "?limit=1")

      assert {200, %{"state" => "idle"}} = c.({"GET", "/drain"}, [], [])
      assert {401, _} = c.({"POST", "/drain"}, [], token: nil)
      assert {200, %{"state" => "drained", "errors" => []}} = c.({"POST", "/drain"}, [], [])

      covered = seen |> :ets.tab2list() |> Enum.map(fn {{m, t}, _} -> {m, t} end) |> Enum.uniq() |> Enum.sort()
      assert covered == operations() |> Enum.map(fn {m, t, _} -> {m, t} end) |> Enum.sort()
    end

    test "a package over the limit is the documented 413" do
      node = Node.start(admin: [token: @operator, port: 0, max_package_bytes: 100])
      on_exit(fn -> Node.stop(node) end)
      seen = :ets.new(:seen, [:public, :bag])
      p = Manifests.package(Manifests.probe("w"))

      assert {413, %{"max_bytes" => 100}} =
               call(node, seen, {"POST", "/workers/{worker}/packages"}, [worker: "w"],
                 body: p.bytes,
                 headers: [{"x-package-sha256", p.id}]
               )
    end
  end
end
