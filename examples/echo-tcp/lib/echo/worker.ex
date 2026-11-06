defmodule Echo.Worker do
  @moduledoc """
  A line protocol over TCP. `HELLO <name>` names the visitor, `VISIT` counts a
  visit in the visitor's cell and answers the total, `QUIT` ends the session.
  After `HELLO` the connection is bound to the visitor's cell.
  """
  @behaviour Atanor.Worker

  alias Atanor.Env

  @impl true
  def tcp_init(_info, _env), do: {:reply, "READY\r\n", %{buffer: "", name: nil}}

  @impl true
  def handle_tcp(data, state, env), do: lines(%{state | buffer: state.buffer <> data}, env, [])

  # Bind the connection to the visitor's cell once HELLO named it.
  @impl true
  def route_key({:tcp, %{name: name}}, _env) when is_binary(name), do: {:cell, "visits", name}
  def route_key(_input, _env), do: :none

  defp lines(%{buffer: buffer} = state, env, out) do
    case String.split(buffer, "\r\n", parts: 2) do
      [line, rest] ->
        case command(line, %{state | buffer: rest}, env) do
          {:ok, state, reply} -> lines(state, env, [out, reply, "\r\n"])
          :quit -> {:close, [out, "BYE\r\n"]}
        end

      [_partial] when byte_size(buffer) > 256 ->
        {:close, [out, "ERR line too long\r\n"]}

      [_partial] ->
        if out == [], do: {:continue, state}, else: {:reply, out, state}
    end
  end

  defp command("HELLO " <> name, state, _env), do: {:ok, %{state | name: name}, "OK #{name}"}
  defp command("VISIT", %{name: nil} = state, _env), do: {:ok, state, "ERR say HELLO first"}

  defp command("VISIT", %{name: name} = state, env) do
    {:ok, _} = Env.execute(env, {"visits", name}, "UPDATE visits SET n = n + 1")
    {:ok, %{rows: [[n]]}} = Env.query(env, {"visits", name}, "SELECT n FROM visits")
    {:ok, state, "VISITS #{n}"}
  end

  defp command("QUIT", _state, _env), do: :quit
  defp command(_other, state, _env), do: {:ok, state, "ERR unknown command"}
end
