defmodule Atanor.HTTP.Deadline do
  @moduledoc """
  An absolute deadline for reading a request on an HTTP/1 connection (design §7.1). The listener's
  `:read_timeout_ms` bounds each read, so a client that sends a byte just inside it holds its
  connection for ever. While a deadline is armed in the connection process, `Transport.recv/3` never waits
  past it: Bandit then answers 408 and closes.

  `Handler` arms `:header_timeout_ms` when the connection starts (Bandit reads its first request there) and
  for each chunk it receives after, and clears it when Bandit is done. The plug clears it as soon as the headers are read and arms `:body_timeout_ms` around
  its body read (`within/2`). HTTP/2 streams run in their own process, where no deadline is armed (Bandit
  bounds a stream's body read by its own deadline, which the caller passes as the read timeout).
  """

  @key :atanor_read_deadline

  @doc false
  @spec arm(pos_integer) :: :ok
  def arm(ms) do
    Process.put(@key, System.monotonic_time(:millisecond) + ms)
    :ok
  end

  @doc false
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc false
  # Runs `fun` under a deadline of `ms` and clears it after.
  @spec within(pos_integer, (-> result)) :: result when result: term
  def within(ms, fun) do
    arm(ms)

    try do
      fun.()
    after
      clear()
    end
  end

  @doc false
  # The wait a read may still have: `timeout` while no deadline is armed, otherwise the smaller of both.
  @spec remaining(timeout) :: timeout
  def remaining(timeout) do
    case Process.get(@key) do
      nil -> timeout
      deadline -> min(timeout, max(deadline - System.monotonic_time(:millisecond), 0))
    end
  end

  defmodule Transport do
    @moduledoc false
    # ThousandIsland's TCP transport with reads bounded by the armed deadline.
    @behaviour ThousandIsland.Transport

    alias ThousandIsland.Transports.TCP

    @impl true
    defdelegate listen(port, options), to: TCP
    @impl true
    defdelegate accept(listener), to: TCP
    @impl true
    defdelegate handshake(socket), to: TCP
    @impl true
    defdelegate handshake(socket, timeout), to: TCP
    @impl true
    defdelegate upgrade(socket, options), to: TCP
    @impl true
    defdelegate controlling_process(socket, pid), to: TCP
    @impl true
    defdelegate send(socket, data), to: TCP
    @impl true
    defdelegate sendfile(socket, filename, offset, length), to: TCP
    @impl true
    defdelegate getopts(socket, options), to: TCP
    @impl true
    defdelegate setopts(socket, options), to: TCP
    @impl true
    defdelegate shutdown(socket, way), to: TCP
    @impl true
    defdelegate close(socket), to: TCP
    @impl true
    defdelegate sockname(socket), to: TCP
    @impl true
    defdelegate peername(socket), to: TCP
    @impl true
    defdelegate peercert(socket), to: TCP
    @impl true
    defdelegate secure?(), to: TCP
    @impl true
    defdelegate getstat(socket), to: TCP
    @impl true
    defdelegate negotiated_protocol(socket), to: TCP
    @impl true
    defdelegate connection_information(socket), to: TCP

    @impl true
    def recv(socket, length, timeout), do: TCP.recv(socket, length, Atanor.HTTP.Deadline.remaining(timeout))
  end

  defmodule Handler do
    @moduledoc false
    # Bandit's handler, with the header deadline armed for each chunk of data it handles.
    use ThousandIsland.Handler

    alias Atanor.{HTTP.Deadline, Registry}

    defdelegate handle_shutdown(socket, state), to: Bandit.DelegatingHandler
    defdelegate handle_close(socket, state), to: Bandit.DelegatingHandler
    defdelegate handle_timeout(socket, state), to: Bandit.DelegatingHandler
    defdelegate handle_error(error, socket, state), to: Bandit.DelegatingHandler
    defdelegate handle_call(msg, from, state), to: Bandit.DelegatingHandler
    defdelegate handle_cast(msg, state), to: Bandit.DelegatingHandler

    # The guard leaves ThousandIsland's own fallback for socket messages reachable.
    def handle_info(msg, state) when not (is_tuple(msg) and tuple_size(msg) == 3 and elem(msg, 0) in [:tcp, :ssl]),
      do: Bandit.DelegatingHandler.handle_info(msg, state)

    # Bandit reads the first request of a connection inside `handle_connection`, counted from the accept; the
    # next ones come through `handle_data`, counted from their first bytes.
    @impl ThousandIsland.Handler
    def handle_connection(socket, %{plug: plug} = state),
      do: armed(plug, fn -> Bandit.DelegatingHandler.handle_connection(socket, state) end)

    # A WebSocket's state has no plug and no deadline.
    @impl ThousandIsland.Handler
    def handle_data(data, socket, %{plug: plug} = state),
      do: armed(plug, fn -> Bandit.DelegatingHandler.handle_data(data, socket, state) end)

    def handle_data(data, socket, state), do: Bandit.DelegatingHandler.handle_data(data, socket, state)

    defp armed(plug, fun) do
      Deadline.arm(header_timeout_ms(plug))

      try do
        fun.()
      after
        Deadline.clear()
      end
    end

    defp header_timeout_ms({Atanor.Admin, name}), do: Registry.config(name).admin.header_timeout_ms
    defp header_timeout_ms({_plug, name}), do: Registry.config(name).http.header_timeout_ms
  end
end
