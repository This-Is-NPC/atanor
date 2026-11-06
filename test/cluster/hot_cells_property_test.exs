defmodule Atanor.Cluster.HotCellsPropertyTest do
  @moduledoc """
  **H1.** Automatic movement never leaves two owners and never loses a confirmed write (design §8.15).

  Three peers run the placement loop with short windows. Background writers send increments to three
  counter cells through random live nodes the whole time, while random steps keep a node under CPU load
  (so its hot cells move off it), move cells by hand, and kill and restart nodes. Every run first loads the
  owner of a cell until the loop has moved a cell by itself, so the property is not vacuous. After the
  cluster is healed:

    * every acknowledged increment is in its cell exactly once, and none that nobody sent;
    * the checks of C1 (`Atanor.Test.C1`): a request ran where its batch committed, acknowledged requests
      for one cell do not overlap in time on different nodes unless a move or a takeover explains it, and
      one epoch is acknowledged by one node, in order;
    * the loop kept to its rules: no cell moved twice by it within the residence time, one cell never moves twice
      at once, and the cluster cap holds within the announcement delay.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Busy, C1, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 900_000

  @names [:n1, :n2, :n3]
  @cells ["c0", "c1", "c2"]
  @ttl_ms 2_000
  @skew_ms 400
  @available_within_ms @ttl_ms + @skew_ms + 10_000
  @owner_check_ms 500
  @window_ms @owner_check_ms + 1_000
  @detector [
    interval_ms: 200,
    phi_threshold: 8,
    min_std_ms: 50,
    acceptable_pause_ms: 600,
    indirect: [k: 2, timeout_ms: 500]
  ]
  @residence_ms 2_500
  # Generous for a loaded host: the delay of a `{:moving, ...}` message between peers.
  @announce_ms 1_000
  @hot [
    enabled: true,
    # The peers share one machine, so the machine's CPU would be the same for all of them.
    os_cpu: false,
    interval_ms: 200,
    sustain_ms: 600,
    write_enter: 5,
    write_exit: 2,
    cpu_enter: 60,
    cpu_exit: 40,
    margin: 20,
    residence_ms: @residence_ms,
    node_cooldown_ms: 500,
    max_moves: 1,
    stale_ms: 1_500
  ]

  defp op do
    frequency([
      {4, tuple({constant(:hog), member_of(@names), integer(1_500..4_000)})},
      {4, tuple({constant(:move), member_of(@names), member_of(@cells)})},
      {1, tuple({constant(:kill), member_of(@names)})},
      {2, tuple({constant(:restart), member_of(@names)})},
      {6, tuple({constant(:pass), integer(200..1_500)})}
    ])
  end

  property "automatic movement keeps one owner and loses no confirmed write" do
    check all(ops <- resize(list_of(op(), min_length: 8, max_length: 16), 16), max_runs: 6, max_shrinking_steps: 0) do
      cluster =
        start_cluster(
          names: @names,
          ttl_ms: @ttl_ms,
          skew_margin_ms: @skew_ms,
          atanor: [detector: @detector, routing: [owner_check_ms: @owner_check_ms], hot_cells: @hot],
          workers: [Manifests.counter("counter")]
        )

      {:ok, alive} = Agent.start_link(fn -> @names end)
      seq = :atomics.new(1, [])

      try do
        writers = for cell <- @cells, do: Task.async(fn -> write_loop(cluster, alive, seq, cell, []) end)
        load_until_moved(cluster)
        Enum.reduce(ops, MapSet.new(), &step(cluster, alive, &1, &2))

        requests = Enum.flat_map(writers, fn task -> stop(task) end)
        for node <- @names -- Agent.get(alive, & &1), do: restart(cluster, node)
        Cluster.heal_all(cluster)
        verify(cluster, requests)
      after
        Agent.stop(alive)
        Process.unlink(cluster)
        Cluster.stop(cluster)
      end
    end
  end

  # One increment at a time on a cell through a live node, until told to stop.
  defp write_loop(cluster, alive, seq, cell, done) do
    receive do
      :stop -> done
    after
      30 ->
        n = :atomics.add_get(seq, 1, 1)
        node = Enum.random(Agent.get(alive, & &1))

        outcome =
          case request(cluster, node, :post, "/c/#{cell}", body: Integer.to_string(n)) do
            {:ok, %{status: 200, body: body}} -> {:acked, Jason.decode!(body)}
            _ -> :unknown
          end

        write_loop(cluster, alive, seq, cell, [%{n: n, cell: cell, outcome: outcome} | done])
    end
  end

  defp stop(task) do
    send(task.pid, :stop)
    Task.await(task, 30_000)
  end

  # Keeps the owner of a cell busy until the loop has moved a cell by itself.
  defp load_until_moved(cluster) do
    Atanor.Test.Await.until(
      fn ->
        now = System.monotonic_time(:millisecond)

        last = Process.get(:hogged)
        if (last == nil or now - last >= 5_000) and hog_owner(cluster, "c0", 5_000), do: Process.put(:hogged, now)

        automatic(cluster) != []
      end,
      90_000
    )
  end

  defp hog_owner(cluster, cell, ms) do
    case owner(cluster, :n1, "log", cell) do
      {:ok, node} -> match?({:ok, :ok}, Cluster.call(cluster, name_of(cluster, node), Busy, :spin, [ms]))
      _ -> false
    end
  end

  defp step(cluster, alive, {:hog, node, ms}, dead) do
    if Agent.get(alive, &(node in &1)), do: Cluster.call(cluster, node, Busy, :spin, [ms])
    dead
  end

  defp step(cluster, alive, {:move, via, cell}, dead) do
    live = Agent.get(alive, & &1)

    if via in live do
      with {:ok, current} <- owner(cluster, via, "log", cell),
           from = name_of(cluster, current),
           true <- from in live,
           [target | _] <- Enum.shuffle(live -- [from]) do
        Cluster.call(cluster, from, Atanor.HotCells, :move, [
          Cluster.instance(cluster),
          {"log", cell},
          Cluster.node(cluster, target)
        ])
      end
    end

    dead
  end

  defp step(cluster, alive, {:kill, node}, dead) do
    live = Agent.get(alive, & &1)

    if node in live and length(live) > 2 do
      Agent.update(alive, &(&1 -- [node]))
      Cluster.kill(cluster, node)
    end

    dead
  end

  defp step(cluster, alive, {:restart, node}, dead) do
    unless node in Agent.get(alive, & &1), do: restart(cluster, node) && Agent.update(alive, &[node | &1])
    dead
  end

  defp step(_cluster, _alive, {:pass, ms}, dead), do: tap(dead, fn _ -> Process.sleep(ms) end)

  defp restart(cluster, node), do: Cluster.restart(cluster, node)

  defp moves(cluster), do: events(cluster, [:atanor, :hot_cell, :move])

  defp automatic(cluster),
    do: Enum.filter(moves(cluster), &(&1.meta.reason in [:load, :affinity] and &1.meta.result == :ok))

  defp verify(cluster, requests) do
    rows =
      for cell <- @cells, into: %{}, do: {cell, C1.read_when_available(cluster, @names, cell, @available_within_ms)}

    all_moves = moves(cluster)

    for cell <- @cells do
      mine = Enum.filter(requests, &(&1.cell == cell))
      attempted = Enum.map(mine, & &1.n)
      acked = for %{outcome: {:acked, _}, n: n} <- mine, do: n
      stored = rows[cell]

      assert stored == Enum.uniq(stored), "cell #{cell} applied an increment twice: #{inspect(stored)}"
      assert stored -- attempted == [], "cell #{cell} has increments nobody sent"
      assert acked -- stored == [], "cell #{cell} lost acknowledged increments #{inspect(acked -- stored)}"

      C1.check_placement(cluster, cell, mine, &explained!(cluster, cell, &1, &2, all_moves))
    end

    C1.check_epochs(Cluster.events(cluster))
    check_rules(automatic(cluster))

    unknown = Enum.count(requests, &(&1.outcome == :unknown))

    IO.puts(
      "H1: #{length(requests)} requests, #{length(requests) - unknown} acknowledged, #{unknown} without an answer, " <>
        "#{length(automatic(cluster))} automatic and #{length(all_moves) - length(automatic(cluster))} other moves"
    )
  end

  # A handler that ran on another node than its commit overlapped a move of the cell, or a takeover (a node
  # that was killed) at most `@window_ms` before.
  defp explained!(cluster, cell, n, body, moves) do
    [from, to] = [body["from"], body["to"]]

    moved? =
      Enum.any?(moves, fn e ->
        e.meta.cell == {"log", cell} and e.at >= from and e.at - div(e.measurements.duration, 1_000) <= to
      end)

    taken? =
      cluster
      |> events([:alambique, :lease, :take_over], &(&1.cell == "log." <> cell and &1.result == :ok))
      |> Enum.any?(&(&1.at >= from - @window_ms * 1_000 and &1.at <= to))

    assert moved? or taken?, "increment #{n} of #{cell} ran on #{body["node"]} and committed on #{body["tx_node"]}"
  end

  # The moves the loop made by itself: a cell stays `@residence_ms` where it moved, and two never overlap.
  defp check_rules(moves) do
    spans = for e <- moves, do: %{cell: e.meta.cell, from: e.at - div(e.measurements.duration, 1_000), to: e.at}

    for {cell, same} <- Enum.group_by(spans, & &1.cell),
        [a, b] <- Enum.chunk_every(Enum.sort_by(same, & &1.from), 2, 1, :discard) do
      assert b.from - a.to >= @residence_ms * 1_000 - 50_000,
             "#{inspect(cell)} moved again #{div(b.from - a.to, 1_000)} ms after it moved (residence #{@residence_ms})"
    end

    # One cell never moves twice at once (safety), whatever the latency. The cap on moves in progress (design
    # §8.15) is exact except for two nodes that decide within the delay of the `:moving` announcement, so two
    # moves of different cells may overlap only when the later one started within `@announce_ms` of the other.
    for a <- spans, b <- spans, a != b, a.from <= b.from, a.from < b.to and b.from < a.to do
      refute a.cell == b.cell, "two automatic moves of #{inspect(a.cell)} ran at the same time: #{inspect({a, b})}"

      assert b.from - a.from <= @announce_ms * 1_000,
             "two automatic moves ran at the same time, the second #{div(b.from - a.from, 1_000)} ms after the " <>
               "first started (announcement tolerance #{@announce_ms} ms): #{inspect({a, b})}"
    end
  end
end
