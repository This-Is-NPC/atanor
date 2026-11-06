defmodule Atanor.Test.SmtpCallback do
  @moduledoc """
  Minimal gen_smtp callback: every accepted message is written to the cell
  `{"smtp", recipient}` through the `Atanor.Env` that Atanor puts in the
  `callbackoptions` it passes to `init/4`.
  """
  @behaviour :gen_smtp_server_session

  alias Atanor.Env

  @impl true
  def init(_hostname, _session_count, _peer, opts) do
    env = Keyword.fetch!(opts, :atanor_env)
    listener = Keyword.fetch!(opts, :atanor_listener)
    {:ok, "atanor #{env.deployment.id} #{listener}", %{env: env, recipient: nil}}
  end

  @impl true
  def handle_HELO(_hostname, state), do: {:ok, 655_360, state}

  @impl true
  def handle_EHLO(_hostname, extensions, state),
    do: {:ok, [{~c"STARTTLS", true} | extensions], state}

  @impl true
  def handle_MAIL(_from, state), do: {:ok, state}

  @impl true
  def handle_MAIL_extension(_extension, _state), do: :error

  @impl true
  def handle_RCPT(to, state), do: {:ok, %{state | recipient: to}}

  @impl true
  def handle_RCPT_extension(_extension, _state), do: :error

  @impl true
  def handle_VRFY(_address, state), do: {:error, "252 VRFY disabled", state}

  @impl true
  def handle_DATA(_from, _to, _data, %{recipient: nil} = state), do: {:error, "503 no recipient", state}

  def handle_DATA(_from, _to, data, state) do
    case Env.execute(state.env, {"smtp", state.recipient}, "INSERT INTO mail (body) VALUES (?)", [data]) do
      {:ok, _} -> {:ok, "stored", state}
      {:error, reason} -> {:error, "451 #{inspect(reason)}", state}
    end
  end

  @impl true
  def handle_RSET(state), do: state

  @impl true
  def handle_STARTTLS(state), do: state

  @impl true
  def handle_other(_verb, _args, state), do: {"500 unknown command", state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end

defmodule Atanor.Test.SmtpWorker do
  @moduledoc """
  A native worker that claims a Ranch listener and serves it with gen_smtp.
  The protocol is built at accept with the `Atanor.Env` of the connection.
  """
  @behaviour Atanor.Worker

  @migrations [[1, "CREATE TABLE mail (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"]]
  def migrations, do: @migrations

  @impl true
  def ranch_protocol(_env) do
    {:gen_smtp_server_session, {Atanor.Test.SmtpCallback, [hostname: "atanor.test", callbackoptions: []]}}
  end
end

defmodule Atanor.Test.SmtpClient do
  @moduledoc "A tiny SMTP client over TCP or TLS, for the Ranch and TLS tests."

  def connect(port, :plain) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    {:ok, {:tcp, socket}}
  end

  def connect(port, :implicit) do
    {:ok, socket} =
      :ssl.connect(~c"127.0.0.1", port, [verify: :verify_none, active: false, mode: :binary, packet: :line], 5_000)

    {:ok, {:ssl, socket}}
  end

  def upgrade({:tcp, socket}) do
    {:ok, ssl} = :ssl.connect(socket, [verify: :verify_none, active: false, mode: :binary], 5_000)
    :ok = :ssl.setopts(ssl, packet: :line)
    {:ok, {:ssl, ssl}}
  end

  def command(socket, line) do
    :ok = send_line(socket, line)
    response(socket)
  end

  def starttls(socket) do
    lines = command(socket, "STARTTLS")

    with {:ok, upgraded} <- upgrade(socket) do
      {:ok, upgraded, lines}
    end
  end

  def data(socket, body) do
    ["354" <> _] = command(socket, "DATA")
    :ok = send_bytes(socket, body <> "\r\n.\r\n")
    response(socket)
  end

  def quit(socket), do: command(socket, "QUIT")

  def peer_cert({:ssl, socket}), do: :ssl.peercert(socket)

  def closed?({:tcp, socket}), do: match?({:error, _}, :gen_tcp.recv(socket, 0, 5_000))
  def closed?({:ssl, socket}), do: match?({:error, _}, :ssl.recv(socket, 0, 5_000))

  def close({:tcp, socket}), do: :gen_tcp.close(socket)
  def close({:ssl, socket}), do: :ssl.close(socket)

  def recv({:tcp, socket}) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    String.trim_trailing(line)
  end

  def recv({:ssl, socket}) do
    {:ok, line} = :ssl.recv(socket, 0, 5_000)
    String.trim_trailing(line)
  end

  defp send_line(socket, line), do: send_bytes(socket, line <> "\r\n")

  defp send_bytes({:tcp, socket}, bytes), do: :gen_tcp.send(socket, bytes)
  defp send_bytes({:ssl, socket}, bytes), do: :ssl.send(socket, bytes)

  # A response is one or more lines; continuation lines have "-" after the code.
  defp response(socket), do: response(socket, [])

  defp response(socket, acc) do
    line = recv(socket)

    if multiline?(line),
      do: response(socket, [line | acc]),
      else: Enum.reverse([line | acc])
  end

  defp multiline?(line), do: byte_size(line) > 3 and binary_part(line, 3, 1) == "-"
end
