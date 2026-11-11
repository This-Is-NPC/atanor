defmodule Atanor.Auth.Keys do
  @moduledoc """
  The signing keys of the issuers that routes trust (design §7.5): the OIDC
  discovery document and the JWKS, fetched through one process per instance
  and cached in an ETS table that requests read without a process hop.

  Fetches are serialized here, so concurrent requests cannot stampede the
  provider: a request that waits finds the keys cached by the one before it.
  An unknown `kid` refreshes the JWKS at most once per `min_refresh_ms`, and
  that holds for a failed fetch too (`error_backoff_ms`). Keys older than
  `jwks_max_age_ms` are refreshed by the next request; when the refresh fails
  the old keys keep serving, for at most `jwks_max_stale_ms` more.

  `flush/1` drops every cached key and discovery document of this node, so a
  key that a provider withdrew stops verifying at once and the next request
  fetches again, without waiting for `min_refresh_ms` or `error_backoff_ms`.

  A response is read while it arrives, so one over `max_response_bytes` ends the
  fetch without being buffered (`Atanor.Egress.send_request/3`).
  """
  use GenServer

  alias Atanor.{Config, Egress, Request}

  @doc false
  def child_spec(%Config{} = config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config, []]}}
  end

  @doc "Options: `:clock`, a function returning milliseconds (tests)."
  def start_link(%Config{} = config, opts \\ []),
    do: GenServer.start_link(__MODULE__, {config, opts}, name: server(config.name))

  def server(name), do: Module.concat(name, AuthKeys)

  @doc """
  The JWKS keys for a token with `kid` (or `nil`) from `issuer`. A `kid` that
  is not cached refreshes the keys when the minimum interval allows it.
  `{:error, :unavailable}` means no keys could be obtained at all.
  """
  @spec fetch(atom, String.t(), String.t() | nil) :: {:ok, [map]} | {:error, :unavailable}
  def fetch(name, issuer, kid) do
    table = server(name)

    case :ets.lookup(table, issuer) do
      [{_, keys, expires_at}] ->
        [{:clock, clock}] = :ets.lookup(table, :clock)
        if clock.() < expires_at and known?(keys, kid), do: {:ok, keys}, else: refresh(name, issuer, kid)

      [] ->
        refresh(name, issuer, kid)
    end
  end

  @doc """
  Drops everything cached for every issuer on this node and answers how many
  issuers were held. `0` when the instance has no OIDC rule, so no process.
  """
  @spec flush(atom) :: non_neg_integer
  def flush(name) do
    GenServer.call(server(name), :flush)
  catch
    :exit, _ -> 0
  end

  defp known?(keys, nil), do: keys != []
  defp known?(keys, kid), do: Enum.any?(keys, &(&1["kid"] == kid))

  defp refresh(name, issuer, kid) do
    [{:settings, settings}] = :ets.lookup(server(name), :settings)
    timeout = settings.connect_timeout_ms + 2 * settings.receive_timeout_ms + 1_000
    GenServer.call(server(name), {:keys, issuer, kid}, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init({config, opts}) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    :ets.new(server(config.name), [:named_table, :public, read_concurrency: true])
    :ets.insert(server(config.name), [{:clock, clock}, {:settings, config.oidc}])
    {:ok, %{name: config.name, settings: config.oidc, clock: clock, issuers: %{}}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    for issuer <- Map.keys(state.issuers), do: :ets.delete(server(state.name), issuer)
    {:reply, map_size(state.issuers), %{state | issuers: %{}}}
  end

  def handle_call({:keys, issuer, kid}, _from, state) do
    now = state.clock.()
    entry = Map.get(state.issuers, issuer)

    if due?(entry, kid, now, state.settings) do
      {entry, result} = load(issuer, entry, now, state)
      {:reply, result, put_in(state.issuers[issuer], entry)}
    else
      {:reply, answer(entry, now, state.settings), state}
    end
  end

  # Whether a fetch is allowed and needed now.
  defp due?(nil, _kid, _now, _settings), do: true

  defp due?(entry, kid, now, settings) do
    interval = if entry.failed?, do: settings.error_backoff_ms, else: settings.min_refresh_ms
    since = now - entry.attempted_at

    cond do
      entry.keys == nil -> since >= settings.error_backoff_ms
      now >= entry.expires_at -> since >= settings.error_backoff_ms
      kid != nil and not known?(entry.keys, kid) -> since >= interval
      kid == nil and entry.keys == [] -> since >= interval
      true -> false
    end
  end

  defp answer(%{keys: keys, expires_at: expires_at}, now, settings)
       when is_list(keys) and now < expires_at + settings.jwks_max_stale_ms,
       do: {:ok, keys}

  defp answer(_entry, _now, _settings), do: {:error, :unavailable}

  defp load(issuer, entry, now, state) do
    entry = entry || %{keys: nil, jwks_uri: nil, discovered_at: nil, attempted_at: nil, expires_at: 0, failed?: false}
    entry = %{entry | attempted_at: now}

    with {:ok, entry} <- discover(issuer, entry, now, state),
         {:ok, keys} <- fetch_jwks(issuer, entry.jwks_uri, state.settings) do
      table = server(state.name)
      expires_at = now + state.settings.jwks_max_age_ms
      :ets.insert(table, {issuer, keys, expires_at})
      entry = %{entry | keys: keys, expires_at: expires_at, failed?: false}
      {entry, {:ok, keys}}
    else
      {:error, _} -> {%{entry | failed?: true}, answer(entry, now, state.settings)}
    end
  end

  defp discover(_issuer, %{jwks_uri: uri, discovered_at: at} = entry, now, state)
       when is_binary(uri) and now - at < state.settings.discovery_ttl_ms,
       do: {:ok, entry}

  defp discover(issuer, entry, now, state) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, %{"issuer" => ^issuer, "jwks_uri" => uri}} <- get_json(url, :discovery, issuer, state.settings),
         true <- same_origin?(uri, issuer) do
      {:ok, %{entry | jwks_uri: uri, discovered_at: now}}
    else
      # A known jwks_uri keeps serving when the discovery document cannot be refreshed.
      _ when is_binary(entry.jwks_uri) -> {:ok, entry}
      _ -> {:error, :discovery}
    end
  end

  defp fetch_jwks(issuer, uri, settings) do
    case get_json(uri, :jwks, issuer, settings) do
      {:ok, %{"keys" => keys}} when is_list(keys) ->
        {:ok, for(%{"kty" => kty} = key <- keys, is_binary(kty), kty != "oct", do: key)}

      _ ->
        {:error, :jwks}
    end
  end

  # The JWKS must come from the issuer's own origin and use a scheme the operator allowed.
  defp same_origin?(uri, issuer) do
    a = URI.parse(uri)
    b = URI.parse(issuer)
    a.scheme == b.scheme and a.host == b.host and a.port == b.port
  end

  defp get_json(url, kind, issuer, settings) do
    started = System.monotonic_time()
    result = request(url, settings)
    outcome = if match?({:ok, _}, result), do: :ok, else: :error
    meta = %{issuer: issuer, kind: kind, result: outcome, reason: with({:error, reason} <- result, do: reason)}
    :telemetry.execute([:atanor, :auth, :fetch], %{duration: System.monotonic_time() - started}, meta)
    result
  end

  defp request(url, settings) do
    uri = URI.parse(url)
    query = uri.query || ""

    limits = %{
      deadline: now() + settings.connect_timeout_ms + settings.receive_timeout_ms,
      max_bytes: settings.max_response_bytes
    }

    request = %Request{
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port,
      path: uri.path || "/",
      query: query,
      headers: [{"accept", "application/json"}]
    }

    with {:ok, %{status: 200, body: body}} <- Egress.send_request(request, uri.host, limits),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, :response_too_large} -> {:error, :too_large}
      {:error, _} -> {:error, :unreachable}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
