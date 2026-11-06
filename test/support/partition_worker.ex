defmodule Atanor.Test.PartitionWorker do
  @moduledoc """
  Test worker for partitioned cells. The namespace `events` is partitioned and
  `/p/KEY` is routed by `KEY`, the partition key, to the logical cell
  `{"events", "stream"}`. `POST /p/KEY` with a number appends `{KEY, number}`
  to the partition cell that holds `KEY` and answers with the node that ran it
  and the physical key; `GET /p/KEY` lists the numbers written for `KEY`;
  `GET /all` counts the rows in each partition, reading across them; `GET /cell/I`
  lists the rows of partition `I` (not routed: it runs on the ingress node).
  """
  @behaviour Atanor.Worker

  alias Atanor.{Env, Request, Response}

  @migrations [[1, "CREATE TABLE log (id INTEGER PRIMARY KEY AUTOINCREMENT, pk TEXT NOT NULL, n INTEGER NOT NULL)"]]
  def migrations, do: @migrations

  @cell {"events", "stream"}

  @impl true
  def route_key(%Request{path: "/p/" <> pk}, _env), do: {:cell, "events", "stream", pk}
  def route_key(_request, _env), do: :none

  @impl true
  def handle_request(%Request{method: "POST", path: "/p/" <> pk, body: body}, env) do
    {:ok, cell} = Env.partition(env, @cell, pk)

    case Env.execute(env, cell, "INSERT INTO log (pk, n) VALUES (?, ?)", [pk, String.to_integer(body)]) do
      {:ok, _} -> json(200, %{node: node(), cell: elem(cell, 1)})
      {:error, reason} -> json(500, %{node: node(), error: inspect(reason)})
    end
  end

  def handle_request(%Request{method: "GET", path: "/p/" <> pk}, env) do
    {:ok, cell} = Env.partition(env, @cell, pk)

    case Env.query(env, cell, "SELECT n FROM log WHERE pk = ? ORDER BY id", [pk]) do
      {:ok, %{rows: rows}} -> json(200, %{node: node(), cell: elem(cell, 1), rows: List.flatten(rows)})
      {:error, reason} -> json(500, %{node: node(), error: inspect(reason)})
    end
  end

  # The rows of partition `I`, read from the ingress (no routing key).
  def handle_request(%Request{method: "GET", path: "/cell/" <> index}, env) do
    {:ok, cells} = Env.partitions(env, @cell)

    case Env.query(env, Enum.at(cells, String.to_integer(index)), "SELECT pk, n FROM log ORDER BY id") do
      {:ok, %{rows: rows}} -> json(200, %{rows: rows})
      {:error, reason} -> json(500, %{error: inspect(reason)})
    end
  end

  def handle_request(%Request{method: "GET", path: "/all"}, env) do
    {:ok, cells} = Env.partitions(env, @cell)

    counts =
      for cell <- cells do
        {:ok, %{rows: [[n]]}} = Env.query(env, cell, "SELECT count(*) FROM log")
        n
      end

    json(200, %{counts: counts})
  end

  def handle_request(_request, _env), do: json(404, %{error: "not_found"})

  # Jobs and alarms are only set in the tests, far in the future, to check where they attach.
  @impl true
  def handle_job(_job, _env), do: :ok

  @impl true
  def handle_alarm(_cell, _payload, _env), do: :ok

  defp json(status, term),
    do: %Response{status: status, headers: [{"content-type", "application/json"}], body: Jason.encode!(term)}
end
