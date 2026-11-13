defmodule AtanorLoad.Worker do
  @moduledoc """
  The native worker of the load tests (scripts/load-run, docs/how-to-run-the-load-tests.md). A native
  module must be loaded in the node: cluster/load is a derived image (mix atanor.release) that holds it, and it is active
  only after `scripts/load-env` deploys cluster/load/atanor.json.

    * `GET /native/CELL`: counts the rows of the cell `CELL` (a read).
    * `POST /native/CELL`: appends one row (a write).
    * WebSocket on `/native`: `join CELL` attaches the socket to the cell and answers `joined`.
  """
  @behaviour Atanor.Worker

  alias Atanor.{Env, Request, Response}

  @impl true
  def route_key(%Request{path: "/native/" <> cell}, _env) when cell != "", do: {:cell, "load", cell}
  def route_key(_request, _env), do: :none

  @impl true
  def handle_request(%Request{method: "GET", path: "/native/" <> cell}, env) do
    case Env.query(env, {"load", cell}, "SELECT count(*) FROM log") do
      {:ok, %{rows: [[n]]}} -> reply(200, ~s({"rows":#{n}}))
      _ -> reply(500, ~s({"error":"read"}))
    end
  end

  def handle_request(%Request{method: "POST", path: "/native/" <> cell, body: body}, env) do
    case Env.execute(env, {"load", cell}, "INSERT INTO log (v) VALUES (?)", [body]) do
      {:ok, _} -> reply(201, ~s({"ok":true}))
      _ -> reply(500, ~s({"error":"write"}))
    end
  end

  def handle_request(_request, _env), do: reply(404, ~s({"error":"not found"}))

  @impl true
  def handle_ws({:text, "join " <> cell}, state, env) do
    case Env.attach(env, {"load", String.trim(cell)}) do
      :ok -> {:reply, [{:text, "joined"}], state}
      _ -> {:reply, [{:text, "refused"}], state}
    end
  end

  def handle_ws(_message, state, _env), do: {:ok, state}

  defp reply(status, body), do: %Response{status: status, headers: [{"content-type", "application/json"}], body: body}
end
