defmodule Atanor.TCP.TLS.Transport do
  @moduledoc false
  # ThousandIsland's SSL transport with two changes (design §7.3): the TLS
  # options of every handshake are read from the listener's certificate cache,
  # and the handshake is timed and reported. The accept socket carries the
  # listener it belongs to; the handshake replaces the connection's TLS
  # options with the ones loaded now, so a reloaded certificate is used without
  # restarting the listener.

  @behaviour ThousandIsland.Transport

  alias Atanor.TCP.TLS
  alias ThousandIsland.Transports.SSL

  @impl true
  def listen(port, opts) do
    {meta, ssl_opts} = Keyword.pop(opts, :atanor)

    case SSL.listen(port, ssl_opts) do
      {:ok, socket} -> {:ok, {socket, meta}}
      error -> error
    end
  end

  @impl true
  def accept({socket, meta}) do
    case SSL.accept(socket) do
      {:ok, accepted} -> {:ok, {accepted, meta}}
      error -> error
    end
  end

  @impl true
  def handshake({socket, meta}, timeout) do
    TLS.handshake(meta.instance, meta.listener, :implicit, timeout, fn opts, timeout ->
      :ssl.handshake(socket, opts, timeout)
    end)
  end

  @impl true
  def handshake({_socket, _meta} = socket), do: handshake(socket, 5_000)
  def handshake(socket), do: SSL.handshake(socket)

  @impl true
  def upgrade(socket, meta) do
    TLS.handshake(meta.instance, meta.listener, :starttls, :configured, fn opts, timeout ->
      :ssl.handshake(socket, opts, timeout)
    end)
  end

  @impl true
  def controlling_process(socket, pid), do: SSL.controlling_process(unwrap(socket), pid)

  @impl true
  def recv(socket, length, timeout), do: SSL.recv(unwrap(socket), length, timeout)

  @impl true
  def send(socket, data), do: SSL.send(unwrap(socket), data)

  @impl true
  def sendfile(socket, filename, offset, length),
    do: SSL.sendfile(unwrap(socket), filename, offset, length)

  @impl true
  def getopts(socket, opts), do: SSL.getopts(unwrap(socket), opts)

  @impl true
  def setopts(socket, opts), do: SSL.setopts(unwrap(socket), opts)

  @impl true
  def shutdown(socket, way), do: SSL.shutdown(unwrap(socket), way)

  @impl true
  def close(socket), do: SSL.close(unwrap(socket))

  @impl true
  def sockname(socket), do: SSL.sockname(unwrap(socket))

  @impl true
  def peername(socket), do: SSL.peername(unwrap(socket))

  @impl true
  def peercert(socket), do: SSL.peercert(unwrap(socket))

  @impl true
  def secure?, do: true

  @impl true
  def getstat(socket), do: SSL.getstat(unwrap(socket))

  @impl true
  def negotiated_protocol(socket), do: SSL.negotiated_protocol(unwrap(socket))

  @impl true
  def connection_information(socket), do: SSL.connection_information(unwrap(socket))

  # The listen socket and the accepted socket before the handshake are wrapped
  # with their listener; after the handshake no wrapper is left.
  defp unwrap({socket, %{instance: _, listener: _}}), do: socket
  defp unwrap(socket), do: socket
end

defmodule Atanor.TCP.Ranch.Transport do
  @moduledoc false
  # Ranch's SSL transport with the same certificate cache as
  # `Atanor.TCP.TLS.Transport` (design §7.3). Ranch gives the listener's
  # metadata through `socket_opts`, which is removed before the options reach
  # `:ssl`; the accepted socket carries it until the handshake.

  # Ranch is optional: without it the behaviour is not declared, so a build
  # without Ranch stays warning-free. With Ranch the compiler checks every
  # callback below.
  if Code.ensure_loaded?(:ranch_transport) do
    @behaviour :ranch_transport
  end

  @compile {:no_warn_undefined, :ranch_ssl}

  alias Atanor.TCP.TLS

  def listen(trans_opts) do
    {meta, socket_opts} = pop_meta(trans_opts)

    case :ranch_ssl.listen(%{trans_opts | socket_opts: socket_opts}) do
      {:ok, socket} -> {:ok, {socket, meta}}
      error -> error
    end
  end

  def accept({socket, meta}, timeout) do
    case :ranch_ssl.accept(socket, timeout) do
      {:ok, accepted} -> {:ok, {accepted, meta}}
      error -> error
    end
  end

  def handshake({socket, meta}, timeout) do
    TLS.handshake(meta.instance, meta.listener, :implicit, timeout, fn opts, timeout ->
      :ssl.handshake(socket, opts, timeout)
    end)
  end

  def handshake(socket, timeout), do: handshake(socket, [], timeout)

  def handshake(socket, opts, timeout) do
    case :ssl.handshake(unwrap(socket), opts, timeout) do
      {:ok, socket, _extensions} -> {:ok, socket}
      other -> other
    end
  end

  def handshake_continue(socket, timeout), do: :ranch_ssl.handshake_continue(unwrap(socket), timeout)

  def handshake_continue(socket, opts, timeout), do: :ranch_ssl.handshake_continue(unwrap(socket), opts, timeout)

  def handshake_cancel(socket), do: :ranch_ssl.handshake_cancel(unwrap(socket))

  def controlling_process(socket, pid), do: :ranch_ssl.controlling_process(unwrap(socket), pid)

  def recv(socket, length, timeout), do: :ranch_ssl.recv(unwrap(socket), length, timeout)

  def send(socket, data), do: :ranch_ssl.send(unwrap(socket), data)

  def sendfile(socket, filename), do: :ranch_ssl.sendfile(unwrap(socket), filename)

  def sendfile(socket, filename, offset, length),
    do: :ranch_ssl.sendfile(unwrap(socket), filename, offset, length)

  def sendfile(socket, filename, offset, length, opts),
    do: :ranch_ssl.sendfile(unwrap(socket), filename, offset, length, opts)

  def setopts(socket, opts), do: :ranch_ssl.setopts(unwrap(socket), opts)

  def getopts(socket, opts), do: :ranch_ssl.getopts(unwrap(socket), opts)

  def getstat(socket), do: :ranch_ssl.getstat(unwrap(socket))

  def getstat(socket, stats), do: :ranch_ssl.getstat(unwrap(socket), stats)

  def peername(socket), do: :ranch_ssl.peername(unwrap(socket))

  def sockname(socket), do: :ranch_ssl.sockname(unwrap(socket))

  def shutdown(socket, way), do: :ranch_ssl.shutdown(unwrap(socket), way)

  def close(socket), do: :ranch_ssl.close(unwrap(socket))

  def cleanup(trans_opts), do: :ranch_ssl.cleanup(trans_opts)

  def name, do: :ranch_ssl.name()

  def secure, do: true

  def messages, do: :ranch_ssl.messages()

  def connect(host, port, opts), do: :ranch_ssl.connect(host, port, opts)

  def connect(host, port, opts, timeout), do: :ranch_ssl.connect(host, port, opts, timeout)

  def recv_proxy_header(socket, timeout), do: :ranch_ssl.recv_proxy_header(unwrap(socket), timeout)

  def format_error(reason), do: :ranch_ssl.format_error(reason)

  defp pop_meta(%{socket_opts: socket_opts}) do
    {meta, socket_opts} = Keyword.pop(socket_opts, :atanor)
    {meta, socket_opts}
  end

  defp unwrap({socket, %{instance: _, listener: _}}), do: socket
  defp unwrap(socket), do: socket
end
