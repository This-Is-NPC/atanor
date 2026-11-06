defmodule Atanor.Test.LineWorker do
  @moduledoc """
  Test worker speaking a toy SMTP-like protocol over TCP: `HELO x`, `RCPT <user>`,
  `DATA` (lines until a lone `.`), `STARTTLS` (upgrades the connection), `WHO`, `NODE` (the node that runs the callback), `BADNS`, `CRASH`, `QUIT`. Messages are
  stored in the cell `{"mail", user}`; the connection is routed to that cell
  once `RCPT` named it. It reports `route_key` calls and chunk sizes to the process
  registered as `:line_worker_probe`.
  """
  @behaviour Atanor.Worker

  alias Atanor.Env

  @migrations [[1, "CREATE TABLE mail (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"]]
  def migrations, do: @migrations

  @impl true
  def tcp_init(%{listener: listener, peer: {_ip, _port}}, _env),
    do: {:reply, "220 #{listener} ready\r\n", %{buffer: "", rcpt: nil, ns: "mail", data: nil}}

  @impl true
  def handle_tcp(data, state, env) do
    if probe = Process.whereis(:line_worker_probe), do: send(probe, {:chunk, byte_size(data)})
    lines(%{state | buffer: state.buffer <> data}, env, [])
  end

  @impl true
  def route_key({:tcp, %{rcpt: rcpt, ns: ns} = state}, _env) do
    if probe = Process.whereis(:line_worker_probe), do: send(probe, {:route_key, state})
    if rcpt, do: {:cell, ns, rcpt}, else: :none
  end

  defp lines(state, env, out) do
    case String.split(state.buffer, "\r\n", parts: 2) do
      [line, rest] ->
        case line(line, %{state | buffer: rest}, env) do
          {:ok, state, reply} -> lines(state, env, [out, reply])
          {:starttls, reply, state} -> {:starttls, [out, reply], state}
          {:close, reply} -> {:close, [out, reply]}
        end

      [_incomplete] ->
        if byte_size(state.buffer) > 1024, do: {:close, [out, "500 line too long\r\n"]}, else: reply(out, state)
    end
  end

  defp reply([], state), do: {:continue, state}
  defp reply(out, state), do: {:reply, out, state}

  defp line(".", %{data: lines} = state, env) when is_list(lines) do
    body = lines |> Enum.reverse() |> Enum.join("\n")
    {:ok, _} = Env.execute(env, {state.ns, state.rcpt}, "INSERT INTO mail (body) VALUES (?)", [body])
    {:ok, %{state | data: nil}, "250 stored\r\n"}
  end

  defp line(text, %{data: lines} = state, _env) when is_list(lines), do: {:ok, %{state | data: [text | lines]}, ""}
  defp line("HELO " <> name, state, _env), do: {:ok, state, "250 hello #{name}\r\n"}
  defp line("RCPT " <> user, state, _env), do: {:ok, %{state | rcpt: user}, "250 ok\r\n"}
  defp line("DATA", %{rcpt: nil} = state, _env), do: {:ok, state, "503 need RCPT\r\n"}
  defp line("DATA", state, _env), do: {:ok, %{state | data: []}, "354 go ahead\r\n"}
  defp line("STARTTLS", state, _env), do: {:starttls, "220 Ready to start TLS\r\n", state}
  defp line("NODE", state, _env), do: {:ok, state, "#{node()}\r\n"}
  defp line("WHO", state, env), do: {:ok, state, "#{env.deployment.id}\r\n"}
  defp line("BADNS", state, _env), do: {:ok, %{state | ns: "other", rcpt: "x"}, "250 ok\r\n"}
  defp line("CRASH", _state, _env), do: raise("secret internals")
  defp line("QUIT", _state, _env), do: {:close, "221 bye\r\n"}
  defp line(_other, state, _env), do: {:ok, state, "500 what\r\n"}
end
