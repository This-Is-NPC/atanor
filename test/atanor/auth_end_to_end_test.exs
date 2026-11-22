defmodule Atanor.AuthEndToEndTest do
  # End to end: a node verifies tokens of the fake OIDC issuer in test/support and serves them to a worker.
  use ExUnit.Case, async: true

  alias Atanor.Test.{Manifests, OIDCProvider}
  alias AtanorTestkit.Node

  setup do
    provider = OIDCProvider.start()
    OIDCProvider.add_key(provider, "k1")

    node =
      Node.start(
        auth: [
          [
            host: "127.0.0.1",
            path: "/api",
            issuer: provider.issuer,
            audience: "api",
            scopes: ["openid"],
            types: ["at+jwt"]
          ]
        ],
        oidc: [allow_http: true, min_refresh_ms: 500, error_backoff_ms: 100],
        workers: [Manifests.probe("api", routes: [{"127.0.0.1", "/api"}])]
      )

    on_exit(fn ->
      Node.stop(node)
      OIDCProvider.stop(provider)
    end)

    %{provider: provider, node: node}
  end

  # An access token with the `openid` scope the rule requires, unless `claims` sets another scope.
  defp access_token(provider, claims \\ %{}) do
    OIDCProvider.token(provider, "k1", Map.put_new(claims, "scope", "openid read"))
  end

  # The keys process reads a clock the test moves, so the refresh interval does not depend on the load.
  defp manual_clock(node) do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    now = fn -> Agent.get(clock, & &1) end
    server = Atanor.Auth.Keys.server(node.name)
    :sys.replace_state(server, &%{&1 | clock: now})
    :ets.insert(server, {:clock, now})
    fn ms -> Agent.update(clock, &(&1 + ms)) end
  end

  defp get(node, token \\ nil) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []
    Req.get!(node.url <> "/api/claims", retry: false, headers: headers)
  end

  test "a minted token reaches the worker with its claims", %{provider: p, node: node} do
    token =
      OIDCProvider.token(p, "k1", %{"sub" => "person-1", "org_ids" => ["o1"], "scope" => "openid email organizations"})

    resp = get(node, token)

    assert resp.status == 200

    assert %{"claims" => %{"sub" => "person-1", "org_ids" => ["o1"], "scope" => "openid email organizations"}} =
             resp.body
  end

  test "a missing token is refused with a bare Bearer challenge", %{node: node} do
    resp = get(node)
    assert resp.status == 401
    assert resp.headers["www-authenticate"] == ["Bearer"]
  end

  test "a token with too few scopes is refused", %{provider: p, node: node} do
    resp = get(node, OIDCProvider.token(p, "k1", %{"scope" => "email"}))
    assert resp.status == 403
    assert resp.headers["www-authenticate"] == ["Bearer error=\"insufficient_scope\", scope=\"openid\""]
  end

  test "an ID token (typ JWT) is refused", %{provider: p, node: node} do
    assert get(node, OIDCProvider.token(p, "k1", %{"scope" => "openid"}, %{"typ" => "JWT"})).status == 401
  end

  test "a token for another audience is refused", %{provider: p, node: node} do
    assert get(node, access_token(p, %{"aud" => "https://other.test"})).status == 401
  end

  test "the JWKS is fetched once and then read from the cache", %{provider: p, node: node} do
    token = access_token(p)

    for _ <- 1..5, do: assert(get(node, token).status == 200)

    assert OIDCProvider.hits(p) == {1, 1}
  end

  test "a rotated signing key is fetched again once the refresh interval allows it", %{provider: p, node: node} do
    advance = manual_clock(node)
    assert get(node, access_token(p)).status == 200
    assert OIDCProvider.hits(p) == {1, 1}

    OIDCProvider.add_key(p, "k2")
    OIDCProvider.remove_key(p, "k1")
    token = OIDCProvider.token(p, "k2", %{"scope" => "openid read"})

    # Within the interval of the first load the unknown kid does not reach the provider.
    assert get(node, token).status == 401
    assert OIDCProvider.hits(p) == {1, 1}

    advance.(500)
    assert get(node, token).status == 200
    assert OIDCProvider.hits(p) == {1, 2}
  end
end
