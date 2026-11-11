defmodule Atanor.AuthHTTPTest do
  use ExUnit.Case, async: true

  alias Atanor.Test.{Manifests, OIDCProvider, RawHTTP, WasmCase}
  alias AtanorTestkit.Node

  setup do
    provider = OIDCProvider.start()
    OIDCProvider.add_key(provider, "k1")
    other = OIDCProvider.start()
    OIDCProvider.add_key(other, "k1")

    auth = [
      [
        host: "127.0.0.1",
        path: "/secure",
        issuer: provider.issuer,
        audience: "api",
        scopes: ["read"],
        types: ["at+jwt"],
        realm: "atanor"
      ],
      [host: "127.0.0.1", path: "/echo", issuer: provider.issuer, audience: "api"],
      [host: "127.0.0.1", path: "/plug", issuer: provider.issuer, audience: "api"],
      [host: "secure.test", issuer: provider.issuer, audience: "api"]
    ]

    node =
      Node.start(
        auth: auth,
        oidc: [allow_http: true],
        workers: [
          Manifests.probe("secure", routes: [{"127.0.0.1", "/secure"}]),
          Manifests.probe("open", routes: [{"127.0.0.1", "/open"}]),
          Manifests.probe("plug", module: Atanor.Test.PlugWorker, routes: [{"127.0.0.1", "/plug"}]),
          Manifests.probe("sub", routes: [{"127.0.0.1", "/secure/public"}]),
          Manifests.probe("hosted", routes: [{"secure.test", "/"}]),
          Manifests.probe("catchall", routes: [{"*", "/"}])
        ]
      )

    WasmCase.deploy(node, [{"echo", "echo", []}])

    on_exit(fn ->
      Node.stop(node)
      OIDCProvider.stop(provider)
      OIDCProvider.stop(other)
    end)

    %{node: node, provider: provider, other: other}
  end

  defp get(node, path, token \\ nil, headers \\ []) do
    headers = if token, do: [{"authorization", "Bearer " <> token} | headers], else: headers
    Req.get!(node.url <> path, retry: false, headers: headers)
  end

  # The last base64 character of a 2048-bit signature has unused bits, so change the first one.
  defp flip_signature(token) do
    [header, payload, <<first, rest::binary>>] = String.split(token, ".")
    Enum.join([header, payload, <<if(first == ?A, do: ?B, else: ?A), rest::binary>>], ".")
  end

  test "the admin API flushes the key cache, so a withdrawn key stops verifying", %{provider: p} do
    operator = "operator-secret"
    rule = [host: "127.0.0.1", path: "/secure", issuer: p.issuer, audience: "api"]

    node =
      Node.start(
        auth: [rule],
        oidc: [allow_http: true],
        admin: [token: operator, port: 0],
        workers: [Manifests.probe("secure", routes: [{"127.0.0.1", "/secure"}])]
      )

    on_exit(fn -> Node.stop(node) end)
    token = OIDCProvider.token(p, "k1")
    flush = "http://127.0.0.1:#{Atanor.admin_port(node.name)}/auth/keys/flush"

    assert get(node, "/secure", token).status == 200
    OIDCProvider.remove_key(p, "k1")
    OIDCProvider.add_key(p, "k2")
    assert get(node, "/secure", token).status == 200, "cached until the age ends"

    assert Req.post!(flush, retry: false).status == 401
    assert %{status: 200, body: %{"flushed" => 1}} = Req.post!(flush, retry: false, auth: {:bearer, operator})
    assert get(node, "/secure", token).status == 401
    assert get(node, "/secure", OIDCProvider.token(p, "k2")).status == 200
  end

  defp challenge(resp), do: resp.headers["www-authenticate"]

  test "a valid token reaches the worker with its claims", %{node: node, provider: p} do
    extra = %{"org_ids" => ["o1"], "act" => %{"sub" => "agent"}}
    resp = get(node, "/secure/claims", OIDCProvider.token(p, "k1", extra))

    assert resp.status == 200

    assert %{"claims" => %{"sub" => "u1", "org_ids" => ["o1"], "act" => %{"sub" => "agent"}, "scope" => "read write"}} =
             resp.body
  end

  test "a WASM worker reads the claims from the x-atanor-claims header", %{node: node, provider: p} do
    resp = get(node, "/echo/x", OIDCProvider.token(p, "k1", %{"org_ids" => ["o1"]}), [{"x-name", "x-atanor-claims"}])
    assert resp.status == 200
    assert {:ok, %{"org_ids" => ["o1"], "iss" => iss}} = Atanor.Auth.decode_claims(resp.body)
    assert iss == p.issuer
  end

  test "no token is a 401 with a bare Bearer challenge and the worker is not called", %{node: node} do
    for path <- ["/secure/claims", "/plug/x"] do
      resp = get(node, path)
      assert resp.status == 401
      assert resp.body == %{"error" => "unauthorized"}
    end

    assert challenge(get(node, "/secure/claims")) == ["Bearer realm=\"atanor\""]
    assert challenge(get(node, "/echo/x")) == ["Bearer"]
  end

  test "other schemes count as no credentials", %{node: node} do
    resp = get(node, "/secure/claims", nil, [{"authorization", "Basic dXNlcjpwYXNz"}])
    assert resp.status == 401
    assert challenge(resp) == ["Bearer realm=\"atanor\""]
  end

  test "malformed credentials are invalid_request", %{node: node, provider: p} do
    token = OIDCProvider.token(p, "k1")

    for headers <- [
          [{"authorization", "Bearer"}],
          [{"authorization", "Bearer a b"}],
          [{"authorization", "Bearer =="}],
          [{"authorization", "Bearer a=b"}],
          [{"authorization", "Bearer a%b"}],
          [{"authorization", "Bearer " <> token}, {"authorization", "Bearer " <> token}]
        ] do
      resp = get(node, "/secure/claims", nil, headers)
      assert resp.status == 400, inspect(headers)
      assert resp.body == %{"error" => "invalid_request"}
      assert challenge(resp) == ["Bearer realm=\"atanor\", error=\"invalid_request\""]
    end
  end

  test "invalid tokens are 401 invalid_token and leak nothing", %{node: node, provider: p, other: other} do
    past = System.system_time(:second) - 1000

    for token <- [
          "garbage",
          OIDCProvider.token(p, "k1", %{"exp" => past}),
          OIDCProvider.token(p, "k1", %{"aud" => "someone-else"}),
          OIDCProvider.token(p, "k1", %{"iss" => "https://elsewhere.test"}),
          OIDCProvider.token(p, "k1", %{}, %{"typ" => "JWT"}),
          OIDCProvider.token(other, "k1"),
          flip_signature(OIDCProvider.token(p, "k1"))
        ] do
      resp = get(node, "/secure/claims", token)
      assert resp.status == 401
      assert resp.body == %{"error" => "invalid_token"}
      assert challenge(resp) == ["Bearer realm=\"atanor\", error=\"invalid_token\""]
      refute inspect(resp) =~ token
    end
  end

  test "a missing scope is 403 insufficient_scope", %{node: node, provider: p} do
    resp = get(node, "/secure/claims", OIDCProvider.token(p, "k1", %{"scope" => "write"}))
    assert resp.status == 403
    assert resp.body == %{"error" => "insufficient_scope"}
    assert challenge(resp) == ["Bearer realm=\"atanor\", error=\"insufficient_scope\", scope=\"read\""]
  end

  test "a route without a rule behaves as before and never sees a client's claims header", %{node: node} do
    forged = Atanor.Auth.encode_claims(%{"sub" => "admin"})
    resp = get(node, "/open/claims", nil, [{"x-atanor-claims", forged}])
    assert resp.status == 200
    assert resp.body == %{"claims" => nil}

    resp = get(node, "/open/x", "not even a token")
    assert resp.status == 200
  end

  test "a client's own claims header never survives on a protected route", %{node: node, provider: p} do
    forged = Atanor.Auth.encode_claims(%{"sub" => "admin"})
    resp = get(node, "/secure/claims", OIDCProvider.token(p, "k1"), [{"x-atanor-claims", forged}])
    assert resp.body["claims"]["sub"] == "u1"
  end

  describe "the claims header" do
    @forged Atanor.Auth.encode_claims(%{"sub" => "admin"})

    test "no copy of a client's claims header reaches a route without a rule", %{node: node} do
      for copies <- 1..3 do
        headers = List.duplicate({"x-atanor-claims", @forged}, copies)
        {200, _, body} = RawHTTP.get(node.port, "/open/claims", "127.0.0.1", headers)
        assert Jason.decode!(body) == %{"claims" => nil}, "#{copies} copies"

        {200, _, body} = RawHTTP.get(node.port, "/open/headers", "127.0.0.1", headers)
        refute Map.has_key?(Jason.decode!(body)["headers"], "x-atanor-claims"), "#{copies} copies"
      end
    end

    test "only Atanor's claims reach a protected route, whatever the readers do with duplicates", %{
      node: node,
      provider: p
    } do
      headers = [
        {"authorization", "Bearer " <> OIDCProvider.token(p, "k1")} | List.duplicate({"x-atanor-claims", @forged}, 3)
      ]

      # The echo keeps the last value of a repeated header; the first is what `Request.claims/1` reads.
      {200, _, body} = RawHTTP.get(node.port, "/secure/headers", "127.0.0.1", headers)
      assert {:ok, %{"sub" => "u1"}} = Atanor.Auth.decode_claims(Jason.decode!(body)["headers"]["x-atanor-claims"])

      # A Plug worker reads every value.
      {200, _, body} = RawHTTP.get(node.port, "/plug/x", "127.0.0.1", headers)
      assert [value] = Jason.decode!(body)["claims"]
      assert {:ok, %{"sub" => "u1"}} = Atanor.Auth.decode_claims(value)
    end
  end

  describe "routes and rules see the canonical request" do
    test "an encoded unreserved character cannot skip a protected route", %{node: node} do
      for path <- ["/secure/claims", "/%73ecure/claims", "/%73%65%63%75%72%65/claims"] do
        {status, _, _} = RawHTTP.get(node.port, path, "127.0.0.1")
        assert status == 401, path
      end
    end

    test "dot segments, encoded slashes and bad escapes are refused", %{node: node} do
      for path <- [
            "/secure/../open/claims",
            "/open/./claims",
            "/open/%2e%2E/secure",
            "/secure%2Fclaims",
            "/open/%zz",
            "/open/%00"
          ] do
        {status, _, _} = RawHTTP.get(node.port, path, "127.0.0.1")
        assert status == 400, path
      end
    end

    test "the host is compared in lower case and without the trailing dot", %{node: node} do
      for host <- ["secure.test", "Secure.TEST", "secure.test.", "SECURE.test:80"] do
        {status, _, _} = RawHTTP.get(node.port, "/x", host)
        assert status == 401, host
      end
    end

    test "workers see the canonical path and host", %{node: node} do
      {200, _, body} = RawHTTP.get(node.port, "/open/%7Euser/%41/a%20b", "127.0.0.1")
      assert %{"path" => "/open/~user/A/a%20b"} = Jason.decode!(body)
      {200, _, body} = RawHTTP.get(node.port, "/x", "Catch.All.")
      assert %{"host" => "catch.all", "worker" => "catchall"} = Jason.decode!(body)
    end

    test "a rule covers the routes below the one it names", %{node: node} do
      {status, _, _} = RawHTTP.get(node.port, "/secure/public/claims", "127.0.0.1")
      assert status == 401
    end
  end

  test "the provider being down is a 503 with Retry-After, not a 401", %{node: node, provider: p} do
    token = OIDCProvider.token(p, "k1")
    OIDCProvider.fail(p, true)
    resp = get(node, "/secure/claims", token)
    assert resp.status == 503
    assert resp.body == %{"error" => "auth_unavailable"}
    assert resp.headers["retry-after"] == ["1"]
  end

  test "rejections emit telemetry without the token", %{node: node, provider: p} do
    WasmCase.capture([[:atanor, :auth, :reject]])
    get(node, "/secure/claims", OIDCProvider.token(p, "k1", %{"scope" => ""}))
    get(node, "/secure/claims")

    assert_receive {:telemetry, _, %{count: 1}, %{reason: :insufficient_scope, status: 403, worker: "secure"}}
    assert_receive {:telemetry, _, %{count: 1}, %{reason: :missing, status: 401, worker: "secure"}}
  end

  test "an invalid :auth option raises, a valid one builds" do
    base = [data_dir: "/tmp/x", store: {Mod, nil}]
    good = [host: "a.test", issuer: "https://a.test", audience: "x"]

    config = Atanor.Config.build(base ++ [auth: [good, [host: "*.b.test", path: "/p"] ++ Keyword.drop(good, [:host])]])

    assert %{{"a.test", "/"} => %{algorithms: ["RS256"], leeway_s: 60, scopes: [], types: nil, audience: ["x"]}} =
             config.auth

    assert is_map_key(config.auth, {"*.b.test", "/p"})
    assert Atanor.Config.build(base).auth == %{}

    for {auth, oidc} <- [
          {[[host: "a.test", issuer: "http://a.test", audience: "x"]], []},
          {[[host: "a.test", issuer: "https://a.test"]], []},
          {[[host: "a.test", issuer: "https://a.test", audience: "x", algorithms: ["HS256"]]], []},
          {[[host: "a.test", issuer: "https://a.test", audience: "x", algorithms: ["none"]]], []},
          {[[host: "a.test", issuer: "https://a.test", audience: "x", leeway_s: -1]], []},
          {[[host: "a.test", issuer: "https://a.test", audience: "x", color: 1]], []},
          {[
             [host: "a.test", issuer: "https://a.test", audience: "x"],
             [host: "a.test", issuer: "https://a.test", audience: "y"]
           ], []},
          {[], [min_refresh_ms: 0]},
          {[], [error_backoff_ms: 100_000]}
        ] do
      assert_raise ArgumentError, fn ->
        Atanor.Config.build(base ++ [auth: auth, oidc: oidc])
      end
    end
  end
end
