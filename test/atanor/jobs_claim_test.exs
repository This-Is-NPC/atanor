defmodule Atanor.JobsClaimTest do
  @moduledoc """
  Claiming the next due jobs of a cell when one finishes (design §15.5) and
  releasing the claims of a node whose cell was taken over (design §15.11).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Atanor.Test.Await

  alias Atanor.{Cell, Jobs}
  alias Atanor.Test.Manifests
  alias AlambiqueTestkit.ManualClock
  alias AtanorTestkit.Node

  @moduletag timeout: 120_000

  @clock_start 1_000_000_000_000

  # By default no scan runs by itself and a test starts the first claim with `scan/1`. With `scanning`
  # the scan is fast, for cells that wait for a slot of another cell (design §15.5).
  defp start(jobs \\ [], opts \\ []) do
    {tick, wait} = if opts[:scanning], do: {50, 100}, else: {3_600_000, 1_000}

    node =
      Node.start(
        workers: [Manifests.jobs("jobs")],
        alarms: [tick_ms: tick] ++ Keyword.take(opts, [:timeout_ms, :clock]),
        jobs: [concurrency: 8, worker_concurrency: 8, cell_concurrency: 2, wait_ms: wait] |> Keyword.merge(jobs)
      )

    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp scan(node), do: Atanor.Alarms.run(node.name, fn _ -> true end)

  defp table, do: :"track_#{System.unique_integer([:positive])}"

  defp tracker do
    name = table()
    :ets.new(name, [:named_table, :public, :set])
    name
  end

  defp enqueue(node, key, payload, due \\ nil) do
    spec = %{kind: "test", payload: payload, scheduled_at_ms: due}
    {:ok, id} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", key}, spec)
    id
  end

  defp effects(node, key) do
    {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", key}, "SELECT payload FROM effects")
    rows |> List.flatten() |> Enum.sort()
  end

  defp states(node, key) do
    {:ok, %{rows: rows}} =
      Cell.query(node.name, {"jobs", key}, "SELECT state, claimed_by FROM _atanor_jobs ORDER BY id")

    rows
  end

  # Every job of the cells is finished, so stopping the node cuts nothing off.
  defp settled?(node, keys),
    do: Enum.all?(keys, fn key -> Enum.all?(states(node, key), fn [state, _] -> state in ["done", "dead"] end) end)

  # Moves the clock 10 ms every 10 ms, as real time would, until the test ends.
  defp tick_clock(world) do
    owner = self()
    spawn(fn -> tick_loop(world, owner) end)
  end

  defp tick_loop(world, owner) do
    Process.sleep(10)

    if Process.alive?(owner) do
      ManualClock.advance(world, 10)
      tick_loop(world, owner)
    end
  end

  defp max_running(table, key) do
    for {{:sample, _}, ^key, n} <- :ets.tab2list(table), reduce: 0, do: (max -> max(max, n))
  end

  defp started(table), do: for({{:started, seq}, key, id} <- Enum.sort(:ets.tab2list(table)), do: {seq, key, id})

  describe "claim_on_finish" do
    test "a finishing job claims the next due jobs of its cell without a scan" do
      node = start()
      for i <- 1..6, do: enqueue(node, "a", "p#{i}")
      scan(node)

      assert until(fn -> effects(node, "a") == Enum.map(1..6, &"p#{&1}") and settled?(node, ["a"]) end, 15_000)
    end

    test "with claim_on_finish false the rest waits for the next scan" do
      node = start(claim_on_finish: false)
      for i <- 1..6, do: enqueue(node, "a", "p#{i}")
      scan(node)

      assert until(fn -> length(effects(node, "a")) == 2 end)
      Process.sleep(500)
      assert length(effects(node, "a")) == 2

      for _ <- 1..4, do: scan(node)
      assert until(fn -> length(effects(node, "a")) == 6 and settled?(node, ["a"]) end, 15_000)
    end

    test "a dead job also hands over to the next one" do
      node = start(cell_concurrency: 1)
      now = System.os_time(:millisecond)

      enqueue(node, "a", "fail", now - 2_000)
      |> then(&Cell.execute(node.name, {"jobs", "a"}, "UPDATE _atanor_jobs SET max_attempts = 1 WHERE id = ?", [&1]))

      enqueue(node, "a", "next", now - 1_000)
      scan(node)

      # The effect is written before the job is marked done.
      assert until(fn -> "next" in effects(node, "a") and settled?(node, ["a"]) end, 15_000)
      assert [["dead", nil], ["done", nil]] = states(node, "a")
    end

    test "the node and worker limits hold across cells" do
      node = start([concurrency: 2, worker_concurrency: 2, cell_concurrency: 1], scanning: true)
      t = tracker()
      for key <- ["a", "b", "c"], i <- 1..4, do: enqueue(node, key, "track:30:#{t}", System.os_time(:millisecond) - i)

      scan(node)

      assert until(
               fn ->
                 Enum.all?(["a", "b", "c"], &(length(effects(node, &1)) == 4)) and settled?(node, ["a", "b", "c"])
               end,
               30_000
             )

      assert max_running(t, :all) <= 2
      for key <- ["a", "b", "c"], do: assert(max_running(t, key) == 1)
    end

    test "a stopping node claims nothing more" do
      node = start(cell_concurrency: 1)
      for i <- 1..3, do: enqueue(node, "a", "p#{i}")
      Atanor.Jobs.Slots.close(node.name)
      scan(node)
      Process.sleep(300)
      assert effects(node, "a") == []
    end

    property "never more than cell_concurrency run in a cell, in due order, none lost" do
      check all(
              cell_limit <- integer(1..4),
              worker_limit <- integer(cell_limit..6),
              counts <- list_of(integer(1..9), length: 2),
              max_runs: 10
            ) do
        # Jobs are due after the last enqueue: a scan that ran earlier would claim a higher rank before a
        # lower one that is not enqueued yet, and that is not an ordering defect. The clock stays before every
        # due time until all jobs are enqueued, however long that takes, then moves past them.
        world = ManualClock.new(@clock_start)

        node =
          start([concurrency: 6, worker_concurrency: worker_limit, cell_concurrency: cell_limit],
            scanning: true,
            clock: {ManualClock, ManualClock.config(world, 0)}
          )

        t = tracker()
        base = @clock_start + 1_500

        ids =
          for {count, cell} <- Enum.with_index(counts, 1), key = "c#{cell}", rank <- Enum.shuffle(1..count) do
            {key, rank, enqueue(node, key, "track:#{5 + rem(rank, 7)}:#{t}", base + rank)}
          end

        # Past every due time, then at the pace of real time: cells that wait for a slot retry after wait_ms.
        ManualClock.advance(world, 2_000)
        ticker = tick_clock(world)
        total = Enum.sum(counts)

        assert until(
                 fn -> length(started(t)) == total and :ets.lookup(t, {:running, :all}) == [{{:running, :all}, 0}] end,
                 60_000
               )

        keys = for {_, i} <- Enum.with_index(counts, 1), do: "c#{i}"

        assert until(
                 fn -> settled?(node, keys) and length(Enum.flat_map(keys, &effects(node, &1))) == total end,
                 30_000
               )

        for {_, i} <- Enum.with_index(counts, 1), key = "c#{i}" do
          assert max_running(t, key) <= cell_limit

          order = for {_, ^key, id} <- started(t), do: id
          due = for {^key, _rank, id} <- Enum.sort_by(ids, fn {_, rank, _} -> rank end), do: id
          assert Enum.sort(order) == Enum.sort(due), "a job was lost or run twice in #{key}"

          # Jobs claimed together start in any order; the displacement stays below the bound.
          for {id, index} <- Enum.with_index(order) do
            assert abs(index - Enum.find_index(due, &(&1 == id))) < cell_limit
          end
        end

        assert max_running(t, :all) <= worker_limit
        Process.exit(ticker, :kill)
        Node.stop(node)
      end
    end
  end

  describe "batched claim" do
    # Several scans claim batches of one cell at once, over jobs that are due, jobs whose claim expired and
    # jobs claimed by another node that still holds them. Each job that may run runs once; the others never.
    property "a batch never claims a job twice, and each job completes once" do
      check all(
              cell_limit <- integer(1..4),
              batch <- integer(1..5),
              scans <- integer(2..4),
              kinds <- list_of(member_of([:due, :due, :expired, :foreign]), min_length: 1, max_length: 12),
              max_runs: 25
            ) do
        # Claims of another node count against the bound of the cell, so they widen it.
        bound = cell_limit + Enum.count(kinds, &(&1 == :foreign))

        node =
          start(concurrency: 16, worker_concurrency: 16, cell_concurrency: bound, batch_size: batch, claim_ms: 600_000)

        t = tracker()
        now = System.os_time(:millisecond)
        ids = for {_, i} <- Enum.with_index(kinds), do: enqueue(node, "b", "track:15:#{t}", now - 1_000 + i)

        for {kind, id} <- Enum.zip(kinds, ids), kind != :due do
          lease = if kind == :expired, do: now - 500, else: now + 600_000
          claim_row(node, "b", id, "other@host", lease)
        end

        for task <- for(_ <- 1..scans, do: Task.async(fn -> Jobs.run(node.name, {"jobs", "b"}, nil) end)),
            do: assert(:ok = Task.await(task, 30_000))

        runnable = for {kind, id} <- Enum.zip(kinds, ids), kind != :foreign, do: id
        foreign = for {:foreign, id} <- Enum.zip(kinds, ids), do: id

        assert until(fn -> length(started(t)) >= length(runnable) and Jobs.stats(node.name).running == 0 end, 30_000)
        assert until(fn -> done(node, runnable) end, 30_000)
        Process.sleep(100)

        ran = for {_, "b", id} <- started(t), do: id
        assert Enum.sort(ran) == Enum.sort(runnable), "a job ran twice, or not at all, or a foreign claim ran"
        assert Enum.all?(foreign, &(&1 not in ran))
        assert max_running(t, "b") <= cell_limit
        assert runs(node, "b") |> Enum.all?(fn {id, count} -> id in runnable and count == 1 end)
        Node.stop(node)
      end
    end

    defp done(node, ids) do
      {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", "b"}, "SELECT id, state FROM _atanor_jobs")
      Enum.all?(rows, fn [id, state] -> id not in ids or state == "done" end)
    end

    defp runs(node, key) do
      {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", key}, "SELECT job_id, count(*) FROM runs GROUP BY job_id")
      Enum.map(rows, &List.to_tuple/1)
    end
  end

  @doc false
  def kill_runner(_event, _measurements, meta, {instance, id}) do
    if meta.instance == instance and meta.id == id do
      :telemetry.detach({__MODULE__, id})
      Process.exit(self(), :kill)
    end
  end

  defmodule StepClock do
    @moduledoc false
    # Every reading is one second later than the one before.
    def now_ms(ref), do: :atomics.add_get(ref, 1, 1_000)
  end

  @doc false
  def report_started(_event, _measurements, meta, {pid, instance}) do
    if meta.instance == instance, do: send(pid, {:started, meta})
  end

  describe "claim lease" do
    test "a claim lasts claim_ms from the moment it is written, not from the start of the scan" do
      ref = :atomics.new(1, [])
      :atomics.put(ref, 1, System.os_time(:millisecond))
      node = start([claim_ms: 60_000, timeout_ms: 1_000], clock: {StepClock, ref})
      enqueue(node, "a", "ok")
      :telemetry.attach({__MODULE__, ref}, [:atanor, :job, :started], &__MODULE__.report_started/4, {self(), node.name})
      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      before = :atomics.get(ref, 1)
      assert :ok = Jobs.run(node.name, {"jobs", "a"}, nil)

      # The scan reads the clock once to select the job and the claim reads it again when it writes the lease.
      assert_receive {:started, %{claimed_until_ms: lease}}, 5_000
      assert lease - 60_000 > before + 1_000
      assert until(fn -> effects(node, "a") == ["ok"] end, 5_000)
    end
  end

  describe "slots" do
    test "a process that dies after the claim gives its slot back, and the job runs when the claim expires" do
      node =
        start([concurrency: 1, worker_concurrency: 1, cell_concurrency: 1, timeout_ms: 500, claim_ms: 1_000],
          timeout_ms: 300
        )

      id = enqueue(node, "a", "once")
      instance = node.name

      # The claim has committed and the handler has not started: the runner dies here, once.
      :telemetry.attach(
        {__MODULE__, id},
        [:atanor, :job, :started],
        &__MODULE__.kill_runner/4,
        {instance, id}
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, id}) end)
      scan(node)

      assert until(fn -> Jobs.stats(instance).running == 0 end, 5_000), "the dead process kept the slot"
      assert [["running", _]] = states(node, "a")

      # The claim expires and the alarm retries: a leaked slot would leave the job claimed for good.
      assert until(
               fn ->
                 scan(node)
                 effects(node, "a") == ["once"]
               end,
               15_000
             )
    end
  end

  describe "release_claims" do
    defp claim_row(node, key, id, by, until \\ 4_000_000_000_000) do
      {:ok, _} =
        Cell.execute(
          node.name,
          {"jobs", key},
          "UPDATE _atanor_jobs SET state = 'running', claimed_by = ?, claimed_until_ms = ?, attempts = 1 WHERE id = ?",
          [by, until, id]
        )
    end

    defp epoch(node, id) do
      {:ok, %{epoch: epoch, owner: owner}} = Alambique.lease(Atanor.Registry.config(node.name).alambique, id)
      assert owner == node()
      epoch
    end

    # A job claimed by a node that took no part in the takeover is left alone.
    test "releases the claims of the named node and no other" do
      node = start()
      dead = enqueue(node, "a", "dead-claim")
      other = enqueue(node, "a", "other-claim")
      claim_row(node, "a", dead, "dead@host")
      claim_row(node, "a", other, "other@host")

      assert {:ok, 1} = Jobs.release_claims(node.name, "jobs.a", :dead@host, epoch(node, "jobs.a"))
      assert until(fn -> effects(node, "a") == ["dead-claim"] end)

      assert {"running", "other@host"} in Enum.map(states(node, "a"), &List.to_tuple/1)
    end

    # The lease no longer reads the epoch of the takeover: the cell changed hands again.
    test "does nothing when the epoch is not the one the takeover raised" do
      node = start()
      id = enqueue(node, "a", "claimed")
      claim_row(node, "a", id, "dead@host")
      epoch = epoch(node, "jobs.a")

      assert :stale = Jobs.release_claims(node.name, "jobs.a", :dead@host, epoch + 1)
      assert :stale = Jobs.release_claims(node.name, "jobs.a", :dead@host, epoch - 1)
      Process.sleep(200)
      assert [["running", "dead@host"]] = states(node, "a")
      assert effects(node, "a") == []
    end

    test "a cell with no jobs or no claims has nothing to release" do
      node = start()
      {:ok, _} = Cell.query(node.name, {"jobs", "empty"}, "SELECT 1")
      assert {:ok, 0} = Jobs.release_claims(node.name, "jobs.empty", :dead@host, epoch(node, "jobs.empty"))
      id = enqueue(node, "a", "pending")
      assert {:ok, 0} = Jobs.release_claims(node.name, "jobs.a", :dead@host, epoch(node, "jobs.a"))
      assert id
    end
  end
end
