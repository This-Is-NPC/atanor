defmodule Atanor.EgressTest do
  use ExUnit.Case, async: true

  alias Atanor.{Egress, Request, Response}

  defp ip(text), do: with({:ok, ip} <- :inet.parse_address(String.to_charlist(text)), do: ip)

  test "blocks private, loopback, link-local, multicast and unspecified ranges" do
    for text <- ~w(0.0.0.0 10.1.2.3 100.64.0.1 127.0.0.1 127.255.255.254 169.254.169.254 172.16.0.1 172.31.255.255
                   192.168.1.1 224.0.0.1 255.255.255.255 :: ::1 fe80::1 febf::1 fc00::1 fd12:3456::1 ff02::1
                   ::ffff:127.0.0.1 ::ffff:10.0.0.1 64:ff9b::7f00:1) do
      assert Egress.blocked?(ip(text)), "#{text} should be blocked"
    end
  end

  test "lets public addresses through" do
    for text <- ~w(8.8.8.8 1.1.1.1 172.15.0.1 172.32.0.1 100.63.255.255 192.169.0.1 2606:4700::1111 2001:db8::1
                   ::ffff:8.8.8.8 64:ff9b::808:808) do
      refute Egress.blocked?(ip(text)), "#{text} should be allowed"
    end
  end

  test "parses allow_private_hosts entries" do
    assert {:ok, {:host, "internal.test"}} = Egress.parse_entry("internal.test")
    assert {:ok, {:cidr, {127, 0, 0, 1}, 32}} = Egress.parse_entry("127.0.0.1")
    assert {:ok, {:cidr, {10, 0, 0, 0}, 8}} = Egress.parse_entry("10.0.0.0/8")
    assert {:ok, {:cidr, {0, 0, 0, 0, 0, 0, 0, 1}, 128}} = Egress.parse_entry("::1")
    assert {:ok, {:cidr, {0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7}} = Egress.parse_entry("fc00::/7")

    for bad <- ["10.0.0.0/33", "10.0.0.0/x", "::/129", "A B", "", 5, nil, "a/b/c"] do
      assert Egress.parse_entry(bad) == :error, inspect(bad)
    end
  end

  describe "resolve" do
    test "returns an address that was checked" do
      assert {:ok, {8, 8, 8, 8}} = Egress.resolve("8.8.8.8", [])
    end

    test "refuses private addresses unless permitted, by CIDR or by host name" do
      assert {:error, {:private_address, "127.0.0.1", "127.0.0.1"}} = Egress.resolve("127.0.0.1", [])
      assert {:error, {:private_address, "::1", "::1"}} = Egress.resolve("::1", [])
      assert {:error, {:private_address, "localhost", _}} = Egress.resolve("localhost", [])

      assert {:ok, {127, 0, 0, 1}} = Egress.resolve("127.0.0.1", [elem(Egress.parse_entry("127.0.0.0/8"), 1)])

      assert {:error, {:private_address, _, _}} =
               Egress.resolve("127.0.0.1", [elem(Egress.parse_entry("10.0.0.0/8"), 1)])

      assert {:ok, _} = Egress.resolve("localhost", [{:host, "localhost"}])
    end

    test "every address of a name must be permitted" do
      # localhost has 127.0.0.1 and usually ::1: permitting only the IPv4 range is not enough.
      v4_only = [{:cidr, {127, 0, 0, 0}, 8}]

      case :inet.getaddrs(~c"localhost", :inet6) do
        {:ok, [_ | _]} -> assert {:error, {:private_address, "localhost", "::1"}} = Egress.resolve("localhost", v4_only)
        _ -> assert {:ok, _} = Egress.resolve("localhost", v4_only)
      end
    end

    test "reports names that do not resolve" do
      assert {:error, {:unresolved, "no-such-host.invalid"}} = Egress.resolve("no-such-host.invalid", [])
    end
  end

  test "blocks ranges that carry or route to an IPv4 address" do
    for text <- ~w(2002:7f00:1:: 2002:a00:1:: 2001:0:7f00:1::1 64:ff9b:1::1 ::7f00:1 ::a00:1 192.0.2.1 198.51.100.1
                   203.0.113.1 192.88.99.1) do
      assert Egress.blocked?(ip(text)), "#{text} should be blocked"
    end

    for text <- ~w(2002:808:808:: 2606:4700::1111) do
      refute Egress.blocked?(ip(text)), "#{text} should be allowed"
    end
  end

  describe "redirect" do
    defp redirect(location, request \\ %Request{scheme: "https", host: "a.test", port: 443, path: "/x"}, status \\ 302),
      do: Egress.redirect(%Response{status: status, headers: [{"location", location}]}, request)

    test "is nil for a response that does not redirect" do
      assert Egress.redirect(%Response{status: 200}, %Request{}) == nil
      assert Egress.redirect(%Response{status: 302, headers: []}, %Request{}) == nil
    end

    test "never goes from https to http" do
      assert {:error, :insecure_redirect} = redirect("http://a.test/y")
      assert {:error, :insecure_redirect} = redirect("http://b.test/y")
      assert {:ok, %Request{scheme: "http", host: "a.test"}} = redirect("/y", %Request{scheme: "http", host: "a.test"})
    end

    test "keeps credentials in one origin and drops them in another" do
      headers = [{"authorization", "a"}, {"cookie", "c"}, {"proxy-authorization", "p"}, {"x-other", "o"}]
      request = %Request{scheme: "https", host: "a.test", port: 443, path: "/x", headers: headers}

      assert {:ok, %Request{headers: ^headers, path: "/y"}} = redirect("/y", request)
      assert {:ok, %Request{headers: [{"x-other", "o"}], host: "b.test"}} = redirect("https://b.test/y", request)
      assert {:ok, %Request{headers: [{"x-other", "o"}], port: 8443}} = redirect("https://a.test:8443/y", request)
    end

    test "turns 301, 302 and 303 into a GET without a body, and keeps the method for 307 and 308" do
      request = %Request{method: "POST", body: "b", scheme: "http", host: "a.test", port: 80}
      assert {:ok, %Request{method: "GET", body: ""}} = redirect("/y", request, 301)
      assert {:ok, %Request{method: "POST", body: "b"}} = redirect("/y", request, 307)
    end
  end
end
