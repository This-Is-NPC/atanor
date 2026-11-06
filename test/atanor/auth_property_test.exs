defmodule Atanor.AuthPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Auth

  @hosts ["a.test", "b.test", "*.a.test", "*.x.a.test", "*.test", "*"]
  @paths ["/", "/api", "/api/v1", "/other", "/api/v1/admin"]
  @oidc %{allow_http: false}

  defp rules(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {{host, path}, i} ->
      [host: host, path: path, issuer: "https://issuer.test", audience: "aud", realm: "r#{i}"]
    end)
    |> Auth.rules!(@oidc)
  end

  # The rule that answers a request with no credentials names its realm.
  defp realm(entries, host, path) do
    case Auth.check(:none, %{auth: rules(entries)}, host, path, []) do
      :open -> nil
      {:reject, 401, challenge, nil, :missing} -> Regex.run(~r/realm="(r\d+)"/, challenge) |> List.last()
    end
  end

  defp host_rank(pattern, host) do
    cond do
      pattern == host ->
        {:ok, 1000}

      pattern == "*" ->
        {:ok, 0}

      String.starts_with?(pattern, "*.") and String.ends_with?(host, String.trim_leading(pattern, "*")) ->
        {:ok, byte_size(pattern)}

      true ->
        :no
    end
  end

  defp path_match?(prefix, path), do: prefix == "/" or path == prefix or String.starts_with?(path, prefix <> "/")

  defp concrete_host, do: member_of(["a.test", "b.test", "x.a.test", "y.x.a.test", "z.test", "other.org", "test"])

  defp concrete_path,
    do: member_of(["/", "/api", "/api/", "/api/v1", "/api/v10", "/apix", "/api/v1/admin/x", "/other/api", "/zzz"])

  # The most specific rule wins: hosts first (exact, longer wildcard, shorter, `*`), then the longest path prefix.
  property "the most specific covering rule applies, sub-paths included" do
    check all(
            entries <- uniq_list_of(tuple({member_of(@hosts), member_of(@paths)}), max_length: 6),
            host <- concrete_host(),
            path <- concrete_path(),
            max_runs: 300
          ) do
      candidates =
        for {{h, p}, i} <- Enum.with_index(entries),
            {:ok, rank} <- [host_rank(h, host)],
            path_match?(p, path),
            do: {{rank, byte_size(p)}, "r#{i}"}

      want = if candidates == [], do: nil, else: candidates |> Enum.max() |> elem(1)
      assert realm(entries, host, String.trim_trailing(path, "/") |> then(&if(&1 == "", do: "/", else: &1))) == want
    end
  end

  # A request with no rule above it stays open, and a trailing slash in a rule's path is not part of the prefix.
  property "rule paths ignore a trailing slash" do
    check all(path <- member_of(@paths), host <- concrete_host()) do
      assert realm([{"*", path <> "/"}], host, "/api") == realm([{"*", path}], host, "/api")
    end
  end

  defp token68 do
    string(Enum.concat([?A..?Z, ?a..?z, ?0..?9, ~c"-_~+/"]), min_length: 1, max_length: 20)
  end

  defp status(headers) do
    case Auth.check(:none, %{auth: rules([{"*", "/"}])}, "h.test", "/", headers) do
      {:reject, status, _, error, _} -> {status, error}
    end
  end

  describe "bearer" do
    # A missing or non-Bearer credential is 401 with no error code; a malformed or repeated one is 400.
    property "the status follows the shape of the Authorization header" do
      check all(
              scheme <- member_of(["Bearer", "bearer", "BEARER", "Basic", "Digest", "Bear"]),
              token <- token68(),
              pad <- member_of(["", "=", "=="])
            ) do
        value = scheme <> " " <> token <> pad
        # A well-shaped token is judged as a token: it is not a JWT.
        want = if String.downcase(scheme) == "bearer", do: {401, "invalid_token"}, else: {401, nil}
        assert status([{"authorization", String.replace(value, ".", "")}]) == want
      end

      assert status([]) == {401, nil}
    end

    property "tokens with other bytes, an empty token, or two headers are a bad request" do
      check all(bad <- member_of([" ", "\"", "\\", "=a", "a b", "é", "a,b", "a;b"]), token <- token68()) do
        assert status([{"authorization", "Bearer " <> token <> bad}]) == {400, "invalid_request"}
        assert status([{"authorization", "Bearer " <> bad}]) == {400, "invalid_request"}
      end

      assert status([{"authorization", "Bearer "}]) == {400, "invalid_request"}

      check all(token <- token68()) do
        header = {"authorization", "Bearer " <> token}
        assert status([header, header]) == {400, "invalid_request"}
      end
    end
  end

  describe "claims header" do
    defp scalar, do: one_of([string(:printable, max_length: 8), integer(), boolean(), constant(nil)])

    defp json_map do
      tree(scalar(), fn child ->
        one_of([list_of(child, max_length: 3), map_of(string(:alphanumeric, max_length: 6), child, max_length: 3)])
      end)
      |> map_of_top()
    end

    defp map_of_top(gen), do: map_of(string(:alphanumeric, min_length: 1, max_length: 6), gen, max_length: 4)

    # Claims survive the header unchanged, and the header is plain base64url.
    property "encoded claims decode to the same map" do
      check all(claims <- json_map()) do
        encoded = Auth.encode_claims(claims)
        assert encoded =~ ~r/\A[A-Za-z0-9_-]*\z/
        assert Auth.decode_claims(encoded) == {:ok, claims}
      end
    end

    # A header value that is not encoded claims is refused, never raised on.
    property "anything else decodes to :error or a map" do
      check all(value <- one_of([binary(max_length: 40), string(:printable, max_length: 40)])) do
        assert match?({:ok, %{}}, Auth.decode_claims(value)) or Auth.decode_claims(value) == :error
      end

      for json <- ["[]", "1", "\"s\"", "null"],
          do: assert(Auth.decode_claims(Base.url_encode64(json, padding: false)) == :error)
    end

    # The claims header is removed in any case, and nothing else.
    property "strip_claims removes every spelling of the claims header only" do
      check all(
              others <-
                list_of(
                  tuple({string(~c"abcdefg-", min_length: 1, max_length: 5), string(:alphanumeric, max_length: 3)}),
                  max_length: 5
                ),
              spelling <- member_of(["x-atanor-claims", "X-Atanor-Claims", "X-ATANOR-CLAIMS"]),
              at <- integer(0..5)
            ) do
        headers = List.insert_at(others, min(at, length(others)), {spelling, "forged"})
        assert Auth.strip_claims(headers) == others
      end
    end
  end
end
