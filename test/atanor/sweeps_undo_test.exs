defmodule Atanor.SweepsUndoTest do
  @moduledoc """
  Positions and the undo report of bulk operations (design §15.9, §15.10): the
  position row shares the job's transaction, and the report compares restored
  copies without touching a live cell.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.Await

  alias Atanor.{Cell, Config, Store, Sweeps}
  alias Atanor.Sweeps.Undo
  alias Atanor.Test.Manifests
  alias AlambiqueTestkit.{ManualClock, MemoryStore}
  alias AtanorTestkit.Node

  @start 1_000_000_000_000
  @token "undo-token"
  @position "SELECT before_txid, before_at_ms, job_id FROM _atanor_undo WHERE operation_id = ?"

  defp start(opts \\ []) do
    world = ManualClock.new(@start)

    sweeps =
      Keyword.merge(
        [
          poll_ms: 50,
          lease_ttl_ms: 2_000,
          renew_ms: 500,
          cell_timeout_ms: 1_000,
          page_size: 2,
          rate_per_s: 100,
          concurrency: 2,
          max_active: 2,
          cell_attempts: 1,
          retry_ms: 10,
          reread_ms: 100,
          undo_timeout_ms: 20_000
        ],
        opts[:sweeps] || []
      )

    alarms = [clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 20]

    node =
      Node.start(
        workers: [Manifests.jobs("jobs", cells: %{"jobs" => Atanor.Test.JobWorker.migrations(), "bare" => []})],
        alambique: opts[:alambique] || [],
        alarms: alarms,
        sweeps: sweeps,
        poll_interval_ms: 100,
        admin: [token: @token, port: 0]
      )

    on_exit(fn -> Node.stop(node) end)
    Process.put({__MODULE__, node.name}, world)
    node
  end

  # Under the stopped clock the alarm scan checks the cells of finished jobs at every tick and wakes them. A
  # minute later it deletes the entries, and the cells stay asleep.
  defp calm(node) do
    ManualClock.advance(Process.get({__MODULE__, node.name}), 120_000)
    {mod, config} = node.store

    until(fn ->
      {:ok, keys, _} = mod.list(config, "", nil, 1_000)
      not Enum.any?(keys, &String.contains?(&1, "/alarms/0"))
    end)
  end

  defp alambique(node), do: Module.concat(node.name, Cells)

  # Writes rows into the cells, then lets them sleep with their data in the store.
  defp seed(node, keys, rows \\ 2) do
    for key <- keys do
      for n <- 1..rows,
          do: {:ok, _} = Cell.execute(node.name, {"jobs", key}, "INSERT INTO notes (body) VALUES (?)", ["seed #{n}"])

      :ok = Alambique.hibernate(alambique(node), "jobs." <> key)
    end
  end

  defp operation(node, attrs \\ %{}) do
    base = %{
      "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
      "action" => %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("swept")}
    }

    {:ok, op} = Sweeps.start(node.name, Map.merge(base, attrs))
    op
  end

  defp record(node, id) do
    {:ok, record, _etag} = Sweeps.get(node.name, id)
    record
  end

  defp finished(node, op) do
    until(fn -> record(node, op["id"])["state"] == "done" end)

    for key <- jobs_keys(node) do
      until(fn ->
        match?(
          {:ok, %{rows: [["done"]]}},
          Cell.query(node.name, {"jobs", key}, "SELECT state FROM _atanor_jobs WHERE operation_id = ?", [op["id"]])
        )
      end)
    end

    record(node, op["id"])
  end

  defp jobs_keys(node) do
    {:ok, %{cells: ids}} = Alambique.list_cells(alambique(node), prefix: "jobs.", limit: 100)
    for "jobs." <> key <- ids, do: key
  end

  defp sleep(node, keys), do: for(key <- keys, do: :ok = Alambique.hibernate(alambique(node), "jobs." <> key))

  defp positions(node, key, id) do
    {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", key}, @position, [id])
    rows
  end

  defp report(node, id) do
    {:ok, started} = Undo.start(node.name, id)
    assert started["state"] == "running"
    until(fn -> (r = get_report(node, id))["state"] != "running" && r end, 30_000)
  end

  defp get_report(node, id) do
    {:ok, report} = Undo.get(node.name, id)
    report
  end

  defp cells(report), do: Map.new(report["cells"], &{&1["cell"], &1})
  defp table(entry, name), do: Enum.find(entry["tables"] ++ entry["host_tables"], &(&1["name"] == name))

  defp request(node, method, path, body \\ nil) do
    Req.request!(
      method: method,
      url: "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path,
      headers: [{"authorization", "Bearer " <> @token}, {"content-type", "application/json"}],
      body: body,
      retry: false,
      decode_body: false
    )
  end

  describe "positions" do
    test "_atanor_undo is created only for an undoable operation, with the position of the job" do
      node = start()
      seed(node, ~w(a b))

      plain = operation(node)
      finished(node, plain)

      for key <- ~w(a b) do
        assert {:ok, %{rows: []}} =
                 Cell.query(node.name, {"jobs", key}, "SELECT 1 FROM sqlite_master WHERE name = '_atanor_undo'")
      end

      assert %{"undo" => %{"enabled" => false, "positions" => 0}} = record(node, plain["id"])

      undoable = operation(node, %{"undo" => true})
      done = finished(node, undoable)
      assert %{"enabled" => true, "positions" => 2} = done["undo"]

      for key <- ~w(a b) do
        assert [[before_txid, before_at_ms, job_id]] = positions(node, key, undoable["id"])
        assert is_integer(before_txid) and before_txid >= 1
        assert before_at_ms == @start

        assert {:ok, %{rows: [[^job_id]]}} =
                 Cell.query(node.name, {"jobs", key}, "SELECT id FROM _atanor_jobs WHERE operation_id = ?", [
                   undoable["id"]
                 ])
      end
    end

    test "the instance default turns positions on and an operation may turn them off" do
      node = start(sweeps: [undo: true])
      seed(node, ~w(a))

      assert %{"undo" => %{"enabled" => true}} = operation(node)
      assert %{"undo" => %{"enabled" => false}} = operation(node, %{"undo" => false})
      assert_raise ArgumentError, ~r/undo must be a boolean/, fn -> operation(node, %{"undo" => "yes"}) end
    end

    @tag :capture_log
    test "a cell with no data records the batch before the operation, and 0 restores an empty database" do
      node = start()
      # A namespace without migrations. Waking the cell commits its initial batch (txid 1),
      # so the operation's transaction is txid 2 and the position is 1.
      {:ok, _} = Cell.query(node.name, {"bare", "fresh"}, "SELECT 1")
      selector = %{"kind" => "namespace", "namespace" => "bare"}
      op = operation(node, %{"undo" => true, "selector" => selector})
      until(fn -> record(node, op["id"])["state"] == "done" end)
      assert {:ok, %{rows: [[1, _, _]]}} = Cell.query(node.name, {"bare", "fresh"}, @position, [op["id"]])

      # Position 0 is what a cell records when the operation is its very first batch.
      {:ok, _} = Cell.execute(node.name, {"bare", "fresh"}, "UPDATE _atanor_undo SET before_txid = 0")
      :ok = Alambique.hibernate(alambique(node), "bare.fresh")

      report = report(node, op["id"])

      assert %{"restorable" => true, "before_txid" => 0, "tables" => [], "host_tables" => host} =
               cells(report)["bare.fresh"]

      assert ["_atanor_alarms", "_atanor_jobs", "_atanor_undo"] = Enum.map(host, & &1["name"])
      assert Enum.all?(host, &(&1["before"] == nil and &1["changed"]))
    end

    test "a replay finds the operation marker and adds no second position" do
      node = start()
      seed(node, ~w(a b))
      op = operation(node, %{"undo" => true})
      finished(node, op)

      # Run the operation again from its first cell.
      {:ok, stored, etag} = Sweeps.get(node.name, op["id"])
      body = Jason.encode!(%{stored | "state" => "running", "cursor" => nil})
      assert {:ok, _} = Store.put(node.name, "operations/" <> op["id"], body, {:if_match, etag})

      until(fn ->
        r = record(node, op["id"])
        r["state"] == "done" and r["counters"]["skipped"] == 2
      end)

      for key <- ~w(a b), do: assert([_one] = positions(node, key, op["id"]))
    end

    test "a failed position insert rolls back the job" do
      node = start()
      seed(node, ~w(a))
      # A table of that name without the columns makes the insert fail.
      {:ok, _} = Cell.execute(node.name, {"jobs", "a"}, "CREATE TABLE _atanor_undo (x)")

      op = operation(node, %{"undo" => true})
      until(fn -> record(node, op["id"])["last_error"] != nil end)

      # The job tables, created in the same transaction, are gone too.
      assert {:ok, %{rows: [[0]]}} =
               Cell.query(node.name, {"jobs", "a"}, "SELECT count(*) FROM sqlite_master WHERE name = '_atanor_jobs'")

      assert {:ok, _} = Sweeps.cancel(node.name, op["id"])
    end

    test "the position rows stay out of Alambique's feed" do
      node = start(alambique: [feed: [window_ms: 1, linger_ms: 0], op_timeout_ms: 10, skew_margin_ms: 0])
      seed(node, ~w(a))
      op = operation(node, %{"undo" => true})
      finished(node, op)

      # The worker's own rows are in the feed once it has settled; the position rows never are.
      records =
        until(fn ->
          {:ok, records, _next} = Atanor.Feed.read_records(node.name, nil, 1_000)
          Enum.any?(records, &(&1.table == "notes")) && records
        end)

      refute Enum.any?(records, &String.starts_with?(&1.table, "_atanor_"))
    end
  end

  describe "report" do
    test "restores at the position and sees what was written after the operation" do
      node = start()
      seed(node, ~w(a b c))
      op = operation(node, %{"undo" => true})
      finished(node, op)

      # After the operation: one more note in a, a new column in b, c untouched.
      {:ok, _} = Cell.execute(node.name, {"jobs", "a"}, "INSERT INTO notes (body) VALUES ('after')")
      {:ok, _} = Cell.execute(node.name, {"jobs", "b"}, "ALTER TABLE notes ADD COLUMN tag TEXT")
      {:ok, _} = Cell.query(node.name, {"jobs", "late"}, "SELECT 1")
      sleep(node, ~w(a b c late))

      report = report(node, op["id"])

      assert %{"state" => "done", "mode" => "report", "error" => nil} = report
      assert String.starts_with?(report["undo_id"], "u-")

      assert %{
               "cells" => 4,
               "with_position" => 3,
               "restorable" => 3,
               "unrestorable" => 0,
               "pending_jobs" => 0,
               "truncated" => false
             } = report["summary"]

      cells = cells(report)
      refute Map.has_key?(cells, "jobs.late")
      assert %{"restorable" => true, "job_state" => "done", "frozen" => false, "error" => nil} = cells["jobs.a"]
      assert cells["jobs.a"]["before_txid"] < cells["jobs.a"]["current_txid"]

      assert %{"before" => 2, "current" => 3, "changed" => true} = table(cells["jobs.a"], "notes")
      assert %{"before" => 0, "current" => 1, "changed" => true} = table(cells["jobs.a"], "effects")
      assert %{"before" => nil, "current" => 1} = table(cells["jobs.a"], "_atanor_jobs")
      assert %{"before" => nil, "current" => 1} = table(cells["jobs.a"], "_atanor_undo")
      assert cells["jobs.a"]["schema_changed"] == false

      assert %{"before" => 2, "current" => 2, "changed" => true} = table(cells["jobs.b"], "notes")
      assert cells["jobs.b"]["schema_changed"] == true

      assert %{"before" => 2, "current" => 2, "changed" => false} = table(cells["jobs.c"], "notes")
      assert cells["jobs.c"]["schema_changed"] == false

      assert {:ok, body, _, _} = Store.get(node.name, "undos/" <> op["id"])
      assert Jason.decode!(body)["summary"] == report["summary"]
      assert get_report(node, op["id"]) == report
    end

    test "a cell the history of which was deleted is unrestorable and the report completes" do
      node = start()
      seed(node, ~w(a b))
      op = operation(node, %{"undo" => true})
      finished(node, op)
      # b stays awake: the live cell still has its data and its position.
      sleep(node, ~w(a))

      {mod, config} = node.store
      {:ok, keys, _} = mod.list(config, "", nil, 1_000)
      # The history, not the lease: a verified read of the live cell would find the lease gone and reload the cell.
      history =
        for key <- keys, String.contains?(key, "/cells/cells/jobs.b/"), not String.ends_with?(key, "/lease"), do: key

      for key <- history, do: :ok = mod.delete(config, key)
      # The alarm scan reads cells with a verified lease: the cell must keep serving its data.
      verified = Cell.query(node.name, {"jobs", "b"}, "SELECT count(*) FROM _atanor_undo", [], verify_lease: true)
      assert {:ok, %{rows: [[1]]}} = verified

      report = report(node, op["id"])

      assert report["state"] == "done"
      assert %{"with_position" => 2, "restorable" => 1, "unrestorable" => 1} = report["summary"]
      assert %{"restorable" => true} = cells(report)["jobs.a"]
      assert %{"restorable" => false, "error" => %{"stage" => stage, "message" => message}} = cells(report)["jobs.b"]
      assert stage in ["before", "latest"]
      assert is_binary(message) and message != ""
    end

    test "the temporary copies are removed after a report and after a failed one" do
      node = start()
      seed(node, ~w(a))
      op = operation(node, %{"undo" => true})
      finished(node, op)
      sleep(node, ~w(a))

      assert report(node, op["id"])["state"] == "done"
      until(fn -> File.ls!(Path.join(node.data_dir, "undos")) == [] end)

      # A target that cannot be listed fails the report, not the node.
      {:ok, stored, etag} = Sweeps.get(node.name, op["id"])
      broken = put_in(stored, ["selector"], %{"kind" => "nonsense"})
      assert {:ok, _} = Store.put(node.name, "operations/" <> op["id"], Jason.encode!(broken), {:if_match, etag})

      failed = report(node, op["id"])
      assert %{"state" => "failed", "error" => %{"message" => message}} = failed
      assert message =~ "listing the target cells failed"
      until(fn -> File.ls!(Path.join(node.data_dir, "undos")) == [] end)
    end

    test "only an operation with positions has a report" do
      node = start()
      seed(node, ~w(a))
      op = operation(node)
      finished(node, op)

      assert {:error, :undo_not_enabled} = Undo.start(node.name, op["id"])
      assert {:error, :not_found} = Undo.start(node.name, "nosuchoperation")
      assert {:error, :not_found} = Undo.start(node.name, "../x")
      assert {:error, :not_found} = Undo.get(node.name, op["id"])
    end

    test "max_cells keeps the first reports and says so" do
      node = start(sweeps: [undo_max_cells: 1, page_size: 1])
      seed(node, ~w(a b c))
      op = operation(node, %{"undo" => true})
      finished(node, op)
      sleep(node, ~w(a b c))

      report = report(node, op["id"])
      assert %{"with_position" => 1, "truncated" => true} = report["summary"]
      assert [%{"cell" => "jobs.a"}] = report["cells"]
    end

    test "a restore that outlives its budget is unrestorable and leaves the live cell alone" do
      node = start(sweeps: [undo_timeout_ms: 300])
      seed(node, ~w(a b))
      op = operation(node, %{"undo" => true})
      finished(node, op)
      sleep(node, ~w(a b))

      {MemoryStore, store} = node.store

      fault =
        MemoryStore.inject(store,
          kind: :latency,
          ms: 5_000,
          key: ~r{/cells/cells/jobs\.a/},
          ops: [:get, :get_range, :list]
        )

      on_exit(fn -> MemoryStore.clear(store) end)

      {:ok, _} = Undo.start(node.name, op["id"])
      # A report still running blocks a second one.
      assert {:error, :already_running} = Undo.start(node.name, op["id"])
      report = until(fn -> (r = get_report(node, op["id"]))["state"] != "running" && r end, 30_000)
      MemoryStore.remove(store, fault)

      assert report["state"] == "done"
      assert %{"restorable" => false, "error" => %{"stage" => "timeout"}} = cells(report)["jobs.a"]
      assert %{"restorable" => true} = cells(report)["jobs.b"]
      assert %{"restorable" => 1, "unrestorable" => 1} = report["summary"] |> Map.take(["restorable", "unrestorable"])

      # The live cell still serves, with its data, and was never frozen.
      assert {:ok, %{rows: [[2]]}} = Cell.query(node.name, {"jobs", "a"}, "SELECT count(*) FROM notes")
      assert [[_, _, _]] = positions(node, "a", op["id"])
      assert {:ok, false} = Alambique.frozen?(alambique(node), "jobs.a")
      until(fn -> File.ls!(Path.join(node.data_dir, "undos")) == [] end)
    end

    test "a stale running report is read as stale and can be replaced" do
      node = start(sweeps: [undo_stale_ms: 1_000])
      seed(node, ~w(a))
      op = operation(node, %{"undo" => true})
      finished(node, op)

      {:ok, started} = Undo.start(node.name, op["id"])
      until(fn -> get_report(node, op["id"])["state"] == "done" end, 30_000)

      stale = %{started | "updated_at_ms" => 0, "state" => "running"}
      assert {:ok, _} = Store.put(node.name, "undos/" <> op["id"], Jason.encode!(stale))
      assert %{"state" => "stale"} = get_report(node, op["id"])
      assert report(node, op["id"])["state"] == "done"
    end

    test "the report is removed with its operation after the retention" do
      node = start()
      seed(node, ~w(a))
      op = operation(node, %{"undo" => true})
      finished(node, op)
      assert report(node, op["id"])["state"] == "done"

      {:ok, stored, etag} = Sweeps.get(node.name, op["id"])
      old = Jason.encode!(%{stored | "updated_at_ms" => 0})
      assert {:ok, _} = Store.put(node.name, "operations/" <> op["id"], old, {:if_match, etag})

      until(fn -> match?({:error, :not_found}, Store.get(node.name, "operations/" <> op["id"])) end)
      assert {:error, :not_found} = Undo.get(node.name, op["id"])
    end
  end

  describe "admin API" do
    test "POST starts a report and GET returns it" do
      node = start()
      seed(node, ~w(a))
      op = operation(node, %{"undo" => true})
      finished(node, op)
      sleep(node, ~w(a))
      path = "/operations/#{op["id"]}/undo"

      assert request(node, :get, path).status == 404

      response = request(node, :post, path, Jason.encode!(%{"mode" => "report"}))
      assert response.status == 202
      assert %{"undo_id" => "u-" <> _, "state" => "running"} = Jason.decode!(response.body)

      report =
        until(fn ->
          body = Jason.decode!(request(node, :get, path).body)
          body["state"] == "done" && body
        end)

      assert report["summary"]["restorable"] == 1
      assert %{"jobs.a" => %{"restorable" => true}} = cells(report)
      assert request(node, :post, path, "{}").status == 202
    end

    test "mode apply needs a report and other modes are invalid" do
      node = start()
      seed(node, ~w(a))
      op = operation(node, %{"undo" => true})
      finished(node, op)
      path = "/operations/#{op["id"]}/undo"

      response = request(node, :post, path, Jason.encode!(%{"mode" => "apply"}))
      assert {409, %{"error" => "report_required"}} = {response.status, Jason.decode!(response.body)}
      assert {:error, :not_found} = Undo.get(node.name, op["id"])

      response = request(node, :post, path, Jason.encode!(%{"mode" => "rewind"}))
      assert {400, %{"error" => "invalid_mode"}} = {response.status, Jason.decode!(response.body)}
      assert request(node, :post, path, "not json").status == 400
    end

    test "an unknown operation is 404 and one without positions is 409" do
      node = start()
      seed(node, ~w(a))
      op = operation(node)
      finished(node, op)

      assert request(node, :post, "/operations/nosuchoperation/undo", "{}").status == 404

      response = request(node, :post, "/operations/#{op["id"]}/undo", "{}")
      assert {409, %{"error" => "undo_not_enabled"}} = {response.status, Jason.decode!(response.body)}
    end

    test "the endpoints need the token" do
      node = start()
      url = "http://127.0.0.1:#{Atanor.admin_port(node.name)}/operations/x/undo"

      assert Req.get!(url, retry: false).status == 401
      assert Req.post!(url, body: "{}", retry: false).status == 401
    end
  end

  describe "apply" do
    defp count(node, key, table) do
      {:ok, %{rows: [[n]]}} = Cell.query(node.name, {"jobs", key}, "SELECT count(*) FROM #{table}")
      n
    end

    defp apply_undo(node, id) do
      {:ok, started} = Undo.rewind(node.name, id)
      assert %{"mode" => "apply", "state" => "running"} = started
      until(fn -> (r = get_report(node, id))["state"] != "running" && r end, 30_000)
    end

    # An operation over cells a, b and c that ends with their data in the store.
    defp reported(keys \\ ~w(a b c), opts \\ []) do
      node = start(opts)
      seed(node, keys)
      op = operation(node, %{"undo" => true})
      finished(node, op)
      calm(node)
      {node, op}
    end

    test "rewinds the cells to the position before the operation and keeps the internal tables" do
      {node, op} = reported()
      # After the operation: more notes in a and b. The note written just before the operation stays.
      for key <- ~w(a b),
          do: {:ok, _} = Cell.execute(node.name, {"jobs", key}, "INSERT INTO notes (body) VALUES ('later')")

      sleep(node, ~w(a b c))
      assert report(node, op["id"])["state"] == "done"
      sleep(node, ~w(a b c))

      done = apply_undo(node, op["id"])

      assert %{"mode" => "apply", "state" => "done", "error" => nil} = done
      assert %{"rewound" => 3, "data_written" => 0, "failed" => 0, "unknown" => 0, "waiting" => 0} = done["summary"]

      for entry <- done["cells"] do
        assert %{"state" => "rewound", "to" => to, "from" => from, "txid" => txid, "kept" => kept} = entry["apply"]
        assert to == entry["before_txid"] and from >= entry["head_txid"] and txid == from + 1
        assert "_atanor_jobs" in kept and "_atanor_undo" in kept
      end

      for key <- ~w(a b c) do
        # Seeds only: the operation's effect and the later note are gone.
        assert count(node, key, "notes") == 2
        assert count(node, key, "effects") == 0
        # The job and its position stay, so the operation is not run again.
        assert [[_, _, _]] = positions(node, key, op["id"])

        assert {:ok, %{rows: [["done"]]}} =
                 Cell.query(node.name, {"jobs", key}, "SELECT state FROM _atanor_jobs WHERE operation_id = ?", [
                   op["id"]
                 ])
      end

      assert get_report(node, op["id"]) == done
    end

    test "excludes exactly the operation: what was written just before it stays" do
      node = start()
      seed(node, ~w(a))
      # Awake, with a write that no upload separates from the operation.
      {:ok, _} = Cell.execute(node.name, {"jobs", "a"}, "INSERT INTO notes (body) VALUES ('just before')")
      op = operation(node, %{"undo" => true})
      finished(node, op)
      calm(node)
      sleep(node, ~w(a))
      assert report(node, op["id"])["state"] == "done"
      sleep(node, ~w(a))

      assert %{"summary" => %{"rewound" => 1}} = apply_undo(node, op["id"])
      assert count(node, "a", "notes") == 3
      assert count(node, "a", "effects") == 0
    end

    test "a cell written since the report is reported and left alone" do
      {node, op} = reported()
      sleep(node, ~w(a b c))
      assert report(node, op["id"])["state"] == "done"
      {:ok, _} = Cell.execute(node.name, {"jobs", "b"}, "INSERT INTO notes (body) VALUES ('after the report')")
      sleep(node, ~w(a b c))

      done = apply_undo(node, op["id"])

      assert %{"state" => "done", "summary" => %{"rewound" => 2, "data_written" => 1}} = done
      assert %{"apply" => %{"state" => "data_written", "data" => data, "expected" => expected}} = cells(done)["jobs.b"]
      assert data > expected
      assert count(node, "b", "notes") == 3
      assert count(node, "b", "effects") == 1
      assert count(node, "a", "effects") == 0

      # A new report sees the cells that were rewound as done and reads b again at its new head.
      report = report(node, op["id"])
      assert %{"apply" => %{"state" => "rewound"}} = cells(report)["jobs.a"]
      assert cells(report)["jobs.b"]["head_txid"] >= data
      refute Map.has_key?(cells(report)["jobs.b"], "apply")
      sleep(node, ~w(a b c))

      assert %{"summary" => %{"rewound" => 3}} = apply_undo(node, op["id"])
      assert count(node, "b", "notes") == 2
      assert count(node, "a", "notes") == 2
    end

    test "a cell that was only woken since the report is rewound" do
      {node, op} = reported(~w(a b))
      sleep(node, ~w(a b))
      report = report(node, op["id"])
      assert report["state"] == "done"
      sleep(node, ~w(a b))

      # Waking a cell commits an empty fence segment: TXID and epoch move, the data TXID does not.
      for key <- ~w(a b) do
        address = {"jobs", key}
        reported_head = cells(report)["jobs." <> key]["head_txid"]
        {:ok, _} = Cell.query(node.name, address, "SELECT 1")
        assert {:ok, %{awake: true} = first} = Cell.position(node.name, address)
        sleep(node, [key])
        {:ok, _} = Cell.query(node.name, address, "SELECT 1")
        assert {:ok, %{awake: true} = second} = Cell.position(node.name, address)

        assert second.txid > first.txid and second.epoch > first.epoch
        assert first.txid > reported_head
        assert second.data == first.data and second.data <= reported_head
      end

      sleep(node, ~w(a b))
      done = apply_undo(node, op["id"])

      assert %{"summary" => %{"rewound" => 2, "data_written" => 0}} = done
      assert count(node, "a", "effects") == 0
      assert count(node, "b", "effects") == 0
    end

    test "a cell that may be rewound already is not rewound a second time" do
      {node, op} = reported(~w(a b))
      sleep(node, ~w(a b))
      assert report(node, op["id"])["state"] == "done"
      sleep(node, ~w(a b))
      done = apply_undo(node, op["id"])
      assert done["summary"]["rewound"] == 2

      # The node died after the rewind of a landed and before its answer was stored.
      # A rewind counts as data, so the cell reads as written since the report.

      marked =
        Enum.map(
          done["cells"],
          &if(&1["cell"] == "jobs.a", do: Map.put(&1, "apply", %{"state" => "rewinding"}), else: &1)
        )

      lost = %{done | "state" => "running", "updated_at_ms" => 0, "cells" => marked}
      assert {:ok, _} = Store.put(node.name, "undos/" <> op["id"], Jason.encode!(lost))
      assert %{"state" => "stale"} = get_report(node, op["id"])

      again = apply_undo(node, op["id"])

      assert %{"summary" => %{"rewound" => 1, "unknown" => 1}} = again
      assert %{"apply" => %{"state" => "unknown", "expected" => _, "data" => _}} = cells(again)["jobs.a"]
      assert count(node, "a", "notes") == 2
    end

    @tag :capture_log
    test "a retry after a partial failure rewinds only the cells that are left" do
      {node, op} = reported()
      sleep(node, ~w(a b c))
      assert report(node, op["id"])["state"] == "done"
      sleep(node, ~w(a b c))

      {MemoryStore, store} = node.store

      fault =
        MemoryStore.inject(store,
          kind: :error,
          key: ~r{/cells/cells/jobs\.b/},
          ops: [:get, :get_range, :list]
        )

      on_exit(fn -> MemoryStore.clear(store) end)

      first = apply_undo(node, op["id"])
      assert %{"state" => "done", "summary" => %{"rewound" => 2, "failed" => 1}} = first
      assert %{"apply" => %{"state" => "failed", "error" => %{"stage" => "rewind"}}} = cells(first)["jobs.b"]
      rewound = cells(first)["jobs.a"]["apply"]

      # a is written again after its rewind; the retry must not rewind it a second time.
      {:ok, _} = Cell.execute(node.name, {"jobs", "a"}, "INSERT INTO notes (body) VALUES ('kept')")
      MemoryStore.remove(store, fault)
      assert count(node, "b", "effects") == 1

      second = apply_undo(node, op["id"])
      assert %{"state" => "done", "summary" => %{"rewound" => 3, "failed" => 0}} = second
      assert cells(second)["jobs.a"]["apply"] == rewound
      assert count(node, "a", "notes") == 3
      assert count(node, "b", "effects") == 0
      assert count(node, "b", "notes") == 2

      # Nothing is left to do, and nothing is rewound again.
      third = apply_undo(node, op["id"])
      assert cells(third) == cells(second)
      assert count(node, "a", "notes") == 3
    end

    test "is refused while the operation runs, with a pending job, or without a full report" do
      {node, op} = reported(~w(a b), sweeps: [page_size: 1, undo_max_cells: 1])
      sleep(node, ~w(a b))
      assert {:error, :report_required} = Undo.rewind(node.name, op["id"])
      assert report(node, op["id"])["summary"]["truncated"]
      assert {:error, :report_truncated} = Undo.rewind(node.name, op["id"])

      plain = operation(node)
      finished(node, plain)
      assert {:error, :undo_not_enabled} = Undo.rewind(node.name, plain["id"])
      assert {:error, :not_found} = Undo.rewind(node.name, "nosuchoperation")

      {node, op} = reported(~w(a))
      {:ok, stored, etag} = Sweeps.get(node.name, op["id"])
      running = Jason.encode!(%{stored | "state" => "paused"})
      assert {:ok, _} = Store.put(node.name, "operations/" <> op["id"], running, {:if_match, etag})
      assert {:error, :operation_active} = Undo.rewind(node.name, op["id"])
    end

    test "is refused while a job of the operation is pending" do
      {node, op} = reported(~w(a))

      {:ok, _} =
        Cell.execute(
          node.name,
          {"jobs", "a"},
          "UPDATE _atanor_jobs SET state = 'pending', due_at_ms = 9000000000000000"
        )

      sleep(node, ~w(a))
      assert report(node, op["id"])["summary"]["pending_jobs"] == 1
      assert {:error, :jobs_active} = Undo.rewind(node.name, op["id"])
      assert count(node, "a", "effects") == 1
    end
  end

  describe "settings" do
    test "the undo settings are validated" do
      base = [data_dir: "/tmp/x", store: {Mod, nil}]

      for bad <- [
            [undo: "yes"],
            [undo_concurrency: 0],
            [undo_timeout_ms: -1],
            [undo_stale_ms: 1.5],
            [undo_max_cells: 0]
          ] do
        assert_raise ArgumentError, ~r/:sweeps/, fn -> Config.build(base ++ [sweeps: bad]) end
      end

      sweeps = Config.build(base).sweeps

      assert %{
               undo: false,
               undo_concurrency: 2,
               undo_max_cells: 1_000,
               undo_timeout_ms: 120_000,
               undo_stale_ms: 600_000
             } = sweeps

      assert Config.build(base ++ [sweeps: [undo: true]]).sweeps.undo
    end
  end
end
