defmodule Atanor.CellLimitsTest do
  @moduledoc "The limits of Alambique reach native and WASM workers as clear errors (design §4.3)."
  use ExUnit.Case, async: true

  import Atanor.Test.WasmCase, only: [request: 4]

  alias Atanor.{Env, Unavailable}
  alias Atanor.Test.{Await, Manifests, WasmCase}
  alias AtanorTestkit.Node

  @notes Manifests.notes_migrations()
  @forever "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
  @alambique [
    op_timeout_ms: 2_000,
    sql: [statement_timeout_ms: 150, max_result_rows: 3],
    awake: [max_cells: 2, max_pending: 2]
  ]

  defp native(alambique \\ @alambique) do
    manifest = Manifests.probe("limits", cells: %{"notes" => @notes})
    node = Node.start(workers: [manifest], alambique: alambique)
    on_exit(fn -> Node.stop(node) end)
    {:ok, deployment} = Atanor.Registry.deployment(node.name, "limits")
    {node, Env.new(node.name, deployment)}
  end

  defp wasm(alambique \\ @alambique) do
    WasmCase.start([{"cell", "cell", cells: %{"notes" => @notes}}], alambique: alambique)
  end

  defp sql(node, op, sql, opts \\ []) do
    headers = [{"x-op", op}, {"x-ns", "notes"}, {"x-key", opts[:key] || "a"}, {"x-params", opts[:params] || ""}]
    request(node, "cell", "", method: :post, body: sql, headers: headers)
  end

  defp fill(env, key \\ "a") do
    for n <- 1..5, do: {:ok, _} = Env.execute(env, {"notes", key}, "INSERT INTO notes (body) VALUES (?)", ["n#{n}"])
  end

  describe "native workers" do
    test "a statement past statement_timeout_ms is :statement_timeout and the cell keeps serving" do
      {_node, env} = native()
      assert {:error, :statement_timeout} = Env.query(env, {"notes", "a"}, @forever)
      assert {:ok, %{rows: [[1]]}} = Env.query(env, {"notes", "a"}, "SELECT 1")
    end

    test "a transaction statement past the deadline returns the error and rolls back" do
      {_node, env} = native()

      assert {:error, :statement_timeout} =
               Env.transaction(env, {"notes", "a"}, fn tx ->
                 {:ok, _} = Alambique.Tx.execute(tx, "INSERT INTO notes (body) VALUES ('x')", [])

                 case Alambique.Tx.query(tx, @forever, []) do
                   {:error, reason} -> Alambique.Tx.rollback(tx, reason)
                   {:ok, _} -> :ok
                 end
               end)

      assert {:ok, %{rows: [[0]]}} = Env.query(env, {"notes", "a"}, "SELECT count(*) FROM notes")
    end

    test "a result over max_result_rows is :result_too_large" do
      {_node, env} = native()
      fill(env)
      assert {:error, :result_too_large} = Env.query(env, {"notes", "a"}, "SELECT body FROM notes")
      assert {:ok, %{rows: [_, _, _]}} = Env.query(env, {"notes", "a"}, "SELECT body FROM notes LIMIT 3")
      assert {:error, :result_too_large} = Env.execute(env, {"notes", "a"}, "UPDATE notes SET body = body RETURNING id")
    end

    test "a wrong number of parameters is {:bad_params, message}, not a crash" do
      {_node, env} = native()
      assert {:error, {:bad_params, message}} = Env.query(env, {"notes", "a"}, "SELECT ?, ?", [1])
      assert is_binary(message)
      assert {:ok, %{rows: [[1]]}} = Env.query(env, {"notes", "a"}, "SELECT 1")
    end

    test "a node at awake max_cells hibernates an idle cell for the new one" do
      {_node, env} = native()
      for key <- ["a", "b", "c"], do: assert({:ok, _} = Env.query(env, {"notes", key}, "SELECT 1"))
    end

    test "a node at awake max_cells with every awake cell busy answers :overloaded" do
      {_node, env} = native(Keyword.put(@alambique, :op_timeout_ms, 10_000))
      parent = self()

      busy =
        for key <- ["a", "b"] do
          Task.async(fn ->
            Env.transaction(env, {"notes", key}, fn _tx ->
              send(parent, {:in_transaction, self()})
              receive do: (:finish -> :ok)
            end)
          end)
        end

      holders =
        for _ <- busy, do: receive(do: ({:in_transaction, holder} -> holder), after: (5_000 -> flunk("no holder")))

      assert {:error, :overloaded} = Env.query(env, {"notes", "c"}, "SELECT 1")
      assert :overloaded = Unavailable.from_error({:error, :overloaded})
      for holder <- holders, do: send(holder, :finish)
      Task.await_many(busy)
      Await.until(fn -> match?({:ok, _}, Env.query(env, {"notes", "c"}, "SELECT 1")) end)
    end

    test "a node at awake max_bytes with every awake cell busy answers :overloaded" do
      {_node, env} =
        native(Keyword.merge(@alambique, awake: [max_bytes: 1], op_timeout_ms: 10_000))

      assert {:ok, _} = Env.query(env, {"notes", "a"}, "SELECT 1")
      parent = self()

      busy =
        Task.async(fn ->
          Env.transaction(env, {"notes", "a"}, fn _tx ->
            send(parent, {:in_transaction, self()})
            receive do: (:finish -> :ok)
          end)
        end)

      assert_receive {:in_transaction, holder}
      assert {:error, :overloaded} = Env.query(env, {"notes", "b"}, "SELECT 1")
      send(holder, :finish)
      # The router reads the busy cell's counters; it does not call it.
      Task.await(busy)
      Await.until(fn -> match?({:ok, _}, Env.query(env, {"notes", "b"}, "SELECT 1")) end)
    end

    test "a cell with more calls waiting than awake max_pending answers :busy" do
      {_node, env} = native(Keyword.put(@alambique, :sql, statement_timeout_ms: 8_000))
      assert {:ok, _} = Env.query(env, {"notes", "a"}, "SELECT 1")

      slow =
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 400000) INSERT INTO notes (body) SELECT x FROM c"

      first = Task.async(fn -> Env.execute(env, {"notes", "a"}, slow) end)
      Process.sleep(20)

      results =
        1..8
        |> Task.async_stream(fn _ -> Env.execute(env, {"notes", "a"}, "INSERT INTO notes (body) VALUES ('q')") end,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert {:error, :busy} in results
      assert {:ok, _} = Task.await(first, 10_000)
      assert :overloaded = Unavailable.from_error({:error, :busy})
    end
  end

  describe "WASM workers" do
    test "limits arrive as failed(\"<code>: <text>\")" do
      node = wasm()
      assert %{status: 500, body: "failed: statement_timeout: " <> _} = sql(node, "query", @forever)

      for n <- 1..5, do: assert(%{status: 200} = sql(node, "execute", "INSERT INTO notes (body) VALUES ('#{n}')"))
      assert %{status: 500, body: "failed: result_too_large: " <> _} = sql(node, "query", "SELECT body FROM notes")

      assert %{status: 500, body: "failed: bad_params: " <> _} = sql(node, "query", "SELECT ?, ?", params: "x")

      assert %{status: 500, body: "failed: statement_timeout: " <> _} =
               sql(node, "batch", "INSERT INTO notes (body) VALUES ('z')\n" <> @forever)

      assert %{status: 200, body: "[count(*)] 5"} = sql(node, "query", "SELECT count(*) FROM notes")
    end

    test "a batch whose results pass wasm max_batch_bytes fails and applies nothing" do
      node = WasmCase.start([{"cell", "cell", cells: %{"notes" => @notes}}], wasm: [max_batch_bytes: 55])
      two = "SELECT '#{String.duplicate("x", 12)}'\nSELECT '#{String.duplicate("y", 12)}'"
      three = two <> "\nINSERT INTO notes (body) VALUES ('z')\nSELECT 'w'"

      assert %{status: 200} = sql(node, "batch", two)
      assert %{status: 500, body: "failed: batch_too_large: " <> _} = sql(node, "batch", three)
      assert %{status: 200, body: "[count(*)] 0"} = sql(node, "query", "SELECT count(*) FROM notes")
    end

    test "a node at awake max_cells serves another cell by hibernating an idle one" do
      node = wasm()
      for key <- ["a", "b", "c", "a"], do: assert(%{status: 200} = sql(node, "query", "SELECT 1", key: key))
    end
  end
end
