defmodule Atanor.AdminScopePropertyTest do
  @moduledoc "A scoped token never acts outside its scope (design §10.2)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Admin.Tokens
  alias Atanor.{Package, Store}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @operator "operator-secret"
  @workers ["alpha", "beta"]
  @actions ~w(deploy activate rollback read)

  setup_all do
    node = Node.start(admin: [token: @operator, port: 0])
    on_exit(fn -> Node.stop(node) end)

    # Each worker has two versions deployed and a third one stored but inactive.
    spare =
      for w <- @workers, into: %{} do
        [p1, p2, p3] = for n <- 1..3, do: package(w, n)
        for p <- [p1, p2], do: {:ok, 201} = {:ok, upload(node, w, p, @operator).status}
        {:ok, 201} = {:ok, upload(node, w, p3, @operator).status}
        for p <- [p1, p2], do: {:ok, _} = Atanor.Deployments.activate(node.name, w, p.id)
        {w, p3.id}
      end

    %{node: node, spare: spare}
  end

  defp package(worker, n), do: Manifests.package(Manifests.probe(worker, limits: %{"timeout_ms" => n}))

  defp url(node, path), do: "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path

  defp upload(node, worker, %Package{} = package, token) do
    Req.post!(url(node, "/workers/#{worker}/packages"),
      body: package.bytes,
      headers: [{"authorization", "Bearer " <> token}, {"x-package-sha256", package.id}],
      retry: false,
      decode_body: false
    )
  end

  # Everything a request could change: heads and packages.
  defp snapshot(node) do
    for prefix <- ["workers/", "packages/"], {:ok, keys, _} <- [Store.list(node.name, prefix)], key <- keys do
      {key, Store.get(node.name, key)}
    end
  end

  defp send_request(node, spare, token, {worker, action}) do
    base = [headers: [{"authorization", "Bearer " <> token}], retry: false, decode_body: false]

    case action do
      "deploy" ->
        upload(node, worker, package(worker, :rand.uniform(1_000_000)), token)

      "activate" ->
        Req.post!(
          url(node, "/workers/#{worker}/activate"),
          [body: Jason.encode!(%{"package_id" => spare[worker]})] ++ base
        )

      "rollback" ->
        Req.post!(url(node, "/workers/#{worker}/rollback"), base)

      "read" ->
        Req.get!(url(node, "/workers/#{worker}/versions"), base)
    end
  end

  # The oracle compares strings, independently of Atanor.Admin.Scope.
  defp in_scope?(scopes, {worker, action}),
    do: Enum.any?(scopes, &(&1 in ["worker:#{worker}:#{action}", "worker:*:#{action}"]))

  defp scope_gen do
    one_of([
      constant("cluster:admin"),
      map({member_of(@workers ++ ["*", "gamma"]), member_of(@actions)}, fn {w, a} -> "worker:#{w}:#{a}" end)
    ])
  end

  defp request_gen, do: tuple({member_of(@workers), member_of(@actions)})

  defp create(node, scopes, attrs \\ %{}) do
    {:ok, record, secret} = Tokens.create(node.name, Map.merge(%{"name" => "p", "scopes" => scopes}, attrs), "operator")
    {record["id"], secret}
  end

  property "out-of-scope requests get 403 and change nothing; in-scope requests are allowed", %{
    node: node,
    spare: spare
  } do
    check all(
            scopes <- list_of(scope_gen(), min_length: 1, max_length: 6),
            requests <- list_of(request_gen(), max_length: 8)
          ) do
      {_id, token} = create(node, scopes)

      for request <- requests do
        before = snapshot(node)
        response = send_request(node, spare, token, request)

        if in_scope?(scopes, request) do
          refute response.status in [401, 403], "#{inspect(scopes)} #{inspect(request)} -> #{response.status}"
        else
          assert response.status == 403, "#{inspect(scopes)} #{inspect(request)} -> #{response.status}"
          assert snapshot(node) == before
        end
      end
    end
  end

  property "uploading with activate needs both scopes", %{node: node} do
    check all(scopes <- list_of(scope_gen(), min_length: 1, max_length: 6), worker <- member_of(@workers)) do
      {_id, token} = create(node, scopes)
      before = snapshot(node)
      pkg = package(worker, :rand.uniform(1_000_000))

      response =
        Req.post!(url(node, "/workers/#{worker}/packages?activate=true"),
          body: pkg.bytes,
          headers: [{"authorization", "Bearer " <> token}, {"x-package-sha256", pkg.id}],
          retry: false,
          decode_body: false
        )

      if in_scope?(scopes, {worker, "deploy"}) and in_scope?(scopes, {worker, "activate"}) do
        assert response.status == 201
      else
        assert response.status == 403
        assert snapshot(node) == before
      end
    end
  end

  property "malformed, unknown, revoked and expired tokens get 401 and change nothing", %{node: node, spare: spare} do
    garbage = string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-, ?., ?:, ?\s], min_length: 1, max_length: 100)
    hex = string([?0..?9, ?a..?f], length: 24)
    secret = string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-], length: 43)
    unknown = map({hex, secret}, fn {id, s} -> "atn_#{id}_#{s}" end)

    check all(
            kind <- member_of([:garbage, :unknown, :wrong_secret, :revoked, :expired]),
            bad <- one_of([garbage, unknown]),
            request <- request_gen()
          ) do
      token =
        case kind do
          :garbage ->
            bad

          :unknown ->
            if String.starts_with?(bad, "atn_") do
              bad
            else
              "atn_" <> String.duplicate("0", 24) <> "_" <> String.duplicate("A", 43)
            end

          :wrong_secret ->
            {id, _} = create(node, ["worker:*:read", "worker:*:deploy", "worker:*:activate", "worker:*:rollback"])
            id <> "_" <> String.duplicate("B", 43)

          :revoked ->
            {id, token} = create(node, ["worker:*:read", "worker:*:deploy", "worker:*:activate", "worker:*:rollback"])
            {:ok, _} = Tokens.revoke(node.name, id, "operator")
            token

          :expired ->
            {id, token} = create(node, ["worker:*:read", "worker:*:deploy", "worker:*:activate", "worker:*:rollback"])
            expire(node, id)
            token
        end

      refute token == @operator
      before = snapshot(node)
      response = send_request(node, spare, token, request)
      assert response.status == 401, "#{kind} #{token} #{inspect(request)} -> #{response.status}"
      assert snapshot(node) == before
      if byte_size(token) >= 20, do: refute(response.body =~ token)
    end
  end

  defp expire(node, id) do
    {:ok, raw, _, _} = Store.get(node.name, "tokens/" <> id)
    past = DateTime.utc_now() |> DateTime.add(-5) |> DateTime.to_iso8601()

    {:ok, _} =
      Store.put(node.name, "tokens/" <> id, raw |> Jason.decode!() |> Map.put("expires_at", past) |> Jason.encode!())
  end
end
