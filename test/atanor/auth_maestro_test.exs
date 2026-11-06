# End to end against the Maestro testkit (a loopback OIDC provider). Compiled only when the testkit is a
# dependency: mix.exs adds it when its directory exists (README, "Requirements").
if Code.ensure_loaded?(MaestroTestkit) do
  defmodule Atanor.AuthMaestroTest do
    use ExUnit.Case, async: true

    alias Atanor.Test.Manifests
    alias AtanorTestkit.Node

    setup do
      kit = MaestroTestkit.start()
      resource = MaestroTestkit.resource(kit, "web-portal")

      node =
        Node.start(
          auth: [
            [
              host: "127.0.0.1",
              path: "/api",
              issuer: MaestroTestkit.issuer(kit),
              audience: resource,
              scopes: ["openid"],
              types: ["at+jwt"]
            ]
          ],
          oidc: [allow_http: true, min_refresh_ms: 500, error_backoff_ms: 100],
          workers: [Manifests.probe("api", routes: [{"127.0.0.1", "/api"}])]
        )

      on_exit(fn ->
        Node.stop(node)
        MaestroTestkit.stop(kit)
      end)

      %{kit: kit, node: node}
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

    test "a minted token reaches the worker, a missing or short one does not", %{kit: kit, node: node} do
      resp = get(node, MaestroTestkit.access_token(kit))
      assert resp.status == 200
      person = MaestroTestkit.person(kit)
      assert %{"claims" => %{"sub" => sub, "org_ids" => [_ | _], "scope" => "openid email organizations"}} = resp.body
      assert sub == person["id"]

      resp = get(node)
      assert resp.status == 401
      assert resp.headers["www-authenticate"] == ["Bearer"]

      resp = get(node, MaestroTestkit.access_token(kit, nil, scope: "email"))
      assert resp.status == 403
      assert resp.headers["www-authenticate"] == ["Bearer error=\"insufficient_scope\", scope=\"openid\""]
    end

    test "an ID token (typ JWT) and a token for another audience are refused", %{kit: kit, node: node} do
      assert get(node, MaestroTestkit.id_token(kit)).status == 401
      assert get(node, MaestroTestkit.access_token(kit, nil, aud: "https://other.test")).status == 401
    end

    test "a rotated signing key is accepted once the refresh interval allows it", %{kit: kit, node: node} do
      advance = manual_clock(node)
      assert get(node, MaestroTestkit.access_token(kit)).status == 200
      assert MaestroTestkit.jwks_requests(kit) == 1

      MaestroTestkit.rotate(kit)
      token = MaestroTestkit.access_token(kit)

      # Within the interval of the first load the unknown kid does not reach the provider.
      assert get(node, token).status == 401
      assert MaestroTestkit.jwks_requests(kit) == 1

      advance.(500)
      assert get(node, token).status == 200
      assert MaestroTestkit.jwks_requests(kit) == 2
    end
  end
end
