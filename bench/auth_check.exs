# Cost of verifying a bearer token (design §12.14).
#
#   mise run bench:auth
#
# `Atanor.Auth.Token.verify/4` for an RS256 and an ES256 token, 20 000 calls each, in one process.

alias Atanor.Auth.Token
alias Atanor.Test.OIDCProvider

now = System.os_time(:second)

rule = fn alg ->
  %{
    issuer: "https://id.example.test",
    audience: ["api"],
    scopes: ["read"],
    types: ["at+jwt"],
    algorithms: [alg],
    leeway_s: 60
  }
end

claims = %{
  "iss" => "https://id.example.test",
  "aud" => "api",
  "sub" => "u1",
  "iat" => now,
  "exp" => now + 300,
  "scope" => "read write"
}

IO.puts("load average: #{File.read!("/proc/loadavg") |> String.split() |> Enum.take(3) |> Enum.join(" ")}")

for {alg, jwk} <- [{"RS256", JOSE.JWK.generate_key({:rsa, 2048})}, {"ES256", JOSE.JWK.generate_key({:ec, :secp256r1})}] do
  {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
  keys = [Map.merge(public, %{"kid" => "k1", "use" => "sig", "alg" => alg})]
  token = OIDCProvider.sign(jwk, "k1", claims, %{"typ" => "at+jwt", "alg" => alg})
  {:ok, _} = Token.verify(token, rule.(alg), keys, now)

  runs =
    for _ <- 1..5 do
      {us, _} = :timer.tc(fn -> for _ <- 1..20_000, do: Token.verify(token, rule.(alg), keys, now) end)
      us / 20_000
    end

  IO.puts("#{alg}: #{Float.round(Enum.at(Enum.sort(runs), 2), 1)} us per verify (median of 5 runs of 20 000)")
end
