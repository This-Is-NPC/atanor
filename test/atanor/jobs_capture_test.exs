defmodule Atanor.JobsCaptureTest do
  @moduledoc """
  The boundary between Atanor's private tables and Alambique's change feed:
  `Atanor.Config` lists the `_atanor_` prefix as internal, so the tables made
  by `Atanor.Jobs.Schema` get no capture triggers and a wake keeps it so.
  """
  use ExUnit.Case, async: true

  alias Atanor.{Alarms, Cell, Env, Jobs, Registry}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  defp start do
    node = Node.start(workers: [Manifests.jobs("jobs")])
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp triggers(node, key) do
    {:ok, %{rows: rows}} =
      Cell.query(
        node.name,
        {"jobs", key},
        "SELECT tbl_name, name FROM sqlite_schema WHERE type = 'trigger' AND tbl_name LIKE '_atanor_%' ORDER BY tbl_name, name"
      )

    rows
  end

  defp feed(node, key, table) do
    {:ok, %{rows: [[count]]}} =
      Cell.query(node.name, {"jobs", key}, "SELECT count(*) FROM _alambique_feed WHERE tbl = ?", [table])

    count
  end

  test "Atanor tables get no capture triggers, before and after a wake" do
    node = start()
    {:ok, _} = Cell.query(node.name, {"jobs", "a"}, "SELECT 1")

    {:ok, deployment} = Registry.deployment(node.name, "jobs")
    env = Env.new(node.name, deployment)
    assert :ok = Alarms.set(env, {"jobs", "b"}, System.os_time(:millisecond) + 3_600_000, "x")

    assert {:ok, %{rows: [[1]]}} =
             Cell.query(node.name, {"jobs", "b"}, "SELECT count(*) FROM _atanor_alarms")

    assert {:ok, _} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", "a"}, %{kind: "x", payload: "x"})
    assert triggers(node, "a") == []
    assert triggers(node, "b") == []

    {:ok, %{rows: [[id]]}} = Cell.query(node.name, {"jobs", "a"}, "SELECT id FROM _atanor_jobs")

    {:ok, _} =
      Cell.execute(node.name, {"jobs", "a"}, "UPDATE _atanor_jobs SET last_error = 'visible' WHERE id = ?", [id])

    assert feed(node, "a", "_atanor_jobs") == 0

    Cell.hibernate(node.name, {"jobs", "a"})
    {:ok, _} = Cell.query(node.name, {"jobs", "a"}, "SELECT 1")
    {:ok, _} = Cell.query(node.name, {"jobs", "a"}, "SELECT 1")
    assert triggers(node, "a") == []

    # A worker's own table is still captured.
    assert {:ok, %{rows: [[n]]}} =
             Cell.query(
               node.name,
               {"jobs", "a"},
               "SELECT count(*) FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = 'notes'"
             )

    assert n == 3
  end
end
