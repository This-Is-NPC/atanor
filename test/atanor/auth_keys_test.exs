defmodule Atanor.AuthKeysTest do
  use ExUnit.Case, async: true

  alias Atanor.Auth.Keys
  alias Atanor.Test.OIDCProvider

  @settings %{
    min_refresh_ms: 60_000,
    error_backoff_ms: 5_000,
    jwks_max_age_ms: 3_600_000,
    jwks_max_stale_ms: 86_400_000,
    discovery_ttl_ms: 3_600_000,
    # Only failure bounds: the tests wait for the fetch, and a loaded VM needs more than a second for a local one.
    connect_timeout_ms: 5_000,
    receive_timeout_ms: 10_000,
    max_response_bytes: 100_000,
    allow_http: true
  }

  setup do
    provider = OIDCProvider.start()
    on_exit(fn -> OIDCProvider.stop(provider) end)
    OIDCProvider.add_key(provider, "k1")
    %{provider: provider}
  end

  # A keys process on a clock the test moves.
  defp start_keys(settings \\ %{}) do
    name = Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    config = struct(Atanor.Config, name: name, oidc: Map.merge(@settings, settings))
    start_supervised!(%{id: name, start: {Keys, :start_link, [config, [clock: fn -> Agent.get(clock, & &1) end]]}})
    {name, fn ms -> Agent.update(clock, &(&1 + ms)) end}
  end

  # Discovery, and a JWKS that streams 100 MB; `Agent` counts the bytes the server managed to send.
  defmodule Stream do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    @chunk String.duplicate("x", 65_536)

    def init(agent), do: agent

    def call(%{request_path: "/.well-known/openid-configuration"} = conn, _agent) do
      issuer = "http://127.0.0.1:#{conn.port}"
      send_resp(conn, 200, Jason.encode!(%{issuer: issuer, jwks_uri: issuer <> "/jwks"}))
    end

    def call(conn, agent) do
      conn = send_chunked(conn, 200)

      Enum.reduce_while(1..1_600, conn, fn _, conn ->
        case chunk(conn, @chunk) do
          {:ok, conn} ->
            Agent.update(agent, &(&1 + byte_size(@chunk)))
            {:cont, conn}

          {:error, _} ->
            {:halt, conn}
        end
      end)
    end
  end

  defp kids(keys), do: keys |> Enum.map(& &1["kid"]) |> Enum.sort()

  test "a JWKS over max_response_bytes is cut off while it is read" do
    {:ok, sent} = Agent.start_link(fn -> 0 end)
    {:ok, server} = Bandit.start_link(plug: {Stream, sent}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)
    on_exit(fn -> Process.exit(server, :shutdown) end)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {name, _advance} = start_keys()
    assert {:error, :unavailable} = Keys.fetch(name, "http://127.0.0.1:#{port}", "k1")

    # The cap is 100 KB; socket buffers account for the rest.
    assert Agent.get(sent, & &1) < 50_000_000
  end

  test "the first request fetches discovery and the JWKS, the next ones read the cache", %{provider: p} do
    {name, _advance} = start_keys()

    for _ <- 1..5 do
      assert {:ok, keys} = Keys.fetch(name, p.issuer, "k1")
      assert kids(keys) == ["k1"]
    end

    assert OIDCProvider.hits(p) == {1, 1}
  end

  test "flush forgets a withdrawn key, so the next request fetches again", %{provider: p} do
    {name, _advance} = start_keys()
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    OIDCProvider.add_key(p, "k2")
    OIDCProvider.remove_key(p, "k1")

    assert {:ok, keys} = Keys.fetch(name, p.issuer, "k1")
    assert kids(keys) == ["k1"], "the withdrawn key still verifies from the cache"

    assert Keys.flush(name) == 1
    assert {:ok, keys} = Keys.fetch(name, p.issuer, "k2")
    assert kids(keys) == ["k2"]
    assert OIDCProvider.hits(p) == {2, 2}, "discovery and the JWKS were fetched again"
    assert Keys.flush(name) == 1
  end

  test "flush on an instance without an OIDC rule drops nothing" do
    assert Keys.flush(Module.concat(__MODULE__, "NoRules")) == 0
  end

  test "concurrent first requests fetch once", %{provider: p} do
    {name, _advance} = start_keys()

    results = 1..50 |> Task.async_stream(fn _ -> Keys.fetch(name, p.issuer, "k1") end) |> Enum.map(&elem(&1, 1))

    assert Enum.all?(results, &match?({:ok, [%{"kid" => "k1"}]}, &1))
    assert OIDCProvider.hits(p) == {1, 1}
  end

  test "an unknown kid refreshes at most once per interval", %{provider: p} do
    {name, advance} = start_keys()
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")

    advance.(1_000)

    for _ <- 1..20 do
      assert {:ok, keys} = Keys.fetch(name, p.issuer, "nope")
      assert kids(keys) == ["k1"]
    end

    assert OIDCProvider.hits(p) == {1, 1}, "within the interval of the first fetch: no refresh"

    advance.(59_000)
    results = 1..20 |> Task.async_stream(fn _ -> Keys.fetch(name, p.issuer, "nope") end) |> Enum.map(&elem(&1, 1))
    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert OIDCProvider.hits(p) == {1, 2}, "the interval passed: exactly one refresh, discovery stays cached"

    for _ <- 1..20, do: Keys.fetch(name, p.issuer, "nope")
    assert OIDCProvider.hits(p) == {1, 2}
  end

  test "rotation: a new kid is found after the interval, the old key stays while published", %{provider: p} do
    {name, advance} = start_keys()
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    OIDCProvider.add_key(p, "k2")

    advance.(10_000)
    assert {:ok, keys} = Keys.fetch(name, p.issuer, "k2")
    assert kids(keys) == ["k1"], "rate limited: the new key is not fetched yet"

    advance.(50_000)
    assert {:ok, keys} = Keys.fetch(name, p.issuer, "k2")
    assert kids(keys) == ["k1", "k2"]

    OIDCProvider.remove_key(p, "k1")
    advance.(60_000)
    assert {:ok, keys} = Keys.fetch(name, p.issuer, "k3")
    assert kids(keys) == ["k2"], "a retired key disappears at the next refresh"
  end

  test "keys older than the max age are refreshed by the next request", %{provider: p} do
    {name, advance} = start_keys(%{jwks_max_age_ms: 10_000})
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    advance.(9_999)
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    assert OIDCProvider.hits(p) == {1, 1}

    advance.(1)
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    assert OIDCProvider.hits(p) == {1, 2}
  end

  test "discovery is refreshed after its ttl", %{provider: p} do
    {name, advance} = start_keys(%{discovery_ttl_ms: 100_000, jwks_max_age_ms: 50_000})
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    advance.(60_000)
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    assert OIDCProvider.hits(p) == {1, 2}
    advance.(60_000)
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    assert OIDCProvider.hits(p) == {2, 3}
  end

  test "a provider that fails: unavailable, retried only after the backoff", %{provider: p} do
    OIDCProvider.fail(p, true)
    {name, advance} = start_keys()

    for _ <- 1..10, do: assert({:error, :unavailable} = Keys.fetch(name, p.issuer, "k1"))
    assert OIDCProvider.hits(p) == {1, 0}

    OIDCProvider.fail(p, false)
    advance.(5_000)
    assert {:ok, _} = Keys.fetch(name, p.issuer, "k1")
  end

  test "known keys keep serving when a refresh fails", %{provider: p} do
    {name, advance} = start_keys(%{jwks_max_age_ms: 10_000})
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    OIDCProvider.fail(p, true)
    advance.(10_000)

    for _ <- 1..5, do: assert({:ok, [%{"kid" => "k1"}]} = Keys.fetch(name, p.issuer, "k1"))
    assert OIDCProvider.hits(p) == {1, 2}, "one failed attempt, then the backoff"
  end

  test "keys that cannot be refreshed stop serving after jwks_max_stale_ms", %{provider: p} do
    {name, advance} = start_keys(%{jwks_max_age_ms: 10_000, jwks_max_stale_ms: 20_000})
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")
    OIDCProvider.fail(p, true)

    advance.(29_000)
    assert {:ok, [%{"kid" => "k1"}]} = Keys.fetch(name, p.issuer, "k1")
    advance.(2_000)
    assert {:error, :unavailable} = Keys.fetch(name, p.issuer, "k1")

    # The provider is back: the next fetch (after the backoff) serves its keys again.
    OIDCProvider.fail(p, false)
    advance.(5_000)
    assert {:ok, [%{"kid" => "k1"}]} = Keys.fetch(name, p.issuer, "k1")
  end

  test "a discovery document naming another issuer is refused", %{provider: p} do
    OIDCProvider.claim_issuer(p, "https://evil.example")
    {name, _} = start_keys()
    assert {:error, :unavailable} = Keys.fetch(name, p.issuer, "k1")
    assert OIDCProvider.hits(p) == {1, 0}
  end

  test "a JWKS outside the issuer's origin is refused", %{provider: p} do
    OIDCProvider.claim_jwks_uri(p, "http://127.0.0.1:1/jwks")
    {name, _} = start_keys()
    assert {:error, :unavailable} = Keys.fetch(name, p.issuer, "k1")
    assert OIDCProvider.hits(p) == {1, 0}
  end

  test "an unreachable provider is unavailable within the timeouts" do
    {name, _} = start_keys(%{connect_timeout_ms: 200})
    assert {:error, :unavailable} = Keys.fetch(name, "http://127.0.0.1:1", nil)
  end

  test "emits a telemetry event per fetch", %{provider: p} do
    Atanor.Test.WasmCase.capture([[:atanor, :auth, :fetch]])

    {name, _} = start_keys()
    {:ok, _} = Keys.fetch(name, p.issuer, "k1")

    assert_receive {:telemetry, _, %{duration: _}, %{kind: :discovery, result: :ok}}
    assert_receive {:telemetry, _, %{duration: _}, %{kind: :jwks, result: :ok}}
  end
end
