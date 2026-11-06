defmodule AtanorLab.Counter do
  @moduledoc """
  `POST /c/CELL` appends the number in the body, with the node that ran the
  handler, to the log of the cell and answers with the row id. `GET /c/CELL`
  lists `[id, n, node]`; `GET /c/CELL?count=1` only counts them. A WebSocket on
  `/c/CELL` does the same with the frames `join`, `w N` and `r`. `GET /c/CELL?count=1&ms=N`
  counts in a bounded request (design §19.3): it runs on the node it reaches, with data up to N ms old. A client that
  records what it was acknowledged can tell afterwards whether a write was lost
  or applied twice.

  The partitioned variant of the hot_cell scenario uses the namespaces `p3`, `p6`
  and `p12` (3, 6 and 12 partitions of the same table), and `/p/N/CELL/KEY` in
  place of `/c/CELL`, with KEY the partition key: POST, `GET ?count=1` and the
  WebSocket do the same on the partition cell of KEY. `GET /p/N/CELL?index=I`
  lists `[id, n, node]` of partition I, for the checker.

  The cursor frames of the hot_cell scenario reach every socket of the cell in
  two ways. `cursor X` goes to the owner, which sends X with `send_to_cell/3`
  (one callback per socket there). `cur X` is published to the cell's ephemeral
  channel by `handle_ws_local/3` on the socket's node, and `jc` joins the channel.
  """
  @behaviour Atanor.Worker

  alias Alambique.Tx
  alias Atanor.{Env, Request, Response}

  @migrations [[1, "CREATE TABLE log (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER NOT NULL, node TEXT NOT NULL)"]]
  def migrations, do: @migrations

  @partitions [3, 6, 12]
  @doc "The numbers of partitions the lab worker offers, one namespace `p<N>` each."
  def partitions, do: @partitions

  @impl true
  def route_key(%Request{method: "GET", path: "/c/" <> cell, query: "count=1&ms=" <> ms}, _env),
    do: {:cell, "log", cell, consistency: {:bounded, String.to_integer(ms)}}

  def route_key(%Request{path: "/c/" <> cell}, _env), do: {:cell, "log", cell}

  def route_key(%Request{path: "/p/" <> rest}, _env) do
    case String.split(rest, "/", parts: 3) do
      [n, cell, key] -> {:cell, "p" <> n, cell, key}
      _ -> :none
    end
  end

  def route_key(_request, _env), do: :none

  @impl true
  def handle_request(%Request{method: "POST", path: "/c/" <> cell, body: body}, env),
    do: reply(append(env, {"log", cell}, String.to_integer(body)))

  def handle_request(%Request{method: "POST", path: "/p/" <> rest, body: body}, env),
    do: reply(append(env, partition_cell(env, rest), String.to_integer(body)))

  def handle_request(%Request{method: "GET", path: "/c/" <> cell, query: "count=1" <> _}, env),
    do: reply(count(env, {"log", cell}))

  def handle_request(%Request{method: "GET", path: "/p/" <> rest, query: "count=1"}, env),
    do: reply(count(env, partition_cell(env, rest)))

  def handle_request(%Request{method: "GET", path: "/c/" <> cell}, env), do: rows(env, {"log", cell})

  def handle_request(%Request{method: "GET", path: "/p/" <> rest, query: "index=" <> index}, env) do
    [n, cell] = String.split(rest, "/", parts: 2)
    {:ok, cells} = Env.partitions(env, {"p" <> n, cell})
    rows(env, Enum.at(cells, String.to_integer(index)))
  end

  defp rows(env, cell) do
    case Env.query(env, cell, "SELECT id, n, node FROM log ORDER BY id") do
      {:ok, %{rows: rows}} -> json(200, %{node: node(), rows: rows})
      {:error, reason} -> json(500, %{node: node(), error: inspect(reason)})
    end
  end

  # `N/CELL/KEY`: the physical cell of the partition key.
  defp partition_cell(env, rest) do
    [n, cell, key] = String.split(rest, "/", parts: 3)
    {:ok, address} = Env.partition(env, {"p" <> n, cell}, key)
    address
  end

  def handle_request(_request, _env), do: json(404, %{error: "not_found"})

  # A WebSocket on `/c/CELL` (the hot_cell scenario): "join" attaches it to the cell, "w N" appends N, "r" counts.
  @impl true
  def ws_init(%Request{path: "/c/" <> cell}, _env), do: {:ok, {"log", cell}}
  def ws_init(%Request{path: "/p/" <> rest}, env), do: {:ok, partition_cell(env, rest)}

  @impl true
  def handle_ws({:text, "join"}, cell, env), do: {:reply, [{:text, inspect(Env.attach(env, cell))}], cell}

  def handle_ws({:text, "w " <> n}, cell, env),
    do: {:reply, [{:text, frame(append(env, cell, String.to_integer(n)))}], cell}

  def handle_ws({:text, "r"}, cell, env), do: {:reply, [{:text, frame(count(env, cell))}], cell}

  def handle_ws({:text, "jc"}, cell, env), do: {:reply, [{:text, inspect(Env.join_channel(env, cell))}], cell}

  def handle_ws({:text, "cursor " <> cursor}, cell, env) do
    :ok = Env.send_to_cell(env, cell, cursor)
    {:ok, cell}
  end

  def handle_ws({:cell_message, cursor}, cell, _env), do: {:reply, [{:text, cursor}], cell}

  @impl true
  def handle_ws_local({:text, "cur " <> cursor}, cell, env) do
    :ok = Env.publish(env, cell, {:text, cursor})
    :drop
  end

  def handle_ws_local(_frame, _cell, _env), do: :pass

  defp append(env, cell, n) do
    result =
      Env.transaction(env, cell, fn tx ->
        {:ok, %{rows: [[id]]}} =
          Tx.query(tx, "INSERT INTO log (n, node) VALUES (?, ?) RETURNING id", [n, Atom.to_string(node())])

        id
      end)

    with {:ok, id} <- result, do: {:ok, %{node: node(), id: id}}
  end

  defp count(env, cell) do
    with {:ok, %{rows: [[count]]}} <- Env.query(env, cell, "SELECT count(*) FROM log"),
         do: {:ok, %{node: node(), count: count}}
  end

  defp reply({:ok, body}), do: json(200, body)
  defp reply({:error, reason}), do: json(500, %{node: node(), error: inspect(reason)})

  defp frame({:ok, body}), do: Jason.encode!(body)
  defp frame({:error, reason}), do: Jason.encode!(%{node: node(), error: inspect(reason)})

  defp json(status, term),
    do: %Response{status: status, headers: [{"content-type", "application/json"}], body: Jason.encode!(term)}
end
