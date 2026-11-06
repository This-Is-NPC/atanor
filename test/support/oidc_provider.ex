defmodule Atanor.Test.OIDCProvider do
  @moduledoc """
  A minimal OIDC provider on loopback for the `:auth` tests: discovery and a
  JWKS that the test changes at will, with a count of the requests served.
  Also mints tokens.

      provider = OIDCProvider.start()
      OIDCProvider.add_key(provider, "k1")
      token = OIDCProvider.token(provider, "k1", %{"aud" => "api"})
  """
  @behaviour Plug

  import Plug.Conn

  defstruct [:agent, :server, :issuer]

  @doc "Starts the provider; `issuer:` overrides the issuer the discovery document names."
  def start(opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> %{keys: %{}, jwks_hits: 0, discovery_hits: 0, issuer: nil, fail: false} end)
    {:ok, server} = Bandit.start_link(plug: {__MODULE__, agent}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    issuer = Keyword.get(opts, :issuer, "http://127.0.0.1:#{port}")
    Agent.update(agent, &%{&1 | issuer: issuer})
    %__MODULE__{agent: agent, server: server, issuer: issuer}
  end

  def stop(%__MODULE__{agent: agent, server: server}) do
    Supervisor.stop(server)
    Agent.stop(agent)
  catch
    :exit, _ -> :ok
  end

  @doc "Publishes a new RSA key under `kid` and returns its private JWK."
  def add_key(%__MODULE__{agent: agent}, kid, jwk \\ nil) do
    jwk = jwk || JOSE.JWK.generate_key({:rsa, 2048})
    Agent.update(agent, &put_in(&1.keys[kid], jwk))
    jwk
  end

  def remove_key(%__MODULE__{agent: agent}, kid),
    do: Agent.update(agent, &update_in(&1.keys, fn k -> Map.delete(k, kid) end))

  @doc "Makes every request answer 500 (or stops doing so)."
  def fail(%__MODULE__{agent: agent}, fail?), do: Agent.update(agent, &%{&1 | fail: fail?})

  @doc "The issuer the discovery document claims, or (`claim_jwks_uri/2`) the JWKS location it gives."
  def claim_issuer(%__MODULE__{agent: agent}, issuer), do: Agent.update(agent, &Map.put(&1, :claimed_issuer, issuer))
  def claim_jwks_uri(%__MODULE__{agent: agent}, uri), do: Agent.update(agent, &Map.put(&1, :claimed_jwks_uri, uri))

  def hits(%__MODULE__{agent: agent}), do: Agent.get(agent, &{&1.discovery_hits, &1.jwks_hits})

  @doc "The public JWK map for `kid`."
  def public(jwk, kid) do
    {_, map} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Map.merge(map, %{"kid" => kid, "use" => "sig", "alg" => "RS256"})
  end

  @doc "A signed RS256 token with the standard claims unless `claims` replaces them."
  def token(%__MODULE__{} = provider, kid, claims \\ %{}, header \\ %{}) do
    jwk = Agent.get(provider.agent, & &1.keys[kid])
    sign(jwk, kid, Map.merge(valid_claims(provider.issuer), claims), header)
  end

  def valid_claims(issuer) do
    now = System.system_time(:second)
    %{"iss" => issuer, "aud" => "api", "sub" => "u1", "iat" => now, "exp" => now + 300, "scope" => "read write"}
  end

  def sign(jwk, kid, claims, header \\ %{}) do
    header = Map.merge(%{"alg" => "RS256", "typ" => "at+jwt", "kid" => kid}, header)
    {_, token} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    token
  end

  @impl true
  def init(agent), do: agent

  @impl true
  def call(conn, agent) do
    state = Agent.get_and_update(agent, fn s -> {s, count(s, conn.request_path)} end)

    cond do
      state.fail -> send_resp(conn, 500, "boom")
      conn.request_path == "/.well-known/openid-configuration" -> json(conn, discovery(state))
      conn.request_path == "/jwks" -> json(conn, %{"keys" => for({kid, jwk} <- state.keys, do: public(jwk, kid))})
      true -> send_resp(conn, 404, "")
    end
  end

  defp count(s, "/.well-known/openid-configuration"), do: %{s | discovery_hits: s.discovery_hits + 1}
  defp count(s, "/jwks"), do: %{s | jwks_hits: s.jwks_hits + 1}
  defp count(s, _), do: s

  defp discovery(state) do
    %{
      "issuer" => state[:claimed_issuer] || state.issuer,
      "jwks_uri" => state[:claimed_jwks_uri] || String.trim_trailing(state.issuer, "/") <> "/jwks"
    }
  end

  defp json(conn, body), do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
end
