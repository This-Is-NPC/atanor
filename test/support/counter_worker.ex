defmodule Atanor.Test.CounterWorker do
  @moduledoc """
  Test worker for cluster tests. `POST /c/CELL` with a number as the body
  appends it to the table `log` of the cell `{"log", CELL}` in one
  transaction; `GET /c/CELL` lists the numbers; `GET /c/direct/CELL` does too from a handler
  without a routing key. Replies are JSON with the node
  that ran the handler (`node`), the node and TXID of the transaction's batch
  (`tx_node`, `txid`), the deployment and the handler's start and end (`from`, `to`, operating system microseconds).

  `GET /r/CELL?ms=N` lists the numbers in a bounded request (design §19.3): it runs on the ingress node and may
  read data up to N ms old. `POST /r/CELL` tries to write in such a request, which Atanor refuses (409).
  """
  @behaviour Atanor.Worker

  alias Alambique.Tx
  alias Atanor.{Env, Request, Response}

  @migrations [[1, "CREATE TABLE log (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER NOT NULL)"]]
  def migrations, do: @migrations

  @impl true
  def route_key(%Request{path: "/c/direct/" <> _}, _env), do: :none
  def route_key(%Request{path: "/c/" <> cell}, _env), do: {:cell, "log", cell}

  def route_key(%Request{path: "/r/" <> cell, query: "ms=" <> ms}, _env),
    do: {:cell, "log", cell, consistency: {:bounded, String.to_integer(ms)}}

  def route_key(_request, _env), do: :none

  @impl true
  def handle_request(%Request{method: "POST", path: "/c/" <> cell, body: body} = request, env) do
    n = String.to_integer(body)
    from = System.os_time(:microsecond)

    result =
      Env.transaction(env, {"log", cell}, fn tx ->
        {:ok, _} = Tx.execute(tx, "INSERT INTO log (n) VALUES (?)", [n])
        {Tx.txid(tx), node()}
      end)

    case result do
      {:ok, {txid, tx_node}} ->
        json(200, %{
          node: node(),
          tx_node: tx_node,
          txid: txid,
          deployment: env.deployment.id,
          claims: Request.header(request, "x-atanor-claims"),
          from: from,
          to: System.os_time(:microsecond)
        })

      {:error, reason} ->
        json(500, %{node: node(), error: inspect(reason)})
    end
  end

  # No routing key: the handler runs on the ingress node and reaches the cell by itself.
  def handle_request(%Request{method: "GET", path: "/c/direct/" <> cell}, env) do
    case Env.query(env, {"log", cell}, "SELECT n FROM log ORDER BY id") do
      {:ok, %{rows: rows}} -> json(200, %{node: node(), rows: List.flatten(rows)})
      {:error, reason} -> json(500, %{node: node(), error: inspect(reason)})
    end
  end

  def handle_request(%Request{method: "GET", path: "/c/" <> cell}, env) do
    case Env.query(env, {"log", cell}, "SELECT n FROM log ORDER BY id") do
      {:ok, %{rows: rows}} -> json(200, %{node: node(), rows: List.flatten(rows)})
      {:error, reason} -> json(500, %{node: node(), error: inspect(reason)})
    end
  end

  def handle_request(%Request{method: "GET", path: "/r/" <> cell}, env) do
    case Env.query(env, {"log", cell}, "SELECT n FROM log ORDER BY id") do
      {:ok, %{rows: rows}} -> json(200, %{node: node(), rows: List.flatten(rows)})
      {:error, reason} -> json(500, %{node: node(), error: inspect(reason)})
    end
  end

  def handle_request(%Request{method: "POST", path: "/r/" <> cell, body: body}, env) do
    case Env.execute(env, {"log", cell}, "INSERT INTO log (n) VALUES (?)", [String.to_integer(body)]) do
      {:ok, _} -> json(200, %{node: node()})
      {:error, reason} -> json(409, %{node: node(), error: inspect(reason)})
    end
  end

  def handle_request(_request, _env), do: json(404, %{error: "not_found"})

  defp json(status, term),
    do: %Response{status: status, headers: [{"content-type", "application/json"}], body: Jason.encode!(term)}
end
