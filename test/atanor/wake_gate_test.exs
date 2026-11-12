defmodule Atanor.WakeGateTest do
  @moduledoc """
  While the memory gate refuses, a cell call that would wake a cell is refused with `overloaded` and no wake
  starts; the cells that are awake keep answering (design §7.1).
  """
  use ExUnit.Case, async: true

  alias Atanor.{Admission, Cell}
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Node

  @moduletag :tmp_dir

  test "a cold cell is refused over the mark; an awake one is served; both are served again below it", %{
    tmp_dir: dir
  } do
    current = Path.join(dir, "memory.current")
    stat = Path.join(dir, "memory.stat")
    File.write!(current, "100\n")

    node =
      Node.start(
        workers: [Manifests.probe("gate", cells: %{"notes" => Manifests.notes_migrations()})],
        memory: [limit_bytes: 1_000, current_path: current, stat_path: stat, sample_ms: 20]
      )

    on_exit(fn -> Node.stop(node) end)

    awake = {"notes", "awake"}
    cold = {"notes", "cold"}
    sql = "INSERT INTO notes (body) VALUES ('x')"
    assert {:ok, _} = Cell.execute(node.name, awake, sql)

    File.write!(current, "900\n")
    Await.until(fn -> Admission.stats(node.name).refusing end)

    assert {:ok, _} = Cell.execute(node.name, awake, sql)
    assert {:ok, _} = Cell.query(node.name, awake, "SELECT 1")
    assert {:ok, _} = Cell.owner(node.name, awake)

    assert {:error, {:unavailable, :overloaded}} = Cell.execute(node.name, cold, sql)
    assert {:error, {:unavailable, :overloaded}} = Cell.query(node.name, cold, "SELECT 1")
    assert {:error, {:unavailable, :overloaded}} = Cell.owner(node.name, cold)
    assert Admission.stats(node.name).wake_refused == 3
    assert Atanor.Overview.cells_count(node.name).count == 1

    # An admin call is how a node sheds cells: it is not gated.
    assert :ok = Cell.hibernate(node.name, awake)

    File.write!(current, "100\n")
    Await.until(fn -> not Admission.stats(node.name).refusing end)
    assert {:ok, _} = Cell.execute(node.name, cold, sql)
    assert {:ok, _} = Cell.execute(node.name, awake, sql)
  end
end
