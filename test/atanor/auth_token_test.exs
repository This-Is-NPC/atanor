defmodule Atanor.AuthTokenTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Auth.Token
  alias Atanor.Test.OIDCProvider

  @issuer "https://id.example.test"
  @now 1_800_000_000
  @leeway 60

  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    other = JOSE.JWK.generate_key({:rsa, 2048})
    %{jwk: jwk, other: other, keys: [OIDCProvider.public(jwk, "k1")]}
  end

  defp rule(overrides \\ []) do
    Map.merge(
      %{
        issuer: @issuer,
        audience: ["api"],
        scopes: ["read"],
        types: ["at+jwt"],
        algorithms: ["RS256"],
        leeway_s: @leeway
      },
      Map.new(overrides)
    )
  end

  defp claims(extra \\ %{}) do
    Map.merge(
      %{"iss" => @issuer, "aud" => "api", "sub" => "u1", "iat" => @now, "exp" => @now + 300, "scope" => "read write"},
      extra
    )
  end

  defp sign(jwk, claims, header \\ %{}), do: OIDCProvider.sign(jwk, "k1", claims, header)

  defp b64(term), do: term |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp verify(token, keys, rule \\ rule()), do: Token.verify(token, rule, keys, @now)

  describe "a valid token" do
    test "passes with its claims intact", %{jwk: jwk, keys: keys} do
      extra = %{
        "org_ids" => ["o1", "o2"],
        "act" => %{"sub" => "agent"},
        "n" => 1.5,
        "nested" => %{"a" => [1, nil, true]}
      }

      assert {:ok, claims} = verify(sign(jwk, claims(extra)), keys)
      assert claims == claims(extra)
    end

    test "accepts an audience list, scp as an array, and the application/ typ form", %{jwk: jwk, keys: keys} do
      c = claims(%{"aud" => ["x", "api"], "scope" => nil, "scp" => ["read"]})
      assert {:ok, _} = verify(sign(jwk, c, %{"typ" => "application/AT+JWT"}), keys)
    end

    test "any typ when the rule lists none", %{jwk: jwk, keys: keys} do
      assert {:ok, _} = verify(sign(jwk, claims(), %{"typ" => "JWT"}), keys, rule(types: nil))
    end

    test "accepts an optional claim at the edge of the leeway", %{jwk: jwk, keys: keys} do
      c = claims(%{"exp" => @now - @leeway + 1, "nbf" => @now + @leeway, "iat" => @now + @leeway})
      assert {:ok, _} = verify(sign(jwk, c), keys)
    end

    test "works with EC and EdDSA keys" do
      for {alg, spec} <- [{"ES256", {:ec, "P-256"}}, {"ES384", {:ec, "P-384"}}, {"EdDSA", {:okp, :Ed25519}}] do
        jwk = JOSE.JWK.generate_key(spec)
        {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
        header = %{"alg" => alg, "typ" => "at+jwt", "kid" => "e"}
        {_, token} = jwk |> JOSE.JWT.sign(header, claims()) |> JOSE.JWS.compact()
        keys = [Map.put(public, "kid", "e")]
        assert {:ok, _} = verify(token, keys, rule(algorithms: [alg])), alg
        assert {:error, :algorithm} = verify(token, keys), alg
      end
    end
  end

  describe "rejections" do
    test "malformed tokens", %{keys: keys} do
      for token <- ["", "a", "a.b", "a.b.c.d", "a.b.", "!!.b.c", b64(%{}) <> ".e30.c", b64([1]) <> ".e30.c"] do
        assert {:error, :malformed} = verify(token, keys), token
      end
    end

    test "alg none, with or without an empty signature", %{keys: keys} do
      payload = b64(claims())

      for header <- [%{"alg" => "none", "kid" => "k1"}, %{"alg" => "None"}, %{"alg" => "NONE"}],
          signature <- ["", "AAAA"] do
        assert {:error, _} = verify("#{b64(header)}.#{payload}.#{signature}", keys)
        assert {:error, _} = verify("#{b64(header)}.#{payload}.#{signature}", keys, rule(algorithms: ["none", "RS256"]))
      end
    end

    test "HS256 with the public key as the secret", %{jwk: jwk, keys: keys} do
      {_, pem} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
      json = Jason.encode!(hd(keys))
      permissive = rule(algorithms: ["RS256", "HS256"])

      for secret <- [pem, json] do
        header = %{"alg" => "HS256", "typ" => "at+jwt", "kid" => "k1"}
        {_, token} = secret |> JOSE.JWK.from_oct() |> JOSE.JWT.sign(header, claims()) |> JOSE.JWS.compact()
        assert {:error, :algorithm} = verify(token, keys)
        assert {:error, :algorithm} = verify(token, keys, permissive)
      end
    end

    test "an oct key never verifies", %{keys: _} do
      oct = %{"kty" => "oct", "k" => Base.url_encode64("secret", padding: false), "kid" => "k1"}
      header = %{"alg" => "RS256", "typ" => "at+jwt", "kid" => "k1"}
      assert {:error, :no_key} = verify("#{b64(header)}.#{b64(claims())}.AAAA", [oct])
    end

    test "a key whose declared alg or use differs", %{jwk: jwk, keys: [key]} do
      token = sign(jwk, claims())
      assert {:error, :no_key} = verify(token, [Map.put(key, "alg", "RS512")])
      assert {:error, :no_key} = verify(token, [Map.put(key, "use", "enc")])
      assert {:error, :no_key} = verify(token, [Map.put(key, "kid", "other")])
      assert {:error, :no_key} = verify(token, [])
    end

    test "typ, crit and a non-string kid", %{jwk: jwk, keys: keys} do
      assert {:error, :type} = verify(sign(jwk, claims(), %{"typ" => "JWT"}), keys)
      assert {:error, :type} = verify(sign(jwk, claims(), %{"typ" => nil}), keys)
      assert {:error, :malformed} = verify(sign(jwk, claims(), %{"crit" => ["exp"]}), keys)
      assert {:error, :malformed} = verify(sign(jwk, claims(), %{"kid" => 1}), keys)
    end

    test "missing or malformed registered claims", %{jwk: jwk, keys: keys} do
      assert {:error, :no_expiry} = verify(sign(jwk, Map.delete(claims(), "exp")), keys)
      assert {:error, :no_expiry} = verify(sign(jwk, claims(%{"exp" => "9999999999"})), keys)
      assert {:error, :issuer} = verify(sign(jwk, Map.delete(claims(), "iss")), keys)
      assert {:error, :audience} = verify(sign(jwk, Map.delete(claims(), "aud")), keys)
      assert {:error, :audience} = verify(sign(jwk, claims(%{"aud" => 5})), keys)
      assert {:error, :not_yet_valid} = verify(sign(jwk, claims(%{"nbf" => "0"})), keys)
      assert {:error, :issued_in_future} = verify(sign(jwk, claims(%{"iat" => nil})), keys)
      header = %{"alg" => "RS256", "typ" => "at+jwt", "kid" => "k1"}
      {_, array} = jwk |> JOSE.JWS.sign("[1]", header) |> JOSE.JWS.compact()
      assert {:error, :claims} = verify(array, keys)
    end

    test "a missing scope names what is missing only in the tuple", %{jwk: jwk, keys: keys} do
      assert {:error, {:insufficient_scope, ["write"]}} =
               verify(sign(jwk, claims(%{"scope" => "read"})), keys, rule(scopes: ["read", "write"]))

      assert {:error, {:insufficient_scope, ["read"]}} = verify(sign(jwk, claims(%{"scope" => nil})), keys)
      assert {:error, {:insufficient_scope, _}} = verify(sign(jwk, claims(%{"scope" => "reader"})), keys)
    end

    test "a scope error never hides an invalid token", %{jwk: jwk, other: other, keys: keys} do
      assert {:error, :signature} = verify(sign(other, claims(%{"scope" => ""})), keys)
      assert {:error, :expired} = verify(sign(jwk, claims(%{"scope" => "", "exp" => @now - 1000})), keys)
    end
  end

  defp replace_payload(token, json) do
    [h, _, s] = String.split(token, ".")
    Enum.join([h, Base.url_encode64(json, padding: false), s], ".")
  end

  describe "properties" do
    @describetag :property

    defp scope_set, do: StreamData.list_of(StreamData.member_of(~w(read write admin extra)), max_length: 4)

    defp extra_claims do
      StreamData.map_of(
        StreamData.string(:alphanumeric, min_length: 3, max_length: 8),
        StreamData.one_of([StreamData.integer(), StreamData.string(:printable), StreamData.boolean()]),
        max_length: 5
      )
      |> StreamData.map(&Map.drop(&1, ["iss", "aud", "exp", "iat", "nbf", "scope", "scp", "sub"]))
    end

    property "valid tokens pass with their claims intact", %{jwk: jwk, keys: keys} do
      check all(
              extra <- extra_claims(),
              scopes <- scope_set(),
              exp_in <- StreamData.integer((-@leeway + 1)..100_000),
              skew <- StreamData.integer(0..@leeway),
              aud <- StreamData.member_of(["api", ["api"], ["other", "api"]])
            ) do
        c =
          claims(%{
            "aud" => aud,
            "exp" => @now + exp_in,
            "nbf" => @now + skew,
            "iat" => @now + skew,
            "scope" => Enum.join(["read" | scopes], " ")
          })
          |> Map.merge(extra, fn _k, v, _ -> v end)

        assert {:ok, ^c} = verify(sign(jwk, c), keys)
      end
    end

    property "no invalid token passes", %{jwk: jwk, other: other, keys: keys} do
      check all(
              kind <- StreamData.member_of(~w(
                  other_key tampered issuer audience expired not_yet_valid iat_future alg_none alg_hs256
                  alg_not_allowed scope typ no_exp unsigned_tail
                )a),
              offset <- StreamData.integer(0..100_000),
              text <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
            ) do
        token = invalid_token(kind, jwk, other, keys, offset, text)
        # A key without a declared alg must still not verify an alg outside the rule's list.
        keys = if kind == :alg_not_allowed, do: Enum.map(keys, &Map.delete(&1, "alg")), else: keys
        assert {:error, _} = verify(token, keys)
      end
    end

    defp invalid_token(:other_key, _jwk, other, _keys, _o, _t), do: sign(other, claims())

    defp invalid_token(:tampered, jwk, _other, _keys, _o, t) do
      replace_payload(sign(jwk, claims()), Jason.encode!(claims(%{"sub" => t, "scope" => "read admin"})))
    end

    defp invalid_token(:issuer, jwk, _other, _keys, _o, t), do: sign(jwk, claims(%{"iss" => @issuer <> "/" <> t}))
    defp invalid_token(:audience, jwk, _other, _keys, _o, t), do: sign(jwk, claims(%{"aud" => ["x" <> t]}))
    defp invalid_token(:expired, jwk, _other, _keys, o, _t), do: sign(jwk, claims(%{"exp" => @now - @leeway - o}))

    defp invalid_token(:not_yet_valid, jwk, _other, _keys, o, _t),
      do: sign(jwk, claims(%{"nbf" => @now + @leeway + 1 + o}))

    defp invalid_token(:iat_future, jwk, _other, _keys, o, _t),
      do: sign(jwk, claims(%{"iat" => @now + @leeway + 1 + o}))

    defp invalid_token(:no_exp, jwk, _other, _keys, _o, _t), do: sign(jwk, Map.delete(claims(), "exp"))
    defp invalid_token(:typ, jwk, _other, _keys, _o, t), do: sign(jwk, claims(), %{"typ" => "x" <> t})
    defp invalid_token(:scope, jwk, _other, _keys, _o, t), do: sign(jwk, claims(%{"scope" => "read" <> t}))
    defp invalid_token(:alg_not_allowed, jwk, _other, _keys, _o, _t), do: sign(jwk, claims(), %{"alg" => "RS512"})

    defp invalid_token(:alg_none, _jwk, _other, _keys, _o, t),
      do: "#{b64(%{"alg" => "none", "typ" => "at+jwt", "kid" => "k1"})}.#{b64(claims(%{"sub" => t}))}."

    defp invalid_token(:unsigned_tail, _jwk, _other, _keys, _o, t),
      do: "#{b64(%{"alg" => "none", "typ" => "at+jwt"})}.#{b64(claims())}.#{t}"

    defp invalid_token(:alg_hs256, _jwk, _other, [key], _o, _t) do
      header = %{"alg" => "HS256", "typ" => "at+jwt", "kid" => "k1"}

      {_, token} =
        key |> Jason.encode!() |> JOSE.JWK.from_oct() |> JOSE.JWT.sign(header, claims()) |> JOSE.JWS.compact()

      token
    end

    property "tokens signed by an unpublished key never pass whatever else they carry", %{other: other, keys: keys} do
      check all(extra <- extra_claims(), kid <- StreamData.member_of(["k1", "k2", nil])) do
        header = %{"alg" => "RS256", "typ" => "at+jwt", "kid" => kid}
        {_, token} = other |> JOSE.JWT.sign(header, Map.merge(claims(), extra)) |> JOSE.JWS.compact()
        assert {:error, _} = verify(token, keys)
      end
    end
  end
end
