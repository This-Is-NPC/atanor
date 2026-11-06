defmodule Atanor.Auth.Token do
  @moduledoc """
  Validation of one JWT against a route's rule (design §7.5). Pure: the keys
  and the clock are arguments.

  Only asymmetric algorithms exist here, so a public key can never be used as
  an HMAC secret. A key is eligible only when its `kty` (and `crv`), its `use`
  and its `alg` agree with the header's `alg`, which must be in the rule's
  allowlist. Provider-specific claim rules are not applied (design §7.5).
  """

  @algorithms %{
    "RS256" => {"RSA", nil},
    "RS384" => {"RSA", nil},
    "RS512" => {"RSA", nil},
    "PS256" => {"RSA", nil},
    "PS384" => {"RSA", nil},
    "PS512" => {"RSA", nil},
    "ES256" => {"EC", ["P-256"]},
    "ES384" => {"EC", ["P-384"]},
    "ES512" => {"EC", ["P-521"]},
    "EdDSA" => {"OKP", ["Ed25519", "Ed448"]}
  }

  @type reason ::
          :malformed
          | :algorithm
          | :type
          | :no_key
          | :signature
          | :claims
          | :issuer
          | :audience
          | :no_expiry
          | :expired
          | :not_yet_valid
          | :issued_in_future

  @doc "The algorithms a rule may allow."
  @spec algorithms() :: [String.t()]
  def algorithms, do: Map.keys(@algorithms)

  @doc "The protected header of `token`, checked against the rule's algorithms and types. No key is needed."
  @spec header(String.t(), map) :: {:ok, map} | {:error, :malformed | :algorithm | :type}
  def header(token, rule) do
    with [header, _payload, signature] <- String.split(token, "."),
         true <- signature != "",
         {:ok, json} <- Base.url_decode64(header, padding: false),
         {:ok, %{} = header} <- Jason.decode(json) do
      check_header(header, rule)
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_header(%{"alg" => alg} = header, rule) when is_binary(alg) do
    cond do
      alg not in rule.algorithms or not is_map_key(@algorithms, alg) -> {:error, :algorithm}
      Map.has_key?(header, "crit") -> {:error, :malformed}
      not type_ok?(header["typ"], rule.types) -> {:error, :type}
      not is_nil(header["kid"]) and not is_binary(header["kid"]) -> {:error, :malformed}
      true -> {:ok, header}
    end
  end

  defp check_header(_header, _rule), do: {:error, :malformed}

  defp type_ok?(_typ, nil), do: true
  defp type_ok?(typ, types) when is_binary(typ), do: normalize_type(typ) in types
  defp type_ok?(_typ, _types), do: false

  @doc "The canonical form of a `typ` (RFC 7515 §4.1.9): lowercase, without the `application/` prefix."
  @spec normalize_type(String.t()) :: String.t()
  def normalize_type(typ), do: typ |> String.downcase() |> String.replace_prefix("application/", "")

  @doc """
  Verifies `token` with the JWKS `keys` (a list of JWK maps) at `now` (Unix
  seconds). Returns the claims, or `{:error, reason}`;
  `{:error, {:insufficient_scope, missing}}` is returned only for a token that
  is otherwise valid.
  """
  @spec verify(String.t(), map, [map], number) ::
          {:ok, map} | {:error, reason | {:insufficient_scope, [String.t()]}}
  def verify(token, rule, keys, now) do
    with {:ok, header} <- header(token, rule),
         {:ok, payload} <- verify_signature(token, header, keys),
         {:ok, claims} <- decode(payload),
         :ok <- check_claims(claims, rule, now) do
      check_scopes(claims, rule.scopes)
    end
  end

  defp verify_signature(token, %{"alg" => alg} = header, keys) do
    case Enum.filter(keys, &eligible?(&1, alg, header["kid"])) do
      [] -> {:error, :no_key}
      candidates -> Enum.find_value(candidates, {:error, :signature}, &signed(token, alg, &1))
    end
  end

  defp signed(token, alg, key) do
    case JOSE.JWS.verify_strict(JOSE.JWK.from_map(key), [alg], token) do
      {true, payload, _jws} -> {:ok, payload}
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp eligible?(%{"kty" => kty} = key, alg, kid) do
    {family, curves} = Map.fetch!(@algorithms, alg)

    kty == family and (is_nil(curves) or key["crv"] in curves) and key["use"] in [nil, "sig"] and
      key["alg"] in [nil, alg] and (is_nil(kid) or key["kid"] == kid)
  end

  defp eligible?(_key, _alg, _kid), do: false

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = claims} -> {:ok, claims}
      _ -> {:error, :claims}
    end
  end

  defp check_claims(claims, rule, now) do
    leeway = rule.leeway_s

    cond do
      claims["iss"] != rule.issuer -> {:error, :issuer}
      not audience?(claims["aud"], rule.audience) -> {:error, :audience}
      not is_number(claims["exp"]) -> {:error, :no_expiry}
      claims["exp"] + leeway <= now -> {:error, :expired}
      not time_ok?(claims, "nbf", now, leeway) -> {:error, :not_yet_valid}
      not time_ok?(claims, "iat", now, leeway) -> {:error, :issued_in_future}
      true -> :ok
    end
  end

  # An optional claim: absent is fine, present must be a number not later than now plus the leeway.
  defp time_ok?(claims, name, now, leeway) do
    case Map.fetch(claims, name) do
      :error -> true
      {:ok, value} -> is_number(value) and value - leeway <= now
    end
  end

  defp audience?(aud, accepted) when is_binary(aud), do: aud in accepted
  defp audience?(aud, accepted) when is_list(aud), do: Enum.any?(aud, &(is_binary(&1) and &1 in accepted))
  defp audience?(_aud, _accepted), do: false

  defp check_scopes(claims, []), do: {:ok, claims}

  defp check_scopes(claims, required) do
    case required -- scopes(claims) do
      [] -> {:ok, claims}
      missing -> {:error, {:insufficient_scope, missing}}
    end
  end

  @doc "The scopes of a claims map: `scope` (space-separated) and `scp` (an array or a space-separated string)."
  @spec scopes(map) :: [String.t()]
  def scopes(claims), do: split(claims["scope"]) ++ split(claims["scp"])

  defp split(value) when is_binary(value), do: String.split(value, " ", trim: true)
  defp split(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp split(_value), do: []
end
