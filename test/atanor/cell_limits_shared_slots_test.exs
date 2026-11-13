defmodule Atanor.CellLimitsSharedSlotsTest do
  @moduledoc """
  `sql.max_concurrent_statements` counts the user statements of the whole VM, not
  of one node (design §7). A module that sets it to 1 must run alone: an async
  module's statement would hold the only slot and refuse the first read.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.WasmCase, only: [request: 4]

  alias Atanor.{Env, Unavailable}
  alias Atanor.Test.{Await, Manifests, WasmCase}
  alias AtanorTestkit.Node

  @notes Manifests.notes_migrations()
  @forever "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
  @one [op_timeout_ms: 5_000, sql: [statement_timeout_ms: 1_500, max_concurrent_statements: 1]]

  defp wasm, do: WasmCase.start([{"cell", "cell", cells: %{"notes" => @notes}}], alambique: @one)

  def report(_event, _measurements, meta, test), do: send(test, {:reject, meta})

  defp sql(node, op, sql, key) do
    headers = [{"x-op", op}, {"x-ns", "notes"}, {"x-key", key}, {"x-params", ""}]
    request(node, "cell", "", method: :post, body: sql, headers: headers)
  end

  test "a read over sql max_concurrent_statements is a 503 overloaded" do
    node = wasm()
    ref = make_ref()

    :telemetry.attach(
      {__MODULE__, ref},
      [:atanor, :http, :reject],
      &__MODULE__.report/4,
      self()
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    assert %{status: 200} = sql(node, "query", "SELECT 1", "b")
    slow = Task.async(fn -> sql(node, "query", @forever, "a") end)

    Await.until(fn ->
      match?(%{status: 503, body: %{"error" => "overloaded", "reason" => "busy"}}, sql(node, "query", "SELECT 1", "b"))
    end)

    assert_received {:reject, %{reason: :busy, status: 503}}
    assert %{status: 500, body: "failed: statement_timeout: " <> _} = Task.await(slow, 10_000)
    Await.until(fn -> match?(%{status: 200}, sql(node, "query", "SELECT 1", "b")) end)
  end

  test "a statement of another node in the VM holds the slot of this one" do
    node = wasm()
    other = Node.start(workers: [Manifests.probe("other", cells: %{"notes" => @notes})], alambique: @one)
    on_exit(fn -> Node.stop(other) end)
    {:ok, deployment} = Atanor.Registry.deployment(other.name, "other")
    env = Env.new(other.name, deployment)

    holder = Task.async(fn -> Env.query(env, {"notes", "a"}, @forever) end)

    Await.until(fn ->
      match?(%{status: 503, body: %{"error" => "overloaded", "reason" => "busy"}}, sql(node, "query", "SELECT 1", "b"))
    end)

    assert {:error, :statement_timeout} = Task.await(holder, 10_000)
    assert :overloaded = Unavailable.from_error({:error, :busy})
    Await.until(fn -> match?(%{status: 200}, sql(node, "query", "SELECT 1", "b")) end)
  end
end
