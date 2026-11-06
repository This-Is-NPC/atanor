defmodule Atanor.ManifestHostsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Manifest

  defp label,
    do:
      string(~c"abc01-", min_length: 1, max_length: 3)
      |> filter(&(not String.starts_with?(&1, "-") and not String.ends_with?(&1, "-")))

  defp domain, do: map(list_of(label(), min_length: 2, max_length: 4), &Enum.join(&1, "."))
  defp bare, do: one_of([domain(), label()])
  defp pattern, do: one_of([bare(), map(domain(), &("*." <> &1))])
  # What a route may name: a host, a wildcard or the catch-all.
  defp route_host, do: one_of([pattern(), constant("*")])

  defp allowing(entry), do: %Manifest{http_allow: [entry]}
  defp allowed?(pattern, host), do: Manifest.http_allowed?(allowing({nil, pattern, nil}), "https", host, 443)

  # A host that the pattern matches: the host itself, or a subdomain below the wildcard's domain.
  defp witness("*." <> domain), do: "w." <> domain
  defp witness(host), do: host

  describe "allow_covered?" do
    # Whatever an entry lets through, a covering operator pattern lets through too; this is why a manifest cannot widen the operator's list.
    property "a covered entry reaches no host the pattern does not allow" do
      check all(pattern <- route_host(), host <- pattern(), probe <- bare(), max_runs: 400) do
        if Manifest.allow_covered?(pattern, host) do
          for candidate <- [witness(host), "x." <> witness(host), probe], allowed?(host, candidate) do
            assert pattern == "*" or allowed?(pattern, candidate), "#{host} reaches #{candidate} outside #{pattern}"
          end
        end
      end
    end

    # An entry that is not covered reaches a host that the pattern refuses, so the check is not too strict to be a limit.
    property "an entry that is not covered has a host outside the pattern" do
      check all(pattern <- one_of([pattern(), constant("*")]), host <- pattern(), max_runs: 400) do
        if pattern != "*" and not Manifest.allow_covered?(pattern, host) and not String.starts_with?(host, "*") do
          assert allowed?(host, host)
          refute allowed?(pattern, host)
        end

        if pattern != "*" and not Manifest.allow_covered?(pattern, host) and String.starts_with?(host, "*.") do
          assert allowed?(host, witness(host))
          refute allowed?(pattern, witness(host)) and allowed?(pattern, "x." <> witness(host))
        end
      end
    end

    # A wildcard entry is never covered by the bare domain, and every host is covered by itself.
    property "a pattern covers itself, and a bare domain does not cover its wildcard" do
      check all(host <- pattern(), domain <- domain(), label <- label()) do
        refute Manifest.allow_covered?("*." <> domain, "*." <> label <> domain),
               "a suffix without the dot is another domain"

        assert Manifest.allow_covered?("*." <> domain, "*." <> label <> "." <> domain)
        refute Manifest.allow_covered?("*." <> label <> "." <> domain, "*." <> domain)
        assert Manifest.allow_covered?(host, host)
        assert Manifest.allow_covered?("*", host)
        refute Manifest.allow_covered?(domain, "*." <> domain)
      end
    end
  end

  describe "host_covered?" do
    # A route host is covered by `*`, by the same pattern, and by a wildcard whose domain it is under; never by the bare domain.
    property "route hosts are covered by * and by the wildcards above them" do
      check all(host <- route_host(), domain <- domain(), label <- label()) do
        assert Manifest.host_covered?("*", host)
        assert Manifest.host_covered?(host, host)
        assert Manifest.host_covered?("*." <> domain, label <> "." <> domain)
        assert Manifest.host_covered?("*." <> domain, "*." <> label <> "." <> domain)
        refute Manifest.host_covered?("*." <> domain, domain)
        refute Manifest.host_covered?(domain, "*." <> domain)
        refute Manifest.host_covered?("*." <> domain, label <> domain), "a suffix without the dot is another domain"
      end
    end
  end

  describe "http_allowed?" do
    # A wildcard entry allows subdomains only, a bare entry its own host only, and scheme and port narrow it.
    property "entries match by host, scheme and port" do
      check all(
              domain <- domain(),
              label <- label(),
              scheme <- member_of([nil, "http", "https"]),
              port <- member_of([nil, 80, 443, 8080]),
              wildcard? <- boolean(),
              request_scheme <- member_of(["http", "https"]),
              request_port <- member_of([80, 443, 8080])
            ) do
        entry = if wildcard?, do: "*." <> domain, else: domain
        host = if wildcard?, do: label <> "." <> domain, else: domain
        manifest = allowing({scheme, entry, port})

        want = (is_nil(scheme) or scheme == request_scheme) and (is_nil(port) or port == request_port)
        assert Manifest.http_allowed?(manifest, request_scheme, host, request_port) == want
        refute Manifest.http_allowed?(manifest, request_scheme, "other-" <> domain, request_port)
        if wildcard?, do: refute(Manifest.http_allowed?(manifest, request_scheme, domain, request_port))
      end
    end
  end
end
