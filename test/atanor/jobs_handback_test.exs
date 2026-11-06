defmodule Atanor.JobsHandbackTest do
  @moduledoc """
  Jobs when a node hands its cells to a node that shares its store and is not clustered with it
  (design §15.12). Node A drains; node B wakes the cells.
  """
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias Atanor.{Alarms, Cell, Jobs}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @moduletag timeout: 60_000
  @far 4_000_000_000_000

  # Neither node scans by itself unless `scanning`; a test starts A's claims with `scan/1`.
  defp start(opts) do
    {tick, extra} = Keyword.pop(opts, :tick, 3_600_000)
    {jobs, extra} = Keyword.pop(extra, :jobs, [])
    {stop, extra} = Keyword.pop(extra, :stop, [])

    node =
      Node.start(
        [
          workers: [Manifests.jobs("jobs")],
          alarms: [tick_ms: tick],
          jobs: Keyword.merge([concurrency: 8, worker_concurrency: 8, cell_concurrency: 2], jobs),
          alambique: [node_id: "node-#{System.unique_integer([:positive])}"],
          stop: Keyword.merge([exit: false, jobs_ms: 300], stop)
        ] ++ extra
      )

    on_exit(fn -> Node.stop(node) end)
    node
  end

  # Two nodes in one VM share a prefix, so their schedulers share a :pg group. Real nodes outside a cluster do
  # not: the scheduler of A leaves the group, and B owns every shard, as it would alone.
  defp pair(a_opts \\ []) do
    a = start(a_opts)
    scheduler = Process.whereis(Module.concat(a.name, Alarms))
    :pg.leave(Atanor.PG, Alarms.group(Atanor.Registry.config(a.name).prefix), scheduler)
    b = start(store: a.store, tick: 50)
    {a, b}
  end

  defp scan(node), do: Alarms.run(node.name, fn _ -> true end)

  defp enqueue(node, payload, due \\ nil) do
    spec = %{kind: "test", payload: payload, scheduled_at_ms: due}
    {:ok, id} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", "a"}, spec)
    id
  end

  defp query(node, sql) do
    {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", "a"}, sql)
    rows
  end

  defp runs(node), do: query(node, "SELECT job_id, attempt, payload FROM runs ORDER BY id")
  defp states(node), do: query(node, "SELECT state, claimed_by FROM _atanor_jobs ORDER BY id")

  defp claim_row(node, id, by) do
    {:ok, _} =
      Cell.execute(
        node.name,
        {"jobs", "a"},
        "UPDATE _atanor_jobs SET state = 'running', claimed_by = ?, claimed_until_ms = ?, attempts = 1 WHERE id = ?",
        [by, @far, id]
      )
  end

  test "a pending job is started by the node that takes the cell, right after the handback" do
    {a, b} = pair()
    id = enqueue(a, "pending")
    assert runs(a) == []

    # B scans every 50 ms and finds the cell held by A: nothing runs yet.
    Process.sleep(300)
    assert runs(a) == []

    started = System.monotonic_time(:millisecond)
    assert {:ok, %{errors: []}} = Atanor.drain(a.name, exit: false)
    assert until(fn -> runs(b) == [[id, 1, "pending"]] end)
    assert System.monotonic_time(:millisecond) - started < 3_000
  end

  test "a claim A leaves behind is released at the drain, and the job runs once, on B" do
    {a, b} = pair()
    claimed = enqueue(a, "claimed")
    finished = enqueue(a, "finished")
    # A claims a job and no task of it runs: what a start that failed leaves.
    claim_row(a, claimed, Atom.to_string(node()))
    {:ok, _} = Cell.execute(a.name, {"jobs", "a"}, "UPDATE _atanor_jobs SET state = 'done' WHERE id = ?", [finished])

    assert {:ok, _} = Atanor.drain(a.name, exit: false)
    assert until(fn -> runs(b) == [[claimed, 2, "claimed"]] end)
    assert until(fn -> Enum.sort(states(b)) == [["done", nil], ["done", nil]] end)
    Process.sleep(300)
    assert runs(b) == [[claimed, 2, "claimed"]]
  end

  test "a claim is left alone when release_claims is false" do
    {a, b} = pair(jobs: [release_claims: false])
    claimed = enqueue(a, "claimed")
    claim_row(a, claimed, Atom.to_string(node()))
    assert {:ok, _} = Atanor.drain(a.name, exit: false)
    Process.sleep(400)
    assert [["running", _]] = states(b)
    assert runs(b) == []
  end

  test "a job A still runs when the drain ends is not released, so it never runs twice", %{tmp_dir: dir} do
    {a, b} = pair()
    id = enqueue(a, "file:1500:" <> dir)
    scan(a)
    path = Path.join(dir, id)
    assert until(fn -> File.exists?(path) end)

    # `stop.jobs_ms` (300) ends with the job running: its claim is kept.
    assert {:ok, _} = Atanor.drain(a.name, exit: false)
    assert until(fn -> File.read!(path) =~ "end" end)
    Process.sleep(500)

    assert [_] = for("start" <> _ = line <- String.split(File.read!(path), "\n", trim: true), do: line)
    assert [["running", _]] = states(b)
    assert [[^id, 1, _]] = runs(b)
  end

  test "a job that ends after the drain closed the runner claims no next job", %{tmp_dir: dir} do
    a = start(jobs: [cell_concurrency: 1], stop: [exit: false, jobs_ms: 5_000])
    b = start(store: a.store)
    scheduler = Process.whereis(Module.concat(a.name, Alarms))
    :pg.leave(Atanor.PG, Alarms.group(Atanor.Registry.config(a.name).prefix), scheduler)

    first = enqueue(a, "file:600:" <> dir)
    enqueue(a, "second")
    scan(a)
    assert until(fn -> File.exists?(Path.join(dir, first)) end)

    assert {:ok, %{errors: []}} = Atanor.drain(a.name, exit: false)
    assert [["done", _], ["pending", nil]] = states(b)
    assert [[^first, 1, _]] = runs(b)
  end
end
