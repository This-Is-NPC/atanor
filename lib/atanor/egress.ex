defmodule Atanor.Egress do
  @moduledoc """
  Address policy for outbound HTTP (design §4). A host is resolved before
  connecting, and the request goes to an address that was checked: when any
  resolved address is private, loopback, link-local, multicast or
  unspecified, the request is refused unless the operator's
  `allow_private_hosts` permits it.

  `allow_private_hosts` entries are a host name (every address of that name is
  permitted) or a CIDR block or IP address (`"10.0.0.0/8"`, `"::1"`).

  `redirect/2` decides the next hop of a redirect: it never leaves https and
  it drops credentials when the origin changes.
  """

  alias Atanor.{Request, Response}

  import Bitwise

  @type entry :: {:host, String.t()} | {:cidr, :inet.ip_address(), 0..128}

  @blocked_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]
  # `::/96` holds `::` and `::1` and the IPv4-compatible addresses; Teredo (`2001::/32`) and the local-use
  # NAT64 prefix (`64:ff9b:1::/48`) hide an address that cannot be judged.
  @blocked_v6 [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    {{0x64, 0xFF9B, 1, 0, 0, 0, 0, 0}, 48},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 32},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc "Parses an `allow_private_hosts` entry."
  @spec parse_entry(term) :: {:ok, entry} | :error
  def parse_entry(entry) when is_binary(entry) do
    case String.split(entry, "/") do
      [one] -> single(one)
      [ip, len] -> cidr(ip, len)
      _ -> :error
    end
  end

  def parse_entry(_), do: :error

  @doc """
  Resolves `host` and returns the address to connect to. Errors:
  `{:unresolved, host}` and `{:private_address, host, ip}`.
  """
  @spec resolve(String.t(), [entry], timeout) ::
          {:ok, :inet.ip_address()} | {:error, {:unresolved, String.t()} | {:private_address, String.t(), String.t()}}
  def resolve(host, permitted, timeout \\ 5_000) do
    case addresses(host, timeout) do
      [] ->
        {:error, {:unresolved, host}}

      [first | _] = addresses ->
        case Enum.find(addresses, &(blocked?(&1) and not permitted?(host, &1, permitted))) do
          nil -> {:ok, first}
          ip -> {:error, {:private_address, host, ip |> :inet.ntoa() |> to_string()}}
        end
    end
  end

  @doc "Whether the address is in a range that outbound HTTP refuses by default."
  @spec blocked?(:inet.ip_address()) :: boolean
  def blocked?({_, _, _, _} = ip), do: Enum.any?(@blocked_v4, &in_cidr?(ip, &1))

  # IPv4-mapped, NAT64 and 6to4 addresses carry an IPv4 address that is judged on its own.
  def blocked?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: blocked?(embedded(hi, lo))
  def blocked?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: blocked?(embedded(hi, lo))
  def blocked?({0x2002, hi, lo, _, _, _, _, _}), do: blocked?(embedded(hi, lo))
  def blocked?({_, _, _, _, _, _, _, _} = ip), do: Enum.any?(@blocked_v6, &in_cidr?(ip, &1))

  @credentials ~w(authorization cookie proxy-authorization)
  @default_ports %{"http" => 80, "https" => 443}

  @doc """
  The request to send after `response`: `{:ok, request}`, `nil` when the
  response is not a redirect with a location, or `{:error, :insecure_redirect}`
  for a redirect from https to http. A 301, 302 or 303 becomes a GET without a
  body. The request keeps its credential headers (`authorization`, `cookie`,
  `proxy-authorization`) only within its origin.
  """
  @spec redirect(Response.t(), Request.t()) :: {:ok, Request.t()} | nil | {:error, :insecure_redirect}
  def redirect(%Response{status: status, headers: headers}, %Request{} = request)
      when status in [301, 302, 303, 307, 308] do
    with {_, location} <- List.keyfind(headers, "location", 0) do
      uri = URI.merge(URI.parse("#{request.scheme}://#{request.host}:#{request.port}#{request.path}"), location)
      keep? = status in [307, 308]

      next = %Request{
        request
        | method: if(keep?, do: request.method, else: "GET"),
          body: if(keep?, do: request.body, else: ""),
          scheme: uri.scheme,
          host: uri.host || "",
          port: uri.port,
          path: uri.path || "/",
          query: uri.query || ""
      }

      cond do
        request.scheme == "https" and next.scheme != "https" ->
          {:error, :insecure_redirect}

        origin(next) == origin(request) ->
          {:ok, next}

        true ->
          {:ok,
           %Request{
             next
             | headers: Enum.reject(next.headers, fn {name, _} -> String.downcase(name) in @credentials end)
           }}
      end
    end
  end

  def redirect(_, _), do: nil

  @doc "Milliseconds left until `limits.deadline` (a monotonic time in milliseconds)."
  @spec remaining(%{deadline: integer}) :: non_neg_integer
  def remaining(%{deadline: deadline}), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  Sends `request` to `address` (an IP address, or a host name) and reads the
  answer, which is never followed. The name of the request goes in the Host
  header and the TLS handshake. A connection serves one request, so no pool is
  keyed by the names a worker may reach. The body is read while the deadline
  and `limits.max_bytes` hold: `{:error, :timeout}` or `{:error,
  :response_too_large}` end it.
  """
  @spec send_request(Request.t(), :inet.ip_address() | String.t(), %{deadline: integer, max_bytes: pos_integer}) ::
          {:ok, Response.t()} | {:error, term}
  def send_request(%Request{} = r, ip, limits) do
    default? = Map.get(@default_ports, r.scheme) == r.port
    host_header = if default?, do: r.host, else: "#{r.host}:#{r.port}"
    headers = [{"host", host_header} | Enum.reject(r.headers, fn {name, _} -> String.downcase(name) == "host" end)]
    target = if r.query == "", do: r.path, else: r.path <> "?" <> r.query
    options = [hostname: r.host, mode: :passive, protocols: [:http1], transport_opts: [timeout: remaining(limits)]]

    case Mint.HTTP.connect(String.to_existing_atom(r.scheme), ip, r.port, options) do
      {:ok, conn} ->
        try do
          exchange(conn, r.method, target, headers, if(r.body == "", do: nil, else: r.body), limits)
        after
          Mint.HTTP.close(conn)
        end

      {:error, exception} ->
        {:error, {:fetch_failed, Exception.message(exception)}}
    end
  end

  defp exchange(conn, method, target, headers, body, limits) do
    case Mint.HTTP.request(conn, method, target, headers, body) do
      {:ok, conn, ref} -> read(conn, ref, %{status: 0, headers: [], body: []}, 0, limits)
      {:error, _conn, exception} -> {:error, {:fetch_failed, Exception.message(exception)}}
    end
  end

  # Reads the response until it ends, the body passes the cap or the deadline.
  defp read(conn, ref, response, size, limits) do
    case remaining(limits) do
      0 ->
        {:error, :timeout}

      wait ->
        case Mint.HTTP.recv(conn, 0, wait) do
          {:ok, conn, parts} -> parts(parts, conn, ref, response, size, limits)
          {:error, _conn, %Mint.TransportError{reason: :timeout}, _} -> {:error, :timeout}
          {:error, _conn, exception, _} -> {:error, {:fetch_failed, Exception.message(exception)}}
        end
    end
  end

  defp parts([], conn, ref, response, size, limits), do: read(conn, ref, response, size, limits)

  defp parts([part | rest], conn, ref, response, size, limits) do
    case part do
      {:status, ^ref, status} ->
        parts(rest, conn, ref, %{response | status: status}, size, limits)

      {:headers, ^ref, headers} ->
        parts(rest, conn, ref, %{response | headers: response.headers ++ headers}, size, limits)

      {:data, ^ref, data} when size + byte_size(data) > limits.max_bytes ->
        {:error, :response_too_large}

      {:data, ^ref, data} ->
        parts(rest, conn, ref, %{response | body: [response.body | data]}, size + byte_size(data), limits)

      {:done, ^ref} ->
        {:ok, %Response{status: response.status, headers: response.headers, body: IO.iodata_to_binary(response.body)}}

      {:error, ^ref, exception} ->
        {:error, {:fetch_failed, Exception.message(exception)}}
    end
  end

  defp origin(%Request{scheme: scheme, host: host, port: port}), do: {scheme, String.downcase(host), port}

  defp embedded(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp permitted?(host, ip, permitted) do
    Enum.any?(permitted, fn
      {:host, name} -> name == host
      {:cidr, _, _} = cidr -> in_cidr?(ip, cidr)
    end)
  end

  defp addresses(host, timeout) do
    case parse_ip(host) do
      {:ok, ip} ->
        [ip]

      :error ->
        name = String.to_charlist(host)
        Enum.uniq(lookup(name, :inet, timeout) ++ lookup(name, :inet6, timeout))
    end
  end

  defp lookup(name, family, timeout) do
    case :inet.getaddrs(name, family, timeout) do
      {:ok, list} -> list
      {:error, _} -> []
    end
  end

  defp parse_ip(string) do
    case :inet.parse_strict_address(String.to_charlist(string)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp single(entry) do
    case parse_ip(entry) do
      {:ok, addr} -> {:ok, {:cidr, addr, bits(addr)}}
      :error -> if entry =~ ~r/\A[a-z0-9.-]+\z/, do: {:ok, {:host, entry}}, else: :error
    end
  end

  defp cidr(ip, len) do
    with {:ok, addr} <- parse_ip(ip),
         {bits, ""} <- Integer.parse(len),
         true <- bits in 0..bits(addr) do
      {:ok, {:cidr, addr, bits}}
    else
      _ -> :error
    end
  end

  defp bits(addr), do: tuple_size(addr) * if(tuple_size(addr) == 4, do: 8, else: 16)

  defp in_cidr?(ip, {:cidr, base, bits}) when tuple_size(ip) == tuple_size(base) do
    shift = bits(base) - bits
    to_int(ip) >>> shift == to_int(base) >>> shift
  end

  defp in_cidr?(ip, {base, bits}), do: in_cidr?(ip, {:cidr, base, bits})
  defp in_cidr?(_, _), do: false

  defp to_int(ip) do
    width = if tuple_size(ip) == 4, do: 8, else: 16
    ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> acc <<< width ||| part end)
  end
end
