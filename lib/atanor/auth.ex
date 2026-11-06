defmodule Atanor.Auth do
  @moduledoc """
  Bearer-token validation per route at the ingress (design §7.5).

  The operator lists the protected routes in the `:auth` option of the
  instance; each entry names a host pattern and a path prefix (`host:` and
  `path:`, default `"/"`) and the trust anchors. A rule covers every request
  whose canonical host and path (`Atanor.Route`) it matches, whichever route
  serves it, so a more specific route declared under a protected one stays
  protected. When several rules match, the most specific one applies: hosts
  first (exact, then `*.` suffixes from the longest, then `*`), then the
  longest path prefix, as in route matching.

    * `:issuer` (required): `iss` must equal it exactly; its OIDC discovery
      document locates the JWKS.
    * `:audience` (required): a string, or a list of accepted values; `aud`
      must contain one.
    * `:scopes`: scopes the token must hold (`scope`, space-separated, or
      `scp`, an array or a string). Default none.
    * `:types`: accepted `typ` header values, for example `["at+jwt"]`;
      `application/` prefixes and case are ignored. Default: any.
    * `:algorithms`: default `["RS256"]`; from `Atanor.Auth.Token.algorithms/0`.
    * `:leeway_s`: clock leeway for `exp`, `nbf` and `iat`. Default 60.
    * `:realm`: the `WWW-Authenticate` realm. Default none.

  A request that fails never reaches the worker. One that passes carries its
  verified claims in the `x-atanor-claims` header (base64url JSON, see
  `Atanor.Request.claims/1`). Atanor applies no provider-specific rule.
  """

  alias Atanor.Auth.{Keys, Token}
  alias Atanor.Route

  @claims_header "x-atanor-claims"
  @allowed [:host, :path, :issuer, :audience, :scopes, :types, :algorithms, :leeway_s, :realm]

  @doc "The request header that carries the verified claims."
  def claims_header, do: @claims_header

  @doc false
  # The rules of the `:auth` option, by manifest route `{host, path}`.
  def rules!(nil, _oidc), do: %{}

  def rules!(entries, oidc) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, rules ->
      {key, rule} = rule!(entry, oidc)
      if is_map_key(rules, key), do: raise(ArgumentError, ":auth lists route #{inspect(key)} twice")
      Map.put(rules, key, rule)
    end)
  end

  def rules!(_entries, _oidc), do: raise(ArgumentError, ":auth must be a list of keyword lists")

  defp rule!(entry, oidc) do
    unless Keyword.keyword?(entry), do: raise(ArgumentError, ":auth entries must be keyword lists")

    case Keyword.keys(entry) -- @allowed do
      [] -> :ok
      unknown -> raise ArgumentError, ":auth: unknown keys #{inspect(unknown)}"
    end

    host = entry[:host]
    unless Atanor.Manifest.host_pattern?(host), do: raise(ArgumentError, ":auth :host must be a host pattern")
    path = Keyword.get(entry, :path, "/")
    unless is_binary(path) and String.starts_with?(path, "/"), do: raise(ArgumentError, ":auth :path must start with /")
    # As in a manifest route, a trailing slash is not part of the prefix.
    path = if String.trim_trailing(path, "/") == "", do: "/", else: String.trim_trailing(path, "/")

    issuer = entry[:issuer]
    check_issuer!(issuer, oidc)
    audience = entry[:audience] |> List.wrap()
    strings!(audience != [] and audience, ":auth :audience must be a string or a non-empty list of strings")
    scopes = Keyword.get(entry, :scopes, [])
    strings!(scopes, ":auth :scopes must be a list of strings")
    algorithms = Keyword.get(entry, :algorithms, ["RS256"])
    strings!(algorithms != [] and algorithms, ":auth :algorithms must be a non-empty list of strings")

    unless algorithms -- Token.algorithms() == [],
      do: raise(ArgumentError, ":auth :algorithms must be among #{inspect(Token.algorithms())}")

    types = Keyword.get(entry, :types)
    unless is_nil(types), do: strings!(types, ":auth :types must be a list of strings")
    leeway = Keyword.get(entry, :leeway_s, 60)

    unless is_integer(leeway) and leeway >= 0,
      do: raise(ArgumentError, ":auth :leeway_s must be a non-negative integer")

    realm = entry[:realm]

    unless is_nil(realm) or (is_binary(realm) and realm =~ ~r/\A[\x20\x21\x23-\x5B\x5D-\x7E]*\z/),
      do: raise(ArgumentError, ":auth :realm must be a printable string without quotes or backslashes")

    {{host, path},
     %{
       host: host,
       path: path,
       issuer: issuer,
       audience: audience,
       scopes: scopes,
       types: types && Enum.map(types, &Token.normalize_type/1),
       algorithms: algorithms,
       leeway_s: leeway,
       realm: realm
     }}
  end

  defp check_issuer!(issuer, oidc) do
    uri = is_binary(issuer) && URI.parse(issuer)

    valid? =
      (uri && uri.scheme in ["https", "http"]) and is_binary(uri.host) and is_nil(uri.query) and is_nil(uri.fragment) and
        (uri.scheme == "https" or oidc.allow_http)

    unless valid?,
      do: raise(ArgumentError, ":auth :issuer must be an https URL (http needs oidc: [allow_http: true])")
  end

  defp strings!(value, message) do
    unless is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 != "")), do: raise(ArgumentError, message)
  end

  @type outcome ::
          :open
          | {:ok, map}
          | {:reject, status :: 400..599, www_authenticate :: String.t() | nil, error :: String.t() | nil,
             reason :: term}

  @doc """
  Checks the request headers of a request for `host` and `path` (canonical, see
  `Atanor.Route`) against the most specific rule that covers them. `:open`
  is a request no rule covers; `{:ok, claims}` a verified token; a rejection
  names the status, the `WWW-Authenticate` value (`nil` for 503), the error
  code of the body and the reason, which only telemetry sees.
  """
  @spec check(atom, Atanor.Config.t(), String.t(), String.t(), [{String.t(), String.t()}], integer) :: outcome
  def check(name, config, host, path, headers, now \\ System.system_time(:second)) do
    case rule(config.auth, host, path) do
      nil -> :open
      rule -> authenticate(name, rule, headers, now)
    end
  end

  defp rule(rules, _host, _path) when map_size(rules) == 0, do: nil

  defp rule(rules, host, path) do
    prefixes = Route.path_prefixes(path)

    Enum.find_value(Route.host_candidates(host), fn candidate ->
      Enum.find_value(prefixes, &Map.get(rules, {candidate, &1}))
    end)
  end

  defp authenticate(name, rule, headers, now) do
    with {:ok, token} <- bearer(headers, rule),
         {:ok, header} <- token |> Token.header(rule) |> invalid(rule),
         {:ok, keys} <- name |> Keys.fetch(rule.issuer, header["kid"]) |> available(),
         {:ok, claims} <- token |> Token.verify(rule, keys, now) |> invalid(rule) do
      {:ok, claims}
    end
  end

  # RFC 6750 §3: no credentials, no error code; a malformed request is 400.
  defp bearer(headers, rule) do
    case for({"authorization", value} <- headers, do: value) do
      [] -> {:reject, 401, challenge(rule, nil), nil, :missing}
      [value] -> parse_bearer(value, rule)
      _ -> {:reject, 400, challenge(rule, "invalid_request"), "invalid_request", :bad_request}
    end
  end

  defp parse_bearer(value, rule) do
    {scheme, token} =
      case String.split(value, " ", parts: 2) do
        [scheme, token] -> {scheme, token}
        [scheme] -> {scheme, ""}
      end

    cond do
      String.downcase(scheme) != "bearer" -> {:reject, 401, challenge(rule, nil), nil, :missing}
      token68?(token) -> {:ok, token}
      true -> {:reject, 400, challenge(rule, "invalid_request"), "invalid_request", :bad_request}
    end
  end

  # RFC 6750 token68: one or more of A-Z a-z 0-9 - . _ ~ + /, then any number of `=`. A byte loop, as a regex
  # literal is imported again at each use on OTP 28.
  defguardp is_token_char(c) when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in ~c"-._~+/"

  defp token68?(<<c, rest::binary>>) when is_token_char(c), do: token68_tail(rest)
  defp token68?(_), do: false

  defp token68_tail(<<c, rest::binary>>) when is_token_char(c), do: token68_tail(rest)
  defp token68_tail(rest), do: String.trim_leading(rest, "=") == ""

  defp invalid({:ok, _} = ok, _rule), do: ok

  defp invalid({:error, {:insufficient_scope, _missing}}, rule),
    do: {:reject, 403, challenge(rule, "insufficient_scope", rule.scopes), "insufficient_scope", :insufficient_scope}

  defp invalid({:error, reason}, rule), do: {:reject, 401, challenge(rule, "invalid_token"), "invalid_token", reason}

  defp available({:ok, _} = ok), do: ok
  defp available({:error, :unavailable}), do: {:reject, 503, nil, "auth_unavailable", :keys_unavailable}

  defp challenge(rule, error, scopes \\ []) do
    params =
      [realm: rule.realm, error: error, scope: scopes != [] && Enum.join(scopes, " ")]
      |> Enum.filter(fn {_, v} -> v end)
      |> Enum.map_join(", ", fn {k, v} -> ~s(#{k}="#{v}") end)

    if params == "", do: "Bearer", else: "Bearer " <> params
  end

  @doc """
  The headers without any copy of the claims header. Atanor alone sets it:
  ingress drops what the client sent and `Atanor.Env.call/3` what the caller
  put in the request.
  """
  @spec strip_claims([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def strip_claims(headers), do: Enum.reject(headers, fn {name, _} -> String.downcase(name) == @claims_header end)

  @doc "Encodes verified claims for the `x-atanor-claims` header."
  def encode_claims(claims), do: claims |> Jason.encode!() |> Base.url_encode64(padding: false)

  @doc "Decodes the `x-atanor-claims` header value."
  def decode_claims(value) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> :error
    end
  end
end
