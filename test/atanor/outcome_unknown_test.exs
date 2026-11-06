defmodule Atanor.OutcomeUnknownTest do
  @moduledoc """
  A write whose batch was sent for upload when its cell stopped may be durable, so it is an unknown
  outcome and never a definite refusal (property P4).
  """
  use ExUnit.Case, async: false

  alias Atanor.Cell
  alias Atanor.Test.Manifests
  alias AlambiqueTestkit.{GatedStore, ManualClock, MemoryStore}
  alias AtanorTestkit.Node

  @moduletag capture_log: true
  @insert "INSERT INTO t (n) VALUES (?)"

  defp until(fun, left \\ 200) do
    cond do
      fun.() -> true
      left == 0 -> false
      true -> Process.sleep(25) && until(fun, left - 1)
    end
  end

  test "a write held in the upload when the lease expires is unknown, not fenced" do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, _} = start_supervised({MemoryStore, name: name})
    {:ok, gate} = GatedStore.start_link()
    store = GatedStore.wrap(gate, {MemoryStore, MemoryStore.config(name)})

    cells = %{"t" => [[1, "CREATE TABLE t (n INTEGER PRIMARY KEY)"]]}
    world = ManualClock.new(1_800_000_000_000)

    node =
      Node.start(
        store: store,
        workers: [Manifests.probe("w", cells: cells)],
        alambique: [lease_ttl_ms: 60_000, clock: {ManualClock, ManualClock.config(world, 0)}]
      )

    on_exit(fn -> Node.stop(node) end)
    assert {:ok, _} = Cell.execute(node.name, {"t", "a"}, @insert, [0])

    # The batch of the next write is sent and stays in the upload while the lease runs out.
    :ok = GatedStore.hold(gate, ~r{/t\.a/.*\.ltx})

    write =
      Task.async(fn ->
        Cell.clear_unknown()
        Cell.clear_unavailable()
        answer = Cell.execute(node.name, {"t", "a"}, @insert, [1], timeout: 20_000)
        {answer, Cell.unknown_outcome?(), Cell.unavailable_reason()}
      end)

    assert until(fn -> GatedStore.held(gate) != [] end)
    ManualClock.advance(world, 61_000)
    assert {:error, :lease_expired} = Cell.query(node.name, {"t", "a"}, "SELECT 1")

    assert {{:error, :outcome_unknown}, true, nil} = Task.await(write, 10_000)
  end

  test "a handler whose later write is refused after an earlier one was acknowledged is unknown" do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, _} = start_supervised({MemoryStore, name: name})
    world = ManualClock.new(1_800_000_000_000)

    node =
      Node.start(
        store: {MemoryStore, MemoryStore.config(name)},
        workers: [Manifests.probe("w", cells: %{"t" => [[1, "CREATE TABLE t (n INTEGER PRIMARY KEY)"]]})],
        alambique: [lease_ttl_ms: 60_000, clock: {ManualClock, ManualClock.config(world, 0)}]
      )

    on_exit(fn -> Node.stop(node) end)

    handler = fn first_cell ->
      Task.async(fn ->
        Cell.clear_unknown()
        Cell.clear_unavailable()
        {:ok, _} = Cell.execute(node.name, {"t", first_cell}, @insert, [1])
        ManualClock.advance(world, 61_000)
        answer = Cell.execute(node.name, {"t", first_cell}, @insert, [2])
        {answer, Cell.unknown_outcome?()}
      end)
      |> Task.await(10_000)
    end

    assert {{:error, reason}, true} = handler.("a")
    assert reason in [:lease_expired, :lease_lost, :fenced]
  end

  test "a guest is told the write may be applied" do
    assert {:error, :failed, "unknown_outcome: " <> _} = Atanor.Wasm.Host.error({:error, :outcome_unknown})
  end
end
