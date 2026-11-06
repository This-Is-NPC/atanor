defmodule Atanor.Cluster.JobsReleaseTest do
  @moduledoc """
  Releasing the claims of a node confirmed down (design §15.11): the jobs it had claimed run again at once
  on the node that takes the cell over, and never while the old node could still be running them.

  The handler (`Atanor.Test.JobWorker`, payload `file:<ms>:<dir>`) appends `start`, `beat` and `end` lines
  to a file outside the cell, so the attempts of one job on different nodes can be compared.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.ClusterCase

  alias Atanor.{Cell, Jobs}
  alias Atanor.Test.{Await, Fence, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 900_000

  @names [:n1, :n2, :n3]
  # Far above every wait in the tests: only a release can make a job run again soon.
  @claim_ms 120_000
  @detector [
    interval_ms: 200,
    phi_threshold: 8,
    min_std_ms: 50,
    acceptable_pause_ms: 600,
    indirect: [k: 2, timeout_ms: 500]
  ]
  # A node that lost its cell stops its attempt within `fence_check_ms`, `routing.owner_check_ms` and a lease read.
  @fence_ms 3_000

  defp start(opts \\ []) do
    jobs =
      Keyword.merge(
        [
          claim_ms: @claim_ms,
          timeout_ms: 60_000,
          backoff_ms: 100,
          max_backoff_ms: 100,
          concurrency: 8,
          worker_concurrency: 8,
          cell_concurrency: 1
        ],
        opts[:jobs] || []
      )

    cluster =
      start_cluster(
        names: @names,
        ttl_ms: opts[:ttl_ms] || 20_000,
        skew_margin_ms: 400,
        workers: [Manifests.jobs("jobs")],
        atanor: [
          detector: @detector,
          takeover: Keyword.get(opts, :takeover, []),
          routing: Fence.routing(owner_check_ms: 500, fence_check_ms: 300),
          alarms: [tick_ms: 100, timeout_ms: 1_000],
          jobs: jobs
        ]
      )

    for via <- Cluster.names(cluster) do
      Await.until(fn -> map_size(views(cluster, via)) == 2 end)

      Await.until(fn ->
        match?(
          {:ok, {:ok, _}},
          Cluster.call(cluster, via, Atanor.Registry, :deployment, [Cluster.instance(cluster), "jobs"])
        )
      end)
    end

    dir = Path.join(System.tmp_dir!(), "atanor-release-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {cluster, dir}
  end

  defp query(cluster, via, key, sql, params \\ []) do
    case Cluster.call(cluster, via, Cell, :query, [Cluster.instance(cluster), {"jobs", key}, sql, params]) do
      {:ok, {:ok, %{rows: rows}}} -> rows
      _ -> nil
    end
  end

  # A cell owned by a peer other than `n1` whose jobs the owner itself claims and runs. The alarm shard of a
  # cell decides which node scans for its jobs (design §7.4), and that is not always the owner; a runner
  # on another node that survives the owner would retry the job itself, and the release could not be
  # told from that retry. A short probe job tells who runs the jobs of a cell.
  defp job_cell(cluster, dir) do
    Enum.find_value(1..40, fn i ->
      key = "j#{i}"
      [[1]] = Await.until(fn -> query(cluster, :n1, key, "SELECT 1") end)
      {:ok, node} = owner(cluster, :n1, "jobs", key)
      owner = name_of(cluster, node)

      if owner in [:n2, :n3] do
        probe = enqueue(cluster, :n1, key, dir, 0)
        started = Await.until(fn -> Enum.find(events(cluster, [:atanor, :job, :started]), &(&1.meta.id == probe)) end)
        if name_of(cluster, started.meta.node) == owner, do: {key, owner}
      end
    end)
  end

  defp enqueue(cluster, via, key, dir, ms) do
    spec = %{kind: "test", payload: "file:#{ms}:#{dir}"}

    case Cluster.call(cluster, via, Jobs, :enqueue_direct, [Cluster.instance(cluster), "jobs", {"jobs", key}, spec]) do
      {:ok, {:ok, id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  # [{"start" | "beat" | "end", node, ms}] in the order written.
  defp lines(dir, id) do
    case File.read(Path.join(dir, id)) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true) do
          [what, node, ms] = String.split(line, " ")
          {what, node, String.to_integer(ms)}
        end

      _ ->
        []
    end
  end

  defp starts(dir, id), do: for({"start", node, ms} <- lines(dir, id), do: {node, ms})
  defp ends(dir, id), do: for({"end", node, ms} <- lines(dir, id), do: {node, ms})

  defp state(cluster, via, key, id) do
    case query(cluster, via, key, "SELECT state FROM _atanor_jobs WHERE id = ?", [id]) do
      [[state]] -> state
      _ -> nil
    end
  end

  defp released(cluster), do: events(cluster, [:atanor, :job, :released])

  # The first call on the cell from a survivor takes it over (design §8.10).
  defp touch(cluster, via, key) do
    Await.until(fn -> query(cluster, via, key, "SELECT 1") end, 60_000)
  end

  # A cell whose jobs are awaited by a node other than its owner, so that every attempt is forwarded.
  defp forwarded_cell(cluster, dir) do
    Enum.find_value(1..40, fn i ->
      key = "f#{i}"
      [[1]] = Await.until(fn -> query(cluster, :n1, key, "SELECT 1") end)
      {:ok, node} = owner(cluster, :n1, "jobs", key)
      probe = enqueue(cluster, :n1, key, dir, 0)
      started = Await.until(fn -> Enum.find(events(cluster, [:atanor, :job, :started]), &(&1.meta.id == probe)) end)
      owner = name_of(cluster, node)
      runner = name_of(cluster, started.meta.node)
      if runner != owner, do: {key, owner, runner}
    end)
  end

  describe "a node confirmed down" do
    test "its job runs again at once on the new owner, once to the end" do
      {cluster, dir} = start()
      {key, victim} = job_cell(cluster, dir)
      [survivor | _] = @names -- [victim]
      id = enqueue(cluster, survivor, key, dir, 4_000)
      Await.until(fn -> length(lines(dir, id)) >= 2 end, 20_000)
      assert [{first, _}] = starts(dir, id)
      assert first == Atom.to_string(Cluster.node(cluster, victim))

      t0 = now()
      Cluster.kill_process(cluster, victim)
      await_event(cluster, survivor, :down, victim)
      touch(cluster, survivor, key)
      Await.until(fn -> length(starts(dir, id)) == 2 end, 30_000)

      # Released by the takeover, not by the claim, which lasts #{@claim_ms} ms.
      assert ms_since(t0, %{at: now()}) < @claim_ms / 4
      assert [event] = Await.until(fn -> match?([_], released(cluster)) && released(cluster) end)
      assert event.meta.from == Cluster.node(cluster, victim)
      assert event.meta.cell == {"jobs", key}
      assert event.measurements.count == 1
      assert [_, {second, _}] = starts(dir, id)
      assert second != first

      Await.until(fn -> state(cluster, survivor, key, id) == "done" end, 30_000)
      assert [{^second, _}] = ends(dir, id)
      assert [[1]] = query(cluster, survivor, key, "SELECT count(*) FROM effects WHERE job_id = ?", [id])
    end

    test "release_claims false leaves the job to its claim" do
      {cluster, dir} = start(jobs: [release_claims: false])
      {key, victim} = job_cell(cluster, dir)
      [survivor | _] = @names -- [victim]
      id = enqueue(cluster, survivor, key, dir, 4_000)
      Await.until(fn -> length(lines(dir, id)) >= 2 end, 20_000)

      Cluster.kill_process(cluster, victim)
      await_event(cluster, survivor, :down, victim)
      touch(cluster, survivor, key)
      # Both survivors may ask for the cell; one takeover wins, the other finds it taken.
      assert [_ | _] =
               events(
                 cluster,
                 [:atanor, :cell, :take_over],
                 &(&1.cell == "jobs." <> key and &1.node == Cluster.node(cluster, victim) and &1.result == :ok)
               )

      # The negative case has no event to wait for: the job would have started within a second.
      Process.sleep(5_000)
      assert length(starts(dir, id)) == 1
      assert released(cluster) == []
      assert state(cluster, survivor, key, id) == "running"
    end
  end

  test "a node that is only link_broken keeps its job and nothing is released" do
    {cluster, dir} = start()
    {key, owner} = job_cell(cluster, dir)
    id = enqueue(cluster, :n1, key, dir, 3_000)
    Await.until(fn -> length(lines(dir, id)) >= 2 end, 20_000)

    # The owner runs the job itself. The cut is between the owner and n1, which still reaches it through
    # the third node.
    Cluster.partition_nodes(cluster, :n1, owner)
    await_event(cluster, :n1, :link_broken, owner)
    # Whatever n1 asks, it may not take the cell: the owner is alive and reachable by others.
    query(cluster, :n1, key, "SELECT 1")

    Await.until(fn -> state(cluster, owner, key, id) == "done" end, 30_000)
    assert [{_, _}] = starts(dir, id)
    assert [{_, _}] = ends(dir, id)
    assert released(cluster) == []
    assert events_about(cluster, [:down]) == []
    assert events(cluster, [:atanor, :cell, :take_over]) == []
  end

  test "a frozen node that comes back loses its attempt, and the new owner starts the job once" do
    {cluster, dir} = start()
    {key, victim} = job_cell(cluster, dir)
    [survivor | _] = @names -- [victim]
    id = enqueue(cluster, survivor, key, dir, 10_000)
    Await.until(fn -> length(lines(dir, id)) >= 2 end, 20_000)
    victim_name = Atom.to_string(Cluster.node(cluster, victim))

    Cluster.pause(cluster, victim)
    await_event(cluster, survivor, :down, victim)
    touch(cluster, survivor, key)
    Await.until(fn -> length(starts(dir, id)) == 2 end, 30_000)
    assert [{^victim_name, _}, {second, _}] = starts(dir, id)
    assert second != victim_name

    thawed = System.os_time(:millisecond)
    Cluster.resume(cluster, victim)

    # The thawed node notices that it lost the cell and stops the attempt. Nothing is observable when it
    # stops, so the test waits the bound out.
    Process.sleep(@fence_ms + 1_000)
    old = attempt_lines(lines(dir, id), victim_name)
    assert Enum.all?(old, fn {_, ms} -> ms <= thawed + @fence_ms end), "the old attempt ran on after the takeover"
    assert for({"end", _} <- old, do: :end) == []
  end

  test "the claim of a runner that dies after claiming expires and the job runs again" do
    {cluster, dir} = start(jobs: [claim_ms: 8_000, timeout_ms: 5_000])
    {key, owner, runner} = forwarded_cell(cluster, dir)
    id = enqueue(cluster, owner, key, dir, 1_000)
    Await.until(fn -> lines(dir, id) != [] end, 20_000)

    # The runner awaits the attempt, which the owner runs. Its death loses the result, not the claim.
    Cluster.kill(cluster, runner)

    Await.until(fn -> state(cluster, owner, key, id) == "done" end, 60_000)
    assert [_, _] = starts(dir, id)
  end

  # A short lease, so the deadline of the fence comes soon after the node is cut off.
  @fence_ttl_ms 4_000
  @fence_margin_ms 400
  # The handler beats every 100 ms. The kill is a timer set to the deadline: it is late by the timer, the
  # scheduler and the kill, a few milliseconds when the machine is idle; 100 ms leaves room for a loaded one.
  @fence_tolerance_ms 100

  test "a node cut off from the store and its peers stops its attempt by its lease deadline, and the job " <>
         "runs to the end on the new owner without overlap" do
    {cluster, dir} = start(ttl_ms: @fence_ttl_ms)

    {key, victim} = job_cell(cluster, dir)
    [survivor | _] = @names -- [victim]
    id = enqueue(cluster, survivor, key, dir, 8_000)
    Await.until(fn -> length(lines(dir, id)) >= 2 end, 20_000)
    victim_name = Atom.to_string(Cluster.node(cluster, victim))
    Process.sleep(500)

    # The lease as the store has it when the node is cut off. Renewals after it only make the fence stricter.
    {:ok, cell_id} = Cell.id({"jobs", key})
    cells = Module.concat(Cluster.instance(cluster), Cells)
    {:ok, {:ok, lease}} = Cluster.call(cluster, survivor, Alambique, :lease, [cells, cell_id])
    deadline = lease.expires_at_ms - @fence_margin_ms

    Cluster.partition_store(cluster, victim)
    for other <- @names -- [victim], do: Cluster.partition_nodes(cluster, victim, other)

    # At once: once the old lease has expired, the cell is taken the ordinary way and nothing releases the claim.
    touch(cluster, survivor, key)
    Await.until(fn -> System.os_time(:millisecond) > deadline + 1_000 end, 30_000)
    old = attempt_lines(lines(dir, id), victim_name)
    {"beat", last} = List.last(old)
    assert last <= deadline + @fence_tolerance_ms, "the attempt ran #{last - deadline} ms after its deadline"
    assert for({"end", _} <- old, do: :end) == []

    assert [event] = events(cluster, [:atanor, :handler, :fenced], &(&1.cell == {"jobs", key}))
    assert event.meta.kind == :job
    assert event.meta.reason == :local_deadline

    # The others take the cell over early (design §8.10) and start the job only once the old lease has
    # expired on their clocks plus the margin (design §8.13).
    await_event(cluster, survivor, :down, victim)
    Await.until(fn -> length(starts(dir, id)) == 2 end, 30_000)
    [{^victim_name, _}, {second, again}] = starts(dir, id)
    assert second != victim_name
    assert again > last, "the new owner started #{last - again} ms before the old one stopped"
    assert again > deadline, "the new owner started #{deadline - again} ms before the old deadline"
    assert again >= lease.expires_at_ms + @fence_margin_ms, "the new owner started before the old lease expired"

    Cluster.heal_all(cluster)
    Await.until(fn -> state(cluster, survivor, key, id) == "done" end, 60_000)
    assert [{^second, _}] = ends(dir, id)
  end

  # The lines of the first attempt of `node`: up to its next start.
  defp attempt_lines(lines, node) do
    mine = for {what, ^node, ms} <- lines, do: {what, ms}
    [start | rest] = mine
    [start | Enum.take_while(rest, fn {what, _} -> what != "start" end)]
  end

  describe "property" do
    @cells ["r0", "r1", "r2"]
    @job_ms 4_000
    # The claim of a job whose cell nobody touches expires; the release must come first or be absent.
    @short_claim_ms 15_000

    defp op do
      node = member_of(@names)
      pair = member_of([{:n1, :n2}, {:n1, :n3}, {:n2, :n3}])

      frequency([
        {8, tuple({constant(:enqueue), node, member_of(@cells)})},
        {3, tuple({constant(:touch), node, member_of(@cells)})},
        {3, tuple({constant(:kill), node})},
        {2, tuple({constant(:restart), node})},
        {3, tuple({constant(:lose), node})},
        {2, tuple({constant(:cut), pair})},
        {2, tuple({constant(:mend), pair})},
        {3, tuple({constant(:pass), integer(200..1500)})}
      ])
    end

    property "no job runs twice after a release unless the old owner was taken over and fenced" do
      check all(
              ops <- resize(list_of(op(), min_length: 10, max_length: 18), 18),
              max_runs: 8,
              max_shrinking_steps: 0
            ) do
        run_ops(ops)
      end
    end

    test "a sequence of freezes, kills and restarts that once left a job undone" do
      run_ops([
        {:restart, :n1},
        {:touch, :n3, "r2"},
        {:cut, {:n2, :n3}},
        {:lose, :n1},
        {:pass, 1323},
        {:lose, :n2},
        {:enqueue, :n3, "r1"},
        {:lose, :n2},
        {:lose, :n2},
        {:kill, :n3},
        {:restart, :n1},
        {:enqueue, :n3, "r0"},
        {:kill, :n3},
        {:touch, :n2, "r1"},
        {:enqueue, :n2, "r0"},
        {:mend, {:n2, :n3}},
        {:enqueue, :n1, "r0"},
        {:enqueue, :n2, "r1"}
      ])
    end

    defp run_ops(ops) do
      # Every cell has a job in flight when the faults start.
      ops = for({key, node} <- Enum.zip(@cells, [:n1, :n2, :n3]), do: {:enqueue, node, key}) ++ ops
      {cluster, dir} = start(jobs: [claim_ms: @short_claim_ms, timeout_ms: 10_000])
      run = %{jobs: [], dead: MapSet.new(), cut: [], thaws: []}

      try do
        run = Enum.reduce(ops, run, &step(cluster, dir, &1, &2))
        settle(cluster, run)
        verify(cluster, dir, run)
      after
        Process.unlink(cluster)
        Cluster.stop(cluster)
      end
    end

    defp up?(run, node), do: node not in run.dead

    defp step(cluster, dir, {:enqueue, node, key}, run) do
      with true <- up?(run, node), id when is_binary(id) <- enqueue(cluster, node, key, dir, @job_ms) do
        %{run | jobs: [{key, id} | run.jobs]}
      else
        _ -> run
      end
    end

    defp step(cluster, _dir, {:touch, node, key}, run) do
      if up?(run, node), do: query(cluster, node, key, "SELECT 1")
      run
    end

    defp step(cluster, _dir, {:kill, node}, run) do
      unless not up?(run, node), do: Cluster.kill(cluster, node)
      %{run | dead: MapSet.put(run.dead, node)}
    end

    defp step(cluster, _dir, {:restart, node}, run) do
      unless up?(run, node) do
        Cluster.heal_store(cluster, node)
        Cluster.restart(cluster, node)
      end

      %{run | dead: MapSet.delete(run.dead, node)}
    end

    # Frozen until a survivor has it down; the survivors take its cells over; then it wakes up.
    defp step(cluster, _dir, {:lose, node}, run) do
      survivors = Enum.filter(@names -- [node], &up?(run, &1))

      if up?(run, node) and length(survivors) == 2 do
        Cluster.pause(cluster, node)

        down? =
          Enum.any?(1..100, fn _ ->
            Process.sleep(100)
            Enum.any?(survivors, &(views(cluster, &1) |> Map.get(node) |> then(fn v -> v && v.state == :down end)))
          end)

        if down?, do: for(key <- @cells, do: query(cluster, hd(survivors), key, "SELECT 1"))
        Cluster.resume(cluster, node)
        %{run | thaws: [{Atom.to_string(Cluster.node(cluster, node)), System.os_time(:millisecond)} | run.thaws]}
      else
        run
      end
    end

    defp step(cluster, _dir, {:cut, {a, b}}, run) do
      if up?(run, a) and up?(run, b), do: Cluster.partition_nodes(cluster, a, b)
      run
    end

    defp step(cluster, _dir, {:mend, {a, b}}, run) do
      if up?(run, a) and up?(run, b), do: Cluster.heal_nodes(cluster, a, b)
      run
    end

    defp step(_cluster, _dir, {:pass, ms}, run), do: tap(run, fn _ -> Process.sleep(ms) end)

    defp settle(cluster, run) do
      Cluster.heal_all(cluster)
      for node <- run.dead, do: Cluster.restart(cluster, node)
    end

    defp verify(cluster, dir, run) do
      jobs = Enum.reverse(run.jobs)

      # Every acknowledged job ends in the cell, with one effect, when the cells are served again.
      for {key, id} <- jobs, do: await_done(cluster, key, id)

      for {key, id} <- jobs do
        check_job(cluster, dir, run, key, id)
      end

      IO.puts(
        "release property: #{length(jobs)} jobs, #{Enum.count(jobs, fn {_, id} -> length(starts(dir, id)) > 1 end)} " <>
          "ran again, #{length(released(cluster))} releases"
      )
    end

    defp await_done(cluster, key, id) do
      Await.until(
        fn -> Enum.find_value(@names, fn via -> state(cluster, via, key, id) == "done" or nil end) end,
        120_000
      )
    rescue
      e in ExUnit.AssertionError ->
        seen =
          for via <- @names do
            row =
              query(
                cluster,
                via,
                key,
                "SELECT id, state, claimed_by, claimed_until_ms, attempts, due_at_ms FROM _atanor_jobs",
                []
              )

            {via, row, Map.new(views(cluster, via), fn {n, v} -> {n, v.state} end)}
          end

        alarm = query(cluster, :n1, key, "SELECT worker, at_ms, attempts FROM _atanor_alarms")
        instance = Cluster.instance(cluster)

        index = Cluster.call(cluster, :n1, Atanor.Test.AlarmIndex, :keys, [instance, "." <> key])

        reraise %{
                  e
                  | message:
                      "job #{id} of #{key} is not done: #{inspect(seen)}; alarm rows #{inspect(alarm)}; index #{inspect(index)}; now #{System.os_time(:millisecond)}"
                },
                __STACKTRACE__
    end

    defp check_job(cluster, dir, run, key, id) do
      attempts = starts(dir, id)
      assert attempts != [], "job #{id} never started"
      ls = lines(dir, id)
      cell = {"jobs", key}
      evidence = released(cluster)

      # A start after the first needs a release in the cell (a takeover raised the epoch and fenced the node
      # whose claim it was; that node is the runner, which is not always the one the handler ran on), a retry
      # by a surviving runner, or an expired claim.
      # A claim is announced by `:started` on the runner, before its handler starts.
      claims = events(cluster, [:atanor, :job, :started], &(&1.id == id)) |> Enum.sort_by(& &1.at)
      claim_of = fn ms -> claims |> Enum.filter(&(div(&1.at, 1000) <= ms)) |> List.last() end

      attempts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{previous, was}, {_next, at}] ->
        first = claim_of.(was)
        again = claim_of.(at)
        assert first != again, "job #{id} started twice under one claim (#{was} and #{at} ms, on #{previous})"

        released? =
          Enum.any?(evidence, fn e ->
            e.meta.cell == cell and div(e.at, 1000) in (was - 100)..(at + 200)
          end)

        # A runner on a node that survived the owner retries the job when its attempt fails.
        retried? =
          Enum.any?(
            events(cluster, [:atanor, :job, :finished], &(&1.id == id and &1.result == :error)),
            &(div(&1.at, 1000) in (was - 100)..(at + 200))
          )

        # The claim itself is the evidence: the next one is written only once the lease has expired.
        expired? = first != nil and again != nil and div(again.at, 1000) >= first.meta.claimed_until_ms - 1

        # The runner could not tell whether the write that ended the attempt applied: it did, and the job
        # was pending again (design §15.4).
        unconfirmed? =
          Enum.any?(
            events(cluster, [:atanor, :job, :unconfirmed], &(&1.id == id)),
            &(div(&1.at, 1000) in (was - 100)..(at + 200))
          )

        # The release follows the takeover of the claimant's node and is done in the background: the node that
        # does it can be killed after it committed and before it reports, so the takeover is the evidence.
        taken? =
          first != nil and again != nil and
            Enum.any?(
              events(
                cluster,
                [:atanor, :cell, :take_over],
                &(&1.cell == "jobs." <> key and &1.result == :ok and &1.node == first.meta.node)
              ),
              &(div(&1.at, 1000) in div(first.at, 1000)..div(again.at, 1000))
            )

        # The attempt failed with an unknown outcome (the owner was lost while the runner awaited it) and its
        # finish write, which puts the job back to pending, is made by the runner. If the runner stops right
        # after that write commits, nothing is reported (design §15.4).
        failed_forward? =
          first != nil and again != nil and
            Enum.any?(
              events(
                cluster,
                [:atanor, :forward],
                &(&1.cell == cell and &1.result == :unknown_outcome)
              ),
              &(&1.node == name_of(cluster, first.meta.node) and
                  div(&1.at, 1000) in div(first.at, 1000)..div(again.at, 1000))
            )

        if unconfirmed? and not (released? or taken? or retried? or expired?),
          do: IO.puts("release property: job #{id} started again after an unconfirmed finish (no other evidence)")

        assert released? or taken? or retried? or unconfirmed? or failed_forward? or expired?,
               "job #{id} started again on another attempt after #{at - was} ms with no release in the cell " <>
                 "(the previous attempt ran on #{previous}); events: " <>
                 inspect(
                   for(
                     e <- Cluster.events(cluster),
                     e.event in [
                       [:atanor, :job, :started],
                       [:atanor, :job, :finished],
                       [:atanor, :job, :released],
                       [:atanor, :job, :unconfirmed],
                       [:atanor, :cell, :take_over],
                       [:atanor, :forward]
                     ],
                     div(e.at, 1000) in (was - 3_000)..(at + 500),
                     e.meta[:cell] in [cell, "jobs." <> key],
                     do:
                       {e.node, e.event, div(e.at, 1000) - was, e.meta[:id], e.meta[:result], e.meta[:reason],
                        e.meta[:target], e.meta[:attempt], e.meta[:claimed_until_ms]}
                   ),
                   limit: :infinity
                 )
      end)

      # The attempt of a node that lost the cell stops within the fence bound of the next start, or of the
      # node's return from a freeze.
      for {{node, was}, {_, next}} <- Enum.zip(attempts, tl(attempts)) do
        thaw = Enum.min(for({^node, ms} <- run.thaws, ms >= next, do: ms), fn -> next end)
        again = Enum.find_value(attempts, :infinity, fn {n, ms} -> if n == node and ms > was, do: ms end)
        late = for {_, ^node, ms} <- ls, ms >= was, ms < again, ms > max(next, thaw) + @fence_ms, do: ms
        assert late == [], "job #{id}: the attempt of #{node} ran on #{inspect(late)} after #{next}"
      end
    end
  end
end
