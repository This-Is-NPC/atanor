defmodule Atanor.Test.SocketWorker do
  @moduledoc """
  Test worker with WebSockets. Text frames: `echo X`, `join ROOM` (attach to the
  cell `{"rooms", ROOM}`), `say ROOM X` (send to that cell), `node` (the node that runs the callback), `socket` (the node of the socket process), `bye`, `crash`.
  Binary frames come back reversed. Cell messages come back as `cell:X`.
  `/reject` is refused in `ws_init/2`; `/room/ROOM` is routed to that cell.
  """
  @behaviour Atanor.Worker

  alias Atanor.{Env, Request, Response}

  @impl true
  def handle_request(_request, _env), do: %Response{body: "plain http"}

  @impl true
  def ws_init(%Request{path: "/reject"}, _env), do: {:reject, %Response{status: 403, body: "no sockets for you"}}
  def ws_init(%Request{path: path}, _env), do: {:ok, %{path: path}}

  @impl true
  def route_key(%Request{path: "/room/" <> room}, _env), do: {:cell, "rooms", room}
  def route_key(%Request{path: "/ungranted"}, _env), do: {:cell, "other", "x"}
  def route_key(_input, _env), do: :none

  @impl true
  def handle_ws({:text, "echo " <> text}, state, _env), do: {:reply, [{:text, text}], state}

  def handle_ws({:text, "join " <> room}, state, env),
    do: {:reply, [{:text, inspect(Env.attach(env, {"rooms", room}))}], state}

  def handle_ws({:text, "say " <> rest}, state, env) do
    [room, text] = String.split(rest, " ", parts: 2)
    {:reply, [{:text, inspect(Env.send_to_cell(env, {"rooms", room}, text))}], state}
  end

  def handle_ws({:text, "node"}, state, _env), do: {:reply, [{:text, Atom.to_string(node())}], state}
  def handle_ws({:text, "socket"}, state, env), do: {:reply, [{:text, Atom.to_string(node(env.socket))}], state}
  def handle_ws({:text, "bye"}, state, _env), do: {:stop, state}
  def handle_ws({:text, "crash"}, _state, _env), do: raise("secret internals")
  def handle_ws({:text, other}, state, _env), do: {:reply, [{:text, "?" <> other}], state}
  def handle_ws({:binary, data}, state, _env), do: {:reply, [{:binary, String.reverse(data)}], state}
  def handle_ws({:cell_message, text}, state, _env), do: {:reply, [{:text, "cell:" <> text}], state}
end
