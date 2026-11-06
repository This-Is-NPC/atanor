defmodule Atanor.JobsTest do
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias Atanor.Cell
  alias Atanor.Test.Manifests
  alias AlambiqueTestkit.ManualClock
  alias AtanorTestkit.Node

  @start 1_000_000_000_000

  defp start(opts \\ []) do
    world = ManualClock.new(@start)
    alarms = Keyword.merge([clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 20], opts[:alarms] || [])
    node = Node.start(Keyword.merge([workers: [Manifests.jobs("jobs")]], Keyword.put(opts, :alarms, alarms)))
    on_exit(fn -> Node.stop(node) end)
    {node, world}
  end

  defp enqueue(node, key, params) do
    query = URI.encode_query(Keyword.merge([key: key], params))
    Req.post!("#{node.url}/enqueue?#{query}", retry: false)
  end

  defp effects(node, key) do
    {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", key}, "SELECT payload FROM effects ORDER BY job_id")
    rows |> List.flatten() |> Enum.sort()
  end

  defp runs(node, key) do
    {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", key}, "SELECT attempt FROM runs ORDER BY id")
    List.flatten(rows)
  end

  test "an enqueued job runs once on the cell and leaves the wake-up clean" do
    {node, world} = start()
    assert %{status: 200} = enqueue(node, "a", payload: "hello")

    assert until(fn -> effects(node, "a") == ["hello"] end)
    assert runs(node, "a") == [1]

    # The @jobs row is gone once the job is done; stale index entries are
    # removed after the alarm timeout, as for any alarm.
    assert until(fn ->
             match?(
               {:ok, %{rows: []}},
               Cell.query(node.name, {"jobs", "a"}, "SELECT at_ms FROM _atanor_alarms WHERE worker = '@jobs'")
             )
           end)

    ManualClock.advance(world, 31_000)
    _ = Atanor.Alarms.run(node.name, fn _ -> true end)

    assert {:ok, %{alarms: []}} = Atanor.Alarms.pending(node.name, nil, 10)
  end

  test "finished jobs leave no @jobs entries in the alarm index" do
    {node, _world} = start()

    # One at a time, each finished before the next: an enqueue that moves a later wake earlier leaves that
    # entry to expire (design §12.13).
    for n <- 1..8 do
      assert %{status: 200} = enqueue(node, "a", payload: "p#{n}")
      assert until(fn -> length(effects(node, "a")) == n and no_wake?(node) end)
    end

    # The clock does not move: only entries that were deleted are gone.
    assert until(fn ->
             {:ok, keys, _} = Atanor.Store.list(Atanor.Store.handle(node.name), "alarms/")
             Enum.filter(keys, &String.contains?(&1, "/@jobs/")) == []
           end)
  end

  test "an enqueue that moves the wake earlier deletes the entry it replaced" do
    {node, _world} = start()

    for at <- [@start + 600_000, @start + 300_000, @start + 100_000] do
      assert %{status: 200} = enqueue(node, "a", payload: "later", at: at)
    end

    {:ok, keys, _} = Atanor.Store.list(Atanor.Store.handle(node.name), "alarms/")
    assert [key] = Enum.filter(keys, &String.contains?(&1, "/@jobs/"))
    assert String.contains?(key, "/#{@start + 100_000}/")
  end

  defp no_wake?(node) do
    match?(
      {:ok, %{rows: []}},
      Cell.query(node.name, {"jobs", "a"}, "SELECT at_ms FROM _atanor_alarms WHERE worker = '@jobs'")
    )
  end

  test "a failing job retries with backoff and then succeeds" do
    {node, world} = start(jobs: [backoff_ms: 1_000, max_backoff_ms: 1_000])
    assert %{status: 200} = enqueue(node, "a", payload: "flaky", max: 3)
    assert until(fn -> runs(node, "a") == [1] end)

    assert until(fn ->
             match?(
               {:ok, %{rows: [["pending"]]}},
               Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs")
             )
           end)

    ManualClock.advance(world, 1_000)
    assert until(fn -> runs(node, "a") == [1, 2] end)
    assert effects(node, "a") == ["flaky"]
  end

  test "purging a dead job removes its index object in the store" do
    {node, world} = start(jobs: [max_attempts: 1, dead_retention_ms: 1_000])
    assert %{status: 200} = enqueue(node, "a", payload: "fail", max: 1)

    assert until(fn ->
             match?(
               {:ok, %{rows: [["dead"]]}},
               Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs")
             )
           end)

    # The index object is put after the transaction that marks the job dead commits.
    assert until(fn -> match?({:ok, [_], _}, Atanor.Store.list(Atanor.Store.handle(node.name), "jobs/dead/")) end)
    ManualClock.advance(world, 60_000)
    assert %{status: 200} = enqueue(node, "a", payload: "noop")

    assert until(fn ->
             match?(
               {:ok, %{rows: [[0]]}},
               Cell.query(node.name, {"jobs", "a"}, "SELECT count(*) FROM _atanor_jobs WHERE state = 'dead'")
             )
           end)

    assert until(fn -> Atanor.Store.list(Atanor.Store.handle(node.name), "jobs/dead/") == {:ok, [], nil} end)
  end

  test "a transaction enqueues a job together with data" do
    {node, _world} = start()
    assert %{status: 200, body: body} = Req.post!("#{node.url}/tx?key=a", retry: false)
    assert body =~ "{:ok, {:ok,"
    assert until(fn -> effects(node, "a") == ["tx"] end)
    {:ok, %{rows: [["committed"]]}} = Cell.query(node.name, {"jobs", "a"}, "SELECT body FROM notes")
  end

  test "a job over max attempts becomes dead and can be retried" do
    {node, world} = start(jobs: [backoff_ms: 1_000, max_backoff_ms: 1_000, max_attempts: 2])
    assert %{status: 200} = enqueue(node, "a", payload: "fail", max: 2)
    assert until(fn -> runs(node, "a") == [1] end)

    assert until(fn ->
             match?(
               {:ok, %{rows: [["pending"]]}},
               Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs")
             )
           end)

    ManualClock.advance(world, 1_000)
    assert until(fn -> runs(node, "a") == [1, 2] end)

    assert until(fn ->
             match?(
               {:ok, %{rows: [["dead", 2, _]]}},
               Cell.query(
                 node.name,
                 {"jobs", "a"},
                 "SELECT state, attempts, last_error FROM _atanor_jobs"
               )
             )
           end)

    {:ok, %{rows: [[id]]}} = Cell.query(node.name, {"jobs", "a"}, "SELECT id FROM _atanor_jobs")
    assert :ok = Atanor.Jobs.retry(node.name, {"jobs", "a"}, id)
    ManualClock.advance(world, 2_000)
    assert until(fn -> length(runs(node, "a")) >= 3 end)
  end

  test "unique keys conflict until done and then allow a new job" do
    {node, world} = start()
    assert %{body: first} = enqueue(node, "a", payload: "one", unique: "u")
    assert first =~ "{:ok, "
    assert %{body: second} = enqueue(node, "a", payload: "two", unique: "u")
    assert second =~ "{:ok, {:duplicate, "
    assert until(fn -> effects(node, "a") == ["one"] end)

    assert until(fn ->
             match?(
               {:ok, %{rows: [["done"]]}},
               Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs")
             )
           end)

    assert %{body: third} = enqueue(node, "a", payload: "three", unique: "u")
    refute third =~ "duplicate"

    assert until(
             fn ->
               ManualClock.advance(world, 250)
               effects(node, "a") == ["one", "three"]
             end,
             10_000
           )
  end

  test "a full cell refuses a new job" do
    {node, _world} = start(jobs: [max_pending: 1], alarms: [tick_ms: 3_600_000])
    assert %{status: 200} = enqueue(node, "a", payload: "one")
    assert %{body: body} = enqueue(node, "a", payload: "two")
    assert body =~ ":queue_full"
  end

  describe "storage bounds" do
    defp count(node, key, sql) do
      {:ok, %{rows: [[n]]}} = Cell.query(node.name, {"jobs", key}, sql)
      n
    end

    test "a cell refuses jobs beyond max_cell_bytes" do
      {node, _world} = start(jobs: [max_cell_bytes: 1_000], alarms: [tick_ms: 3_600_000])
      assert %{body: "{:ok, " <> _} = enqueue(node, "a", payload: String.duplicate("x", 600))
      assert %{body: body} = enqueue(node, "a", payload: String.duplicate("x", 600))
      assert body =~ ":queue_full"
      assert %{body: "{:ok, " <> _} = enqueue(node, "a", payload: String.duplicate("x", 300))
      assert %{body: "{:ok, " <> _} = enqueue(node, "b", payload: String.duplicate("x", 600))
    end

    test "a cell holds at most max_cron schedules" do
      {node, _world} = start(jobs: [max_cron: 3], alarms: [tick_ms: 3_600_000])
      for _ <- 1..5, do: Req.post!("#{node.url}/cron?key=a&expr=*+*+*+*+*", retry: false)
      assert count(node, "a", "SELECT count(*) FROM _atanor_cron") == 3
      assert %{body: body} = Req.post!("#{node.url}/cron?key=a&expr=*+*+*+*+*", retry: false)
      assert body =~ ":too_many_crons"
    end

    test "a cron fire does not go past max_pending" do
      {node, world} = start(jobs: [max_pending: 1])
      assert %{status: 200} = enqueue(node, "a", payload: "later", at: @start + 86_400_000)
      Req.post!("#{node.url}/cron?key=a&expr=*+*+*+*+*", retry: false)
      next = fn -> count(node, "a", "SELECT next_at_ms FROM _atanor_cron") end
      first = next.()

      # The schedule moves on through three fires; none of them adds a job.
      assert until(fn ->
               ManualClock.advance(world, 60_000)
               next.() >= first + 180_000
             end)

      assert count(node, "a", "SELECT count(*) FROM _atanor_jobs") == 1
    end

    test "a finished job does not keep its payload" do
      {node, _world} = start()
      assert %{status: 200} = enqueue(node, "a", payload: String.duplicate("x", 5_000))
      assert until(fn -> count(node, "a", "SELECT count(*) FROM _atanor_jobs WHERE state = 'done'") == 1 end)
      assert count(node, "a", "SELECT sum(length(payload)) FROM _atanor_jobs WHERE state = 'done'") == 0
    end

    test "a cell holds at most max_tombstones forever-unique jobs" do
      {node, _world} = start(jobs: [max_tombstones: 2], alarms: [tick_ms: 3_600_000])
      for u <- ~w(u1 u2), do: assert(%{body: "{:ok, " <> _} = enqueue(node, "a", unique: u, period: "forever"))
      assert %{body: body} = enqueue(node, "a", unique: "u3", period: "forever")
      assert body =~ ":too_many_tombstones"
      assert %{body: "{:ok, " <> _} = enqueue(node, "a", unique: "u3")
    end
  end

  test "terminal jobs are purged after the retention" do
    {node, world} = start(jobs: [retention_ms: 1_000, purge_limit: 10])
    assert %{status: 200} = enqueue(node, "a", payload: "old")
    assert until(fn -> effects(node, "a") == ["old"] end)

    assert until(fn ->
             match?(
               {:ok, %{rows: [["done"]]}},
               Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs")
             )
           end)

    ManualClock.advance(world, 2_000)
    assert %{status: 200} = enqueue(node, "a", payload: "new")
    assert until(fn -> effects(node, "a") == ["new", "old"] end)

    assert until(fn ->
             match?(
               {:ok, %{rows: [[1]]}},
               Cell.query(node.name, {"jobs", "a"}, "SELECT count(*) FROM _atanor_jobs")
             )
           end)
  end

  test "a cell that has the due index only gets the done index at its next wake" do
    {node, _world} = start()
    assert %{status: 200} = enqueue(node, "a", payload: "x")
    assert until(fn -> effects(node, "a") == ["x"] end)

    indexes = fn ->
      {:ok, %{rows: rows}} =
        Cell.query(
          node.name,
          {"jobs", "a"},
          "SELECT name FROM sqlite_master WHERE name LIKE '_atanor_jobs_%' ORDER BY name"
        )

      List.flatten(rows)
    end

    # The purge relies on the done index to skip the finished jobs.
    assert indexes.() == ["_atanor_jobs_done", "_atanor_jobs_due"]
    assert {:ok, _} = Cell.execute(node.name, {"jobs", "a"}, "DROP INDEX _atanor_jobs_done")
    assert indexes.() == ["_atanor_jobs_due"]

    assert %{status: 200} = enqueue(node, "a", payload: "y")
    assert until(fn -> effects(node, "a") == ["x", "y"] end)
    assert until(fn -> indexes.() == ["_atanor_jobs_done", "_atanor_jobs_due"] end)
  end

  test "job listings show only real jobs and a purge keeps the schema state" do
    {node, world} = start(jobs: [retention_ms: 1_000, purge_limit: 10])
    assert %{status: 200} = enqueue(node, "a", payload: "first")
    assert until(fn -> effects(node, "a") == ["first"] end)

    assert until(fn ->
             match?({:ok, %{rows: [["done"]]}}, Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs"))
           end)

    assert {:ok, %{jobs: [%{id: id}]}} = Atanor.Jobs.page(node.name, {"jobs", "a"}, limit: 10)
    refute String.starts_with?(id, "$")

    ManualClock.advance(world, 2_000)
    assert %{status: 200} = enqueue(node, "a", payload: "second")
    assert until(fn -> IO.inspect(effects(node, "a")) == ["first", "second"] end)

    assert until(fn ->
             match?({:ok, %{rows: [[1]]}}, Cell.query(node.name, {"jobs", "a"}, "SELECT count(*) FROM _atanor_jobs"))
           end)

    assert {:ok, %{jobs: [%{id: second}]}} = Atanor.Jobs.page(node.name, {"jobs", "a"}, limit: 10)
    refute String.starts_with?(second, "$")

    assert {:ok, %{rows: [["_atanor_jobs"]]}} =
             Cell.query(
               node.name,
               {"jobs", "a"},
               "SELECT name FROM sqlite_master WHERE type='table' AND name='_atanor_jobs'"
             )

    assert %{status: 200} = enqueue(node, "a", payload: "third")
    assert until(fn -> effects(node, "a") == ["first", "second", "third"] |> Enum.sort() end)
  end

  test "cron schedules a recurring job and advances the schedule" do
    {node, world} = start()
    assert %{status: 200} = Req.post!("#{node.url}/cron?key=a&expr=*%20*%20*%20*%20*", retry: false)
    ManualClock.advance(world, 60_000)
    assert until(fn -> effects(node, "a") == ["cron"] end)
    ManualClock.advance(world, 60_000)
    assert until(fn -> length(effects(node, "a")) >= 2 end)
  end

  test "a stop cancels the attempt that outlives stop.jobs_ms before the detector goes" do
    {node, _world} = start(stop: [jobs_ms: 50])
    table = :"gate_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public])

    assert %{status: 200} = enqueue(node, "a", payload: "gate:#{table}")

    pid =
      until(fn -> match?([{:gate, _}], :ets.lookup(table, :gate)) && :ets.lookup(table, :gate) |> hd() |> elem(1) end)

    ref = Process.monitor(pid)

    # The runner gives the attempt 50 ms, then the instance cancels it while the tables exist.
    :ok = Node.stop(node)
    send(pid, :go)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    assert reason in [:shutdown, :killed], "the attempt crashed instead of being cancelled: #{inspect(reason)}"
    assert :ets.lookup(table, :blocked) == []
  end

  test "a stop gives a running job stop.jobs_ms to finish, and claims no other" do
    {node, _world} = start(stop: [jobs_ms: 600_000])
    table = :"gate_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public])
    assert %{status: 200} = enqueue(node, "a", payload: "gate:#{table}")

    pid =
      until(fn -> match?([{:gate, _}], :ets.lookup(table, :gate)) && :ets.lookup(table, :gate) |> hd() |> elem(1) end)

    slots = Process.whereis(Atanor.Jobs.Slots.name(node.name))
    ref = Process.monitor(pid)
    # The supervisor's default 5 s would kill the drain long before a larger stop.jobs_ms.
    config = Atanor.Registry.config(node.name)
    assert %{shutdown: 605_000} = Atanor.Jobs.Drain.child_spec(config)
    stopping = Task.async(fn -> Node.stop(node) end)

    # The slots close while the job still runs: the drain waits, and only the job's end lets the stop go on.
    assert until(fn -> Atanor.Jobs.Slots.closed?(node.name) end)
    assert Process.alive?(slots)
    assert Process.alive?(pid)

    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000
    assert :ok = Task.await(stopping, 30_000)
    assert [{:blocked, false}] = :ets.lookup(table, :blocked)
  end
end
