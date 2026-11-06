defmodule Atanor.EgressPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Atanor.{Egress, Request, Response}

  # The blocked IPv4 ranges as inclusive integer bounds (RFC 6890 and friends), written apart from the code.
  @blocked_v4 [
    {0x00000000, 0x00FFFFFF},
    {0x0A000000, 0x0AFFFFFF},
    {0x64400000, 0x647FFFFF},
    {0x7F000000, 0x7FFFFFFF},
    {0xA9FE0000, 0xA9FEFFFF},
    {0xAC100000, 0xAC1FFFFF},
    {0xC0000000, 0xC00000FF},
    {0xC0000200, 0xC00002FF},
    {0xC0586300, 0xC05863FF},
    {0xC0A80000, 0xC0A8FFFF},
    {0xC6120000, 0xC613FFFF},
    {0xC6336400, 0xC63364FF},
    {0xCB007100, 0xCB0071FF},
    {0xE0000000, 0xFFFFFFFF}
  ]

  defp v4_int({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  defp v4_blocked?(ip), do: Enum.any?(@blocked_v4, fn {lo, hi} -> v4_int(ip) in lo..hi end)

  defp octet, do: integer(0..255)

  # Addresses at the edges of the blocked ranges and anywhere.
  defp v4 do
    edges = Enum.flat_map(@blocked_v4, fn {lo, hi} -> [lo - 1, lo, hi, hi + 1] end)

    one_of([
      map(member_of(edges), &(&1 |> max(0) |> min(0xFFFFFFFF) |> int_v4())),
      map({octet(), octet(), octet(), octet()}, & &1)
    ])
  end

  defp int_v4(n), do: {n >>> 24, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}
  defp halves({a, b, c, d}), do: {a <<< 8 ||| b, c <<< 8 ||| d}

  defp v6, do: map(List.duplicate(integer(0..0xFFFF), 8) |> List.to_tuple() |> tuple(), & &1)

  defp width(ip), do: if(tuple_size(ip) == 4, do: 32, else: 128)

  defp to_int(ip),
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< if(tuple_size(ip) == 4, do: 8, else: 16) ||| &1))

  defp inside?(ip, base, bits) do
    tuple_size(ip) == tuple_size(base) and to_int(ip) >>> (width(base) - bits) == to_int(base) >>> (width(base) - bits)
  end

  defp cidr do
    gen all(base <- one_of([v4(), v6()]), bits <- integer(0..width(base))) do
      {:cidr, base, bits}
    end
  end

  # An address inside the block, so that a permit has something to match.
  defp inside(base, bits) do
    gen all(
          bits_below <- integer(0..((1 <<< (width(base) - bits)) - 1)//max(1, 1 <<< max(width(base) - bits - 16, 0))),
          do: bits_below
        ) do
      pack(base, (to_int(base) >>> (width(base) - bits)) <<< (width(base) - bits) ||| bits_below)
    end
  end

  defp pack(base, n) when tuple_size(base) == 4, do: int_v4(n)
  defp pack(_, n), do: for(i <- 7..0//-1, into: [], do: n >>> (16 * i) &&& 0xFFFF) |> List.to_tuple()

  describe "blocked?" do
    # An IPv4 address is blocked iff it lies in one of the listed ranges, edges included.
    property "IPv4 follows the table of blocked ranges" do
      for {lo, hi} <- @blocked_v4, n <- [lo - 1, lo, hi, hi + 1], n in 0..0xFFFFFFFF do
        assert Egress.blocked?(int_v4(n)) == v4_blocked?(int_v4(n)), inspect(int_v4(n))
      end

      check all(ip <- v4(), max_runs: 300) do
        assert Egress.blocked?(ip) == v4_blocked?(ip), inspect(ip)
      end
    end

    # IPv4-mapped, NAT64 and 6to4 addresses are judged as the IPv4 address they carry.
    property "an IPv6 form that carries an IPv4 address is blocked iff that address is" do
      check all(ip <- v4(), tail <- list_of(integer(0..0xFFFF), length: 5), max_runs: 300) do
        {hi, lo} = halves(ip)
        [_, _, _, _, _] = tail
        want = v4_blocked?(ip)

        assert Egress.blocked?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) == want
        assert Egress.blocked?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}) == want
        assert Egress.blocked?(List.to_tuple([0x2002, hi, lo | tail])) == want
      end
    end

    # Unique-local, link-local, multicast, `::/96`, Teredo and the local NAT64 prefix are always blocked.
    property "the IPv6 special ranges are blocked whatever follows the prefix" do
      check all(
              rest <- list_of(integer(0..0xFFFF), length: 7),
              first <- member_of([0xFC00, 0xFDFF, 0xFE80, 0xFEBF, 0xFF00, 0xFFFF])
            ) do
        assert Egress.blocked?(List.to_tuple([first | rest]))
        [_, b, c, d, e, f, g] = rest
        assert Egress.blocked?({0x2001, 0, c, d, e, f, g, b})
        assert Egress.blocked?({0x64, 0xFF9B, 1, d, e, f, g, b})
        assert Egress.blocked?({0, 0, 0, 0, 0, 0, g, b})
      end

      refute Egress.blocked?({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111})
      refute Egress.blocked?({0x2001, 1, 0, 0, 0, 0, 0, 0})
      refute Egress.blocked?({0xFBFF, 0xFFFF, 0, 0, 0, 0, 0, 0})
    end
  end

  describe "allow_private_hosts" do
    # An address block parses to itself, and a bare address to a block of its whole length.
    property "a CIDR entry parses to its base and length" do
      check all({:cidr, base, bits} <- cidr()) do
        text = "#{base |> :inet.ntoa() |> to_string()}/#{bits}"
        assert Egress.parse_entry(text) == {:ok, {:cidr, base, bits}}
        assert Egress.parse_entry(text |> String.split("/") |> hd()) == {:ok, {:cidr, base, width(base)}}
      end
    end

    # A prefix length outside the width of the family, or not a plain number, is refused.
    property "invalid prefix lengths are refused" do
      check all(
              {:cidr, base, _} <- cidr(),
              bad <- one_of([constant(width(base) + 1), integer((width(base) + 1)..300), integer(-300..-1)])
            ) do
        ip = base |> :inet.ntoa() |> to_string()
        assert Egress.parse_entry("#{ip}/#{bad}") == :error
      end

      for text <- [
            "10.0.0.0/",
            "10.0.0.0/8/8",
            "10.0.0.0/ 8",
            "10.0.0.0/8x",
            "10.0.0/8",
            "/8",
            "",
            "Example.com",
            "a b"
          ] do
        assert Egress.parse_entry(text) == :error, text
      end
    end

    # A blocked literal address passes iff a permitted block of the same family holds it; the others always pass.
    property "an address is refused unless a permitted block of its own family holds it" do
      check all(
              ip <-
                one_of([
                  v4(),
                  v6(),
                  map(v4(), fn v ->
                    {hi, lo} = halves(v)
                    {0, 0, 0, 0, 0, 0xFFFF, hi, lo}
                  end)
                ]),
              permits <- list_of(cidr(), max_length: 4),
              max_runs: 300
            ) do
        text = ip |> :inet.ntoa() |> to_string()
        permitted = Enum.any?(permits, fn {:cidr, base, bits} -> inside?(ip, base, bits) end)

        result = Egress.resolve(text, permits)

        if Egress.blocked?(ip) and not permitted,
          do: assert({:error, {:private_address, ^text, _}} = result),
          else: assert({:ok, ^ip} = result)
      end
    end

    # A permitted block lets through the addresses inside it, and nothing outside it.
    property "a block permits exactly its own addresses" do
      check all({:cidr, base, bits} = block <- cidr(), ip <- inside(base, bits), outside <- v4()) do
        text = ip |> :inet.ntoa() |> to_string()
        assert inside?(ip, base, bits)
        assert {:ok, ^ip} = Egress.resolve(text, [block])

        if Egress.blocked?(outside) and not inside?(outside, base, bits),
          do:
            assert({:error, {:private_address, _, _}} = Egress.resolve(outside |> :inet.ntoa() |> to_string(), [block]))
      end
    end
  end

  describe "redirect" do
    @credentials [{"authorization", "Bearer x"}, {"cookie", "a=b"}, {"proxy-authorization", "p"}]

    defp request(scheme, host, port),
      do: %Request{
        method: "POST",
        scheme: scheme,
        host: host,
        port: port,
        path: "/a",
        body: "payload",
        headers: [{"accept", "*/*"} | @credentials]
      }

    # A redirect keeps the credentials only inside the origin, never goes from https to http, and drops the body unless 307/308.
    property "redirects keep credentials inside their origin and never leave https" do
      check all(
              status <- member_of([301, 302, 303, 307, 308]),
              scheme <- member_of(["http", "https"]),
              target <- member_of(["http", "https"]),
              same_host <- boolean(),
              same_port <- boolean()
            ) do
        port = if scheme == "https", do: 443, else: 80
        host = if same_host, do: "a.test", else: "b.test"
        tport = if same_port, do: port, else: 8443
        location = "#{target}://#{host}:#{tport}/next"
        response = %Response{status: status, headers: [{"location", location}]}

        result = Egress.redirect(response, request(scheme, "a.test", port))

        cond do
          scheme == "https" and target == "http" ->
            assert result == {:error, :insecure_redirect}

          true ->
            assert {:ok, next} = result
            same_origin? = target == scheme and same_host and tport == port
            kept = for {name, _} <- next.headers, name in ["authorization", "cookie", "proxy-authorization"], do: name
            assert kept != [] == same_origin?
            assert {"accept", "*/*"} in next.headers
            assert (next.body == "payload" and next.method == "POST") == status in [307, 308]
            assert next.path == "/next"
        end
      end
    end
  end
end
