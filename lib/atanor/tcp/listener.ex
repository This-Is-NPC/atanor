defmodule Atanor.TCP.Listener do
  @moduledoc false
  # One operator `listeners:` entry (design §7.3): the address it binds, the
  # server that runs it and its TLS mode. The shape is validated by
  # `Atanor.Config`, which raises `ArgumentError` through `build!/4`.

  defstruct [:name, :port, :ip, :protocol, :tls_mode, :tls, :acceptors, :max_connections, :workers]

  @type t :: %__MODULE__{
          name: String.t(),
          port: :inet.port_number(),
          ip: :inet.ip_address(),
          protocol: :thousand_island | :ranch,
          tls_mode: nil | :implicit | :starttls,
          tls: map | nil,
          acceptors: pos_integer,
          max_connections: pos_integer,
          workers: [String.t()] | nil
        }

  @protocols [:thousand_island, :ranch]
  @tls_modes [nil, :implicit, :starttls]
  @keys [:port, :ip, :protocol, :tls_mode, :tls, :acceptors, :max_connections, :workers]

  @doc """
  Builds a listener from an integer port or a keyword list. `ingress_ip` is
  the default of `:ip`, and `tcp` supplies the defaults of `:acceptors` and
  `:max_connections`. `:workers`, a list of worker names, says which workers may
  claim the listener (default: any, like an absent `hosts:`). `:ip` is an IPv4 or IPv6 address tuple, or a string
  such as `"127.0.0.2"` or `"::1"`, which is parsed here.
  """
  @spec build!(String.t(), term, :inet.ip_address(), map) :: t
  def build!(name, port, ingress_ip, tcp) when is_integer(port), do: build!(name, [port: port], ingress_ip, tcp)

  def build!(name, opts, ingress_ip, tcp) when is_list(opts) do
    check!(Keyword.keyword?(opts), name, "must be an integer port or a keyword list")

    case Keyword.keys(opts) -- @keys do
      [] -> :ok
      unknown -> raise ArgumentError, ":listeners entry #{inspect(name)}: unknown options #{inspect(unknown)}"
    end

    port = Keyword.get(opts, :port)
    ip = ip!(name, Keyword.get(opts, :ip, ingress_ip))
    protocol = Keyword.get(opts, :protocol, :thousand_island)
    tls_mode = Keyword.get(opts, :tls_mode)
    tls = Keyword.get(opts, :tls)
    acceptors = Keyword.get(opts, :acceptors, tcp.acceptors)
    max_connections = Keyword.get(opts, :max_connections, tcp.max_connections)
    workers = Keyword.get(opts, :workers)

    check!(is_integer(port) and port in 0..65_535, name, ":port is required and must be an integer from 0 to 65535")
    check!(protocol in @protocols, name, ":protocol must be :thousand_island or :ranch")
    check!(tls_mode in @tls_modes, name, ":tls_mode must be :implicit or :starttls")
    check!(positive_integer?(acceptors), name, ":acceptors must be a positive integer")
    check!(positive_integer?(max_connections), name, ":max_connections must be a positive integer")
    check!(acceptors <= max_connections, name, ":acceptors must not exceed :max_connections")

    check!(
      is_nil(workers) or (is_list(workers) and Enum.all?(workers, &is_binary/1)),
      name,
      ":workers must be a list of worker names"
    )

    cond do
      tls_mode != nil and tls == nil ->
        raise ArgumentError, ":listeners entry #{inspect(name)}: :tls_mode needs :tls"

      tls_mode == nil and tls != nil ->
        raise ArgumentError, ":listeners entry #{inspect(name)}: :tls needs :tls_mode (:implicit or :starttls)"

      true ->
        :ok
    end

    %__MODULE__{
      name: name,
      port: port,
      ip: ip,
      protocol: protocol,
      tls_mode: tls_mode,
      tls: if(tls, do: Atanor.TCP.TLS.build!(name, tls)),
      acceptors: acceptors,
      max_connections: max_connections,
      workers: workers
    }
  end

  def build!(name, _other, _ingress_ip, _tcp),
    do: raise(ArgumentError, ":listeners entry #{inspect(name)}: invalid entry")

  defp ip!(name, ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, address} -> address
      {:error, _} -> bad_ip!(name)
    end
  end

  defp ip!(name, ip) when is_tuple(ip) do
    if is_list(:inet.ntoa(ip)), do: ip, else: bad_ip!(name)
  end

  defp ip!(name, _ip), do: bad_ip!(name)

  defp bad_ip!(name),
    do: raise(ArgumentError, ":listeners entry #{inspect(name)}: :ip must be an IPv4 or IPv6 address (tuple or string)")

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp check!(true, _name, _message), do: :ok

  defp check!(false, name, message),
    do: raise(ArgumentError, ":listeners entry #{inspect(name)}: #{message}")
end
