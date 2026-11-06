defmodule Atanor.RehearsalTest do
  use ExUnit.Case, async: false

  import Atanor.Test.Await

  alias Atanor.{Deployments, Rehearsal, Store}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @token "rehearsal-token"
  @notes [[1, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"]]
  @tags [[1, "CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT)"]]
  # Runs for as long as the interrupt or the cancel lets it.
  @spin "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000000000) SELECT count(*) FROM c"
  @slow "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 4000000) SELECT count(*) FROM c"

  defp manifest(cells), do: Manifests.probe("notes", cells: cells, routes: [{"127.0.0.1", "/notes"}])

  defp start(opts \\ []) do
    {cells, opts} = Keyword.pop(opts, :cells, %{"notes" => @notes, "tags" => @tags, "empty" => []})
    node = Node.start([workers: [manifest(cells)], admin: [token: @token, port: 0]] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp alambique(node), do: Module.concat(node.name, Cells)

  # Wakes the cells, writes a row and leaves them asleep with their data in the store.
  defp seed(node, ns, keys, sql \\ "INSERT INTO notes (body) VALUES ('a'), ('b')") do
    for key <- keys do
      if ns == "empty",
        do: {:ok, _} = Atanor.Cell.query(node.name, {ns, key}, "SELECT 1"),
        else: {:ok, _} = Atanor.Cell.execute(node.name, {ns, key}, sql)

      :ok = Alambique.hibernate(alambique(node), ns <> "." <> key)
    end
  end

  # Leaves the cell in the schema index with nothing to restore.
  defp wipe(node, cell) do
    {mod, config} = node.store
    {:ok, keys, _} = mod.list(config, "", nil, 1_000)
    for key <- keys, String.contains?(key, "/cells/cells/#{cell}/"), do: :ok = mod.delete(config, key)
  end

  # Publishes a candidate: the same worker with `cells`.
  defp publish(node, cells) do
    package = cells |> manifest() |> Manifests.package()
    {:ok, id} = Deployments.publish(node.name, package)
    id
  end

  defp candidate(node, extra \\ [[2, "ALTER TABLE notes ADD COLUMN tag TEXT"]]),
    do: publish(node, %{"notes" => @notes ++ extra, "tags" => @tags ++ [[2, "ALTER TABLE tags ADD COLUMN x TEXT"]]})

  defp rehearse(node, package, attrs \\ %{}) do
    {:ok, record} = Rehearsal.start(node.name, Map.merge(%{"worker" => "notes", "id" => package}, attrs))
    wait(node, record["id"])
  end

  defp wait(node, id) do
    until(
      fn ->
        {:ok, record} = Rehearsal.get(node.name, id)
        if record["state"] != "running", do: record
      end,
      30_000
    )
  end

  defp cells(report), do: Map.new(report["cells"], &{&1["cell"], &1})

  defp request(node, method, path, body \\ nil) do
    Req.request!(
      method: method,
      url: "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path,
      headers: [{"authorization", "Bearer " <> @token}, {"content-type", "application/json"}],
      body: body && Jason.encode!(body),
      retry: false,
      decode_body: false
    )
  end

  defp json(response), do: Jason.decode!(response.body)

  describe "migration" do
    test "applies the candidate's migrations to every sampled namespace and leaves the cells untouched" do
      node = start()
      seed(node, "notes", ["a", "b", "c"])
      seed(node, "tags", ["t"], "INSERT INTO tags (name) VALUES ('x')")

      report = rehearse(node, candidate(node))

      assert report["state"] == "done"

      assert %{"namespaces" => 2, "sampled" => 4, "ok" => 4, "failed" => 0, "schema_consistent" => true} =
               report["summary"]

      assert %{"notes" => %{"from_min" => 1, "from_max" => 1, "to" => 2}} = report["summary"]["versions"]

      assert %{
               "outcome" => "migrated",
               "from_version" => 1,
               "to_version" => 2,
               "applied" => [2],
               "row_counts_before" => %{"notes" => 2},
               "row_counts_after" => %{"notes" => 2},
               "integrity" => "ok",
               "error" => nil,
               "frozen" => false
             } = cells(report)["notes.a"]

      assert is_binary(cells(report)["notes.a"]["schema_hash"])
      assert %{"outcome" => "migrated", "row_counts_after" => %{"tags" => 1}} = cells(report)["tags.t"]

      # The live cell was not migrated.
      assert {:ok, %{rows: [[1]]}} = Atanor.Cell.query(node.name, {"notes", "a"}, "PRAGMA user_version")
    end

    test "a failing statement fails the cell with its version and SQLite message, and the rehearsal" do
      node = start()
      seed(node, "notes", ["a"])
      package = candidate(node, [[2, ["ALTER TABLE notes ADD COLUMN tag TEXT", "SELECT * FROM missing"]]])

      report = rehearse(node, package)

      assert report["state"] == "failed"
      assert %{"failed" => 1, "ok" => 0} = report["summary"]

      assert %{"outcome" => "failed", "error" => %{"stage" => "migration", "version" => 2, "message" => message}} =
               cells(report)["notes.a"]

      assert message =~ "missing"
    end

    test "a cell newer than the candidate fails with schema_too_new" do
      node = start(cells: %{"notes" => @notes ++ [[2, "ALTER TABLE notes ADD COLUMN tag TEXT"]]})
      seed(node, "notes", ["a"])

      report = rehearse(node, publish(node, %{"notes" => @notes}))

      assert %{
               "outcome" => "failed",
               "error" => %{"stage" => "migration", "version" => 2, "message" => message}
             } =
               cells(report)["notes.a"]

      assert message =~ "schema_too_new"
    end

    test "a cell already at the candidate's version is nothing_pending, an empty cell is skipped" do
      node = start()
      seed(node, "notes", ["a"])
      seed(node, "empty", ["e"])
      wipe(node, "empty.e")
      package = publish(node, %{"notes" => @notes, "empty" => [[1, "CREATE TABLE e (id INTEGER)"]]})

      report = rehearse(node, package)

      assert report["state"] == "done"

      assert %{"outcome" => "nothing_pending", "applied" => [], "row_counts_after" => %{"notes" => 2}} =
               cells(report)["notes.a"]

      assert %{"outcome" => "empty"} = cells(report)["empty.e"]
      assert %{"ok" => 1, "skipped" => 1} = report["summary"]
    end

    test "a package without migrations has nothing to rehearse" do
      node = start()
      package = publish(node, %{})

      report = rehearse(node, package)

      assert %{"state" => "done", "reason" => "nothing_to_rehearse", "cells" => []} = report
    end

    test "a migration that drops a captured column works on the copy" do
      node = start()
      seed(node, "notes", ["a"])

      report = rehearse(node, candidate(node, [[2, "ALTER TABLE notes DROP COLUMN body"]]))

      assert %{"outcome" => "migrated"} = cells(report)["notes.a"]
    end
  end

  describe "comparison" do
    test "a migration that deletes rows is reported, not failed" do
      node = start()
      seed(node, "notes", ["a"])

      report = rehearse(node, candidate(node, [[2, "DELETE FROM notes WHERE id = 1"]]))

      assert report["state"] == "done"

      assert %{
               "row_counts_before" => %{"notes" => 2},
               "row_counts_after" => %{"notes" => 1},
               "row_count_decreased" => ["notes"]
             } =
               cells(report)["notes.a"]
    end

    test "cells of a namespace that end with different schemas are reported, and strict_schema fails them" do
      node = start()
      seed(node, "notes", ["a", "b"])
      {:ok, _} = Atanor.Cell.execute(node.name, {"notes", "b"}, "CREATE TABLE drift (id INTEGER)")
      :ok = Alambique.hibernate(alambique(node), "notes.b")
      package = candidate(node)

      lenient = rehearse(node, package)
      assert lenient["state"] == "done"
      assert %{"schema_consistent" => false, "schema_groups" => %{"notes" => groups}} = lenient["summary"]
      assert map_size(groups) == 2
      refute cells(lenient)["notes.a"]["schema_hash"] == cells(lenient)["notes.b"]["schema_hash"]

      strict = rehearse(node, package, %{"strict_schema" => true})
      assert %{"state" => "failed", "error" => %{"stage" => "schema"}} = strict
    end

    test "integrity_check is a request option and the check result is in the report" do
      node = start()
      seed(node, "notes", ["a"])

      report = rehearse(node, candidate(node), %{"integrity_check" => "integrity_check"})

      assert report["options"]["integrity_check"] == "integrity_check"
      assert cells(report)["notes.a"]["integrity"] == "ok"
    end

    # Alambique connections are defensive since 8c269ff: a migration cannot corrupt the schema, it fails first.
    test "a migration that edits the schema tables fails the cell at the migration" do
      node = start()
      seed(node, "notes", ["a"])

      corrupt = [
        "PRAGMA writable_schema = ON",
        "INSERT INTO sqlite_master (type, name, tbl_name, rootpage, sql) VALUES ('table', 'bogus', 'bogus', 999, 'CREATE TABLE bogus (a)')",
        "PRAGMA schema_version = 9999",
        "PRAGMA writable_schema = OFF"
      ]

      report = rehearse(node, candidate(node, [[2, corrupt]]), %{"integrity_check" => "integrity_check"})

      assert %{"state" => "failed"} = report

      assert %{"outcome" => "failed", "error" => %{"stage" => "migration", "message" => message}} =
               cells(report)["notes.a"]

      assert message =~ "sqlite_master may not be modified"
    end
  end

  describe "integrity" do
    # A row that breaks a CHECK constraint is a corrupt copy for `integrity_check`, and a migration may write it.
    test "a copy that fails the integrity check fails the cell at the check" do
      node = start()
      seed(node, "notes", ["a"])

      broken = [
        "CREATE TABLE checked (n INTEGER CHECK (n > 0))",
        "PRAGMA ignore_check_constraints = ON",
        "INSERT INTO checked (n) VALUES (-1)",
        "PRAGMA ignore_check_constraints = OFF"
      ]

      report = rehearse(node, candidate(node, [[2, broken]]), %{"integrity_check" => "integrity_check"})

      assert %{"state" => "failed"} = report

      assert %{"outcome" => "failed", "integrity" => integrity, "error" => %{"stage" => "check", "message" => message}} =
               cells(report)["notes.a"]

      assert integrity != "ok"
      assert message =~ "CHECK constraint failed"

      # The same table with a valid row passes.
      fine = ["CREATE TABLE checked (n INTEGER CHECK (n > 0))", "INSERT INTO checked (n) VALUES (1)"]

      assert %{"state" => "done"} =
               rehearse(node, candidate(node, [[2, fine]]), %{"integrity_check" => "integrity_check"})
    end
  end

  describe "sampling" do
    test "samples sample_size cells per namespace, only of the candidate's namespaces, and records the seed" do
      node = start()
      seed(node, "notes", Enum.map(1..8, &"n#{&1}"))
      seed(node, "tags", Enum.map(1..8, &"t#{&1}"), "INSERT INTO tags (name) VALUES ('x')")
      seed(node, "empty", ["e"])
      package = publish(node, %{"notes" => @notes ++ [[2, "ALTER TABLE notes ADD COLUMN tag TEXT"]]})

      report = rehearse(node, package, %{"sample_size" => 3, "seed" => 42})

      assert report["options"]["seed"] == 42
      assert length(report["cells"]) == 3
      assert Enum.all?(report["cells"], &String.starts_with?(&1["cell"], "notes."))

      assert %{"notes" => %{"scanned" => 8, "sampled" => 3, "max_scan_reached" => false}} =
               report["summary"]["sampling"]
    end

    test "the same seed picks the same cells, and a random seed is recorded" do
      node = start()
      seed(node, "notes", Enum.map(1..12, &"n#{&1}"))
      package = candidate(node)
      sampled = fn attrs -> rehearse(node, package, attrs) end

      names = fn report -> Enum.map(report["cells"], & &1["cell"]) end
      first = sampled.(%{"sample_size" => 4, "seed" => 7})

      assert names.(first) == names.(sampled.(%{"sample_size" => 4, "seed" => 7}))
      refute names.(first) == names.(sampled.(%{"sample_size" => 4, "seed" => 8}))

      random = sampled.(%{"sample_size" => 4})
      assert is_integer(random["options"]["seed"])
      assert names.(random) == names.(sampled.(%{"sample_size" => 4, "seed" => random["options"]["seed"]}))
    end

    test "max_scan bounds the ids listed, across pages" do
      node = start(rehearsal: [page_size: 2, max_scan: 5])
      seed(node, "notes", Enum.map(1..9, &"n#{&1}"))

      report = rehearse(node, candidate(node), %{"sample_size" => 5})

      assert %{"notes" => %{"scanned" => 5, "sampled" => 5, "max_scan_reached" => true}} = report["summary"]["sampling"]
    end

    test "max_cells bounds the total across namespaces" do
      node = start()
      seed(node, "notes", Enum.map(1..4, &"n#{&1}"))
      seed(node, "tags", Enum.map(1..4, &"t#{&1}"), "INSERT INTO tags (name) VALUES ('x')")

      report = rehearse(node, candidate(node), %{"sample_size" => 3, "max_cells" => 4})

      assert length(report["cells"]) == 4
      assert report["summary"]["max_cells_reached"]
    end
  end

  describe "guarantees" do
    test "no owner appears for the sampled cells and the feed does not move" do
      node = start()
      seed(node, "notes", ["a", "b"])
      prefix = Atanor.Registry.config(node.name).prefix <> "/cells"
      ctx = Alambique.Feed.ctx(store: node.store, prefix: prefix, settle_ms: 0)
      {:ok, records, position} = Alambique.Feed.read(ctx, nil, 1_000)
      assert records != []

      report = rehearse(node, candidate(node))

      assert report["state"] == "done"
      assert :none = Alambique.owner(alambique(node), "notes.a")
      assert :none = Alambique.owner(alambique(node), "notes.b")
      assert {:ok, ^records, ^position} = Alambique.Feed.read(ctx, nil, 1_000)
      assert {:ok, %{cells: []}} = {:ok, Alambique.cells(alambique(node), limit: 10)}
    end

    test "the temporary directory is removed after success, failure and timeout" do
      dir = Path.join(System.tmp_dir!(), "atanor-rehearsal-#{System.pid()}-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      node = start(rehearsal: [dir: dir, timeout_ms: 1_000])
      seed(node, "notes", ["a"])

      for {extra, state} <- [
            {[[2, "ALTER TABLE notes ADD COLUMN tag TEXT"]], "done"},
            {[[2, "SELECT * FROM missing"]], "failed"},
            {[[2, @spin]], "failed"}
          ] do
        report = rehearse(node, candidate(node, extra))
        assert report["state"] == state
        until(fn -> File.ls!(dir) == [] end)
      end

      assert %{"error" => %{"stage" => "timeout"}} = cells(rehearse(node, candidate(node, [[2, @spin]])))["notes.a"]
    end
  end

  describe "records" do
    test "the report is stored under the instance prefix and read back, newest first in the list" do
      node = start()
      seed(node, "notes", ["a"])
      package = candidate(node)

      first = rehearse(node, package)
      second = rehearse(node, package)

      assert {:ok, body, _, _} = Store.get(node.name, "rehearsals/" <> first["id"])
      assert Jason.decode!(body)["summary"] == first["summary"]
      assert first["release"]["id"] == Atanor.Release.id(node.name)
      assert first["node"] == Atom.to_string(node())
      assert {:ok, [newest, oldest]} = Rehearsal.list(node.name, 10)
      assert {newest["id"], oldest["id"]} == {second["id"], first["id"]}
      assert {:ok, [^newest]} = Rehearsal.list(node.name, 1)
    end

    test "a running record that nobody updates is stale, and a fresh one blocks a new rehearsal" do
      node = start(rehearsal: [stale_ms: 60_000, timeout_ms: 1_000])
      seed(node, "notes", ["a"])
      package = candidate(node)
      now = Atanor.Alarms.now(Atanor.Registry.config(node.name))

      record = fn id, updated ->
        %{"id" => id, "state" => "running", "updated_at_ms" => updated, "started_at_ms" => updated}
      end

      {:ok, _} = Store.put(node.name, "rehearsals/h-#{now}-a", Jason.encode!(record.("h-#{now}-a", now - 70_000)))
      assert {:ok, %{"state" => "stale"}} = Rehearsal.get(node.name, "h-#{now}-a")

      {:ok, _} = Store.put(node.name, "rehearsals/h-#{now + 1}-b", Jason.encode!(record.("h-#{now + 1}-b", now)))
      assert {:ok, %{"state" => "running"}} = Rehearsal.get(node.name, "h-#{now + 1}-b")
      assert {:error, :already_running} = Rehearsal.start(node.name, %{"worker" => "notes", "id" => package})
      assert {:error, :invalid_state} = Rehearsal.cancel(node.name, "h-#{now}-a")

      :ok = Store.delete(node.name, "rehearsals/h-#{now + 1}-b")
      assert %{"state" => "done"} = rehearse(node, package)
    end

    test "reports older than retention are removed when a rehearsal starts or the list is read" do
      node = start(rehearsal: [retention_ms: 60_000, stale_ms: 120_000, timeout_ms: 1_000])
      seed(node, "notes", ["a"])
      old = "h-#{String.pad_leading("1", 13, "0")}-old"
      {:ok, _} = Store.put(node.name, "rehearsals/" <> old, Jason.encode!(%{"id" => old, "state" => "done"}))
      {:ok, _} = Store.put(node.name, "rehearsals/foreign", "{}")

      assert {:ok, []} = Rehearsal.list(node.name, 10)
      assert {:error, :not_found} = Store.get(node.name, "rehearsals/" <> old)
      assert {:ok, _, _, _} = Store.get(node.name, "rehearsals/foreign")

      {:ok, _} = Store.put(node.name, "rehearsals/" <> old, Jason.encode!(%{"id" => old, "state" => "done"}))
      %{"state" => "done"} = rehearse(node, candidate(node))
      assert {:error, :not_found} = Store.get(node.name, "rehearsals/" <> old)
    end
  end

  describe "cancel" do
    test "stops before the next cell, keeps the cells done and leaves a breadcrumb while it runs" do
      node = start(rehearsal: [concurrency: 1, sample_size: 10])
      seed(node, "notes", Enum.map(1..8, &"n#{&1}"))
      package = candidate(node, [[2, @slow]])

      {:ok, record} = Rehearsal.start(node.name, %{"worker" => "notes", "id" => package})
      id = record["id"]

      units = Path.join(node.data_dir, "diagnostics/units")

      assert until(fn ->
               File.ls!(units) |> Enum.any?(&(File.read!(Path.join(units, &1)) =~ ~s("kind":"rehearsal")))
             end)

      until(fn ->
        {:ok, %{"progress" => %{"done" => done}}} = Rehearsal.get(node.name, id)
        done >= 1
      end)

      assert {:ok, %{"cancel_requested" => true, "state" => "running"}} = Rehearsal.cancel(node.name, id)
      report = wait(node, id)

      assert report["state"] == "cancelled"
      assert length(report["cells"]) in 1..7
      assert {:error, :invalid_state} = Rehearsal.cancel(node.name, id)
      until(fn -> File.ls!(units) == [] end)
    end
  end

  describe "admin API" do
    test "starts with 202, lists, reads and refuses what it must" do
      node = start()
      seed(node, "notes", ["a"])
      package = candidate(node)

      response = request(node, :post, "/rehearsals", %{"worker" => "notes", "id" => package, "sample_size" => 1})
      assert response.status == 202
      assert %{"id" => id, "state" => "running", "worker" => "notes", "package" => ^package} = json(response)
      wait(node, id)

      assert %{"state" => "done", "worker" => "notes"} = node |> request(:get, "/rehearsals/" <> id) |> json()
      assert %{"rehearsals" => [%{"id" => ^id}]} = node |> request(:get, "/rehearsals") |> json()
      assert request(node, :get, "/rehearsals/missing").status == 404
      assert request(node, :get, "/rehearsals?limit=0").status == 400
      assert request(node, :post, "/rehearsals/#{id}/cancel").status == 409
      assert request(node, :post, "/rehearsals/missing/cancel").status == 404

      {:ok, other} = Deployments.publish(node.name, Manifests.package(Manifests.probe("other")))
      assert request(node, :post, "/rehearsals", %{"worker" => "notes", "id" => other}).status == 400

      assert %{"error" => "wrong_worker"} =
               node |> request(:post, "/rehearsals", %{"worker" => "notes", "id" => other}) |> json()

      assert request(node, :post, "/rehearsals", %{"worker" => "notes", "id" => String.duplicate("0", 64)}).status ==
               404

      assert request(node, :post, "/rehearsals", %{"worker" => "notes"}).status == 400

      for attrs <- [
            %{"sample_size" => 11},
            %{"max_cells" => 101},
            %{"timeout_ms" => 120_001},
            %{"sample_size" => 0},
            %{"extra" => 1}
          ] do
        response = request(node, :post, "/rehearsals", Map.merge(%{"worker" => "notes", "id" => package}, attrs))
        assert response.status == 400, inspect(attrs)
        assert %{"error" => "invalid_rehearsal"} = json(response)
      end

      assert request(node, :post, "/rehearsals", nil).status == 400
    end

    test "cancels a running rehearsal over HTTP, and every call needs the token" do
      node = start(rehearsal: [concurrency: 1])
      seed(node, "notes", Enum.map(1..6, &"n#{&1}"))
      package = candidate(node, [[2, @slow]])

      %{"id" => id} = node |> request(:post, "/rehearsals", %{"worker" => "notes", "id" => package}) |> json()
      assert request(node, :post, "/rehearsals", %{"worker" => "notes", "id" => package}).status == 409
      assert %{"cancel_requested" => true} = node |> request(:post, "/rehearsals/#{id}/cancel") |> json()
      assert wait(node, id)["state"] == "cancelled"

      url = "http://127.0.0.1:#{Atanor.admin_port(node.name)}/rehearsals"
      assert Req.get!(url, retry: false).status == 401
      assert Req.post!(url, retry: false).status == 401
    end
  end

  describe "options" do
    test "defaults are the documented values" do
      config = Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil})

      assert config.rehearsal == %{
               sample_size: 10,
               max_cells: 100,
               max_scan: 10_000,
               page_size: 1_000,
               concurrency: 2,
               timeout_ms: 120_000,
               integrity_check: :quick_check,
               strict_schema: false,
               seed: nil,
               dir: nil,
               stale_ms: 600_000,
               retention_ms: 604_800_000
             }
    end

    test "invalid options raise" do
      for rehearsal <- [
            [sample_size: 0],
            [max_cells: -1],
            [max_scan: "1"],
            [page_size: 0],
            [concurrency: 0],
            [timeout_ms: 0],
            [stale_ms: 0],
            [retention_ms: 0],
            [integrity_check: :full],
            [strict_schema: 1],
            [seed: "1"],
            [dir: ""],
            [sample_size: 11, max_cells: 10],
            [timeout_ms: 600_000],
            [unknown: 1],
            :nope
          ] do
        assert_raise ArgumentError, ~r/rehearsal/, fn ->
          Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, rehearsal: rehearsal)
        end
      end
    end
  end
end
