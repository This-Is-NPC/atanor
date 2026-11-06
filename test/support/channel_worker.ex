defmodule Atanor.Test.ChannelWorker do
  @moduledoc """
  Test worker for ephemeral channels. `/room/ROOM` routes the socket to the cell
  `{"rooms", ROOM}`.

  `handle_ws_local/3` (on the socket's node): `cur ROOM X` publishes `NODE|X`
  to the channel of `{"rooms", ROOM}` and drops the frame; `probe` publishes
  what a cell read from the local callback returned to `rooms/probe`; any other
  frame passes.

  `handle_ws/3` (on the owner): `join ROOM [ID]`, `leave ROOM`, `pub ROOM X`,
  `big ROOM N` (publishes N bytes), `members ROOM` (`COUNT:ID,ID`), `node`, `echo X`.
  """
  @behaviour Atanor.Worker

  alias Atanor.{Env, Request}

  @impl true
  def ws_init(%Request{path: path}, _env), do: {:ok, %{path: path}}

  @impl true
  def route_key(%Request{path: "/room/" <> room}, _env), do: {:cell, "rooms", room}
  def route_key(_input, _env), do: :none

  @impl true
  def handle_ws_local({:text, "cur " <> rest}, _state, env) do
    [room, body] = String.split(rest, " ", parts: 2)
    Env.publish(env, {"rooms", room}, {:text, "#{node()}|#{body}"})
    :drop
  end

  def handle_ws_local({:text, "probe"}, _state, env) do
    result = Env.query(env, {"rooms", "probe"}, "SELECT 1")
    Env.publish(env, {"rooms", "probe"}, {:text, inspect(result)})
    :drop
  end

  def handle_ws_local(_frame, _state, _env), do: :pass

  @impl true
  def handle_ws({:text, "echo " <> text}, state, _env), do: {:reply, [{:text, text}], state}
  def handle_ws({:text, "node"}, state, _env), do: {:reply, [{:text, Atom.to_string(node())}], state}

  def handle_ws({:text, "join " <> rest}, state, env) do
    {room, id} = room_and_rest(rest)
    {:reply, [{:text, inspect(Env.join_channel(env, {"rooms", room}, id: id))}], state}
  end

  def handle_ws({:text, "leave " <> room}, state, env),
    do: {:reply, [{:text, inspect(Env.leave_channel(env, {"rooms", room}))}], state}

  def handle_ws({:text, "pub " <> rest}, state, env) do
    {room, text} = room_and_rest(rest)
    {:reply, [{:text, inspect(Env.publish(env, {"rooms", room}, {:text, text}))}], state}
  end

  def handle_ws({:text, "big " <> rest}, state, env) do
    {room, size} = room_and_rest(rest)
    data = :binary.copy("x", String.to_integer(size))
    {:reply, [{:text, inspect(Env.publish(env, {"rooms", room}, {:binary, data}))}], state}
  end

  def handle_ws({:text, "members " <> room}, state, env) do
    reply =
      case Env.channel_members(env, {"rooms", room}) do
        {:ok, %{count: count, ids: ids}} -> "#{count}:#{ids |> Enum.sort() |> Enum.join(",")}"
        other -> inspect(other)
      end

    {:reply, [{:text, reply}], state}
  end

  def handle_ws({:text, other}, state, _env), do: {:reply, [{:text, "?" <> other}], state}
  def handle_ws({:binary, _}, state, _env), do: {:ok, state}

  defp room_and_rest(text) do
    case String.split(text, " ", parts: 2) do
      [room, rest] -> {room, rest}
      [room] -> {room, nil}
    end
  end

  @doc "Publishes `bodies` in order to the channel of `{\"rooms\", room}` from the calling process."
  def publish_all(instance, worker, room, bodies) do
    {:ok, deployment} = Atanor.Registry.deployment(instance, worker)
    env = Env.new(instance, deployment)
    for body <- bodies, do: :ok = Env.publish(env, {"rooms", room}, {:text, body})
    :ok
  end
end
