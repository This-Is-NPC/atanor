defmodule Atanor.Cluster.AlarmsTest do
  @moduledoc """
  Alarms across real nodes (design §7.4, §8): they fire on the node that owns
  the cell, shards move to the surviving schedulers when a node dies, each
  committed alarm fires at least once, and duplicates are bounded.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{AlarmWorker, Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 600_000

  @names [:n1, :n2, :n3]
  @ttl_ms 2_000
  @max_attempts 5

  defp start(opts \\ []) do
    manifest =
      Manifests.probe("alarms",
        module: AlarmWorker,
        cells: %{"clock" => AlarmWorker.migrations()},
        alarms: true,
        routes: [{"127.0.0.1", "/"}]
      )

    start_cluster(
      [
        names: @names,
        ttl_ms: @ttl_ms,
        skew_margin_ms: 400,
        workers: [manifest],
        atanor: [alarms: [tick_ms: 200, timeout_ms: 2_000, max_attempts: @max_attempts]]
      ] ++ opts
    )
  end

  defp set(cluster, node, key, delay_ms, payload) do
    at = System.os_time(:millisecond) + delay_ms

    case request(cluster, node, :get, "/set", params: [key: key, at: at, payload: payload]) do
      {:ok, %{status: 200, body: ":ok"}} -> true
      _ -> false
    end
  end

  # How many times the alarm of a cell ran its handler, or nil while the cell is unreachable.
  defp fires(cluster, key) do
    Enum.find_value(@names, fn node ->
      args = [Cluster.instance(cluster), {"clock", key}, "SELECT count(*) FROM fires"]

      with true <- Cluster.alive?(cluster, node),
           {:ok, {:ok, %{rows: [[count]]}}} <- Cluster.call(cluster, node, Atanor.Cell, :query, args) do
        count
      else
        _ -> nil
      end
    end)
  end

  test "an alarm fires on the node that owns its cell, whichever node's scheduler found it" do
    cluster = start()
    keys = for i <- 1..12, do: "k#{i}"
    for key <- keys, do: assert(set(cluster, :n1, key, 300, "p-#{key}"))

    Await.until(fn -> Enum.all?(keys, &((fires(cluster, &1) || 0) >= 1)) end, 20_000)

    for key <- keys do
      {:ok, owner} = owner(cluster, :n1, "clock", key)
      fired = events(cluster, [:atanor, :call], &(&1.kind == :alarm and &1.cell == {"clock", key}))
      assert fired != []
      assert Enum.all?(fired, &(&1.meta.node == owner))
    end

    all = events(cluster, [:atanor, :call], &(&1.kind == :alarm))
    assert Enum.any?(all, & &1.meta.forwarded), "the scheduler of some shard should not own its cell"
  end

  test "the shards of a node that dies move to the others" do
    cluster = start()
    Cluster.kill(cluster, :n1)

    keys = for i <- 1..12, do: "d#{i}"
    for key <- keys, do: assert(set(cluster, :n2, key, 300, "p-#{key}"))

    # The cells of the dead node wait for their lease to run out.
    Await.until(fn -> Enum.all?(keys, &((fires(cluster, &1) || 0) >= 1)) end, 45_000)
    assert Enum.all?(keys, &(fires(cluster, &1) <= @max_attempts))
  end

  defp alarm_op do
    node = member_of(@names)

    frequency([
      {10, tuple({constant(:set), node, integer(200..2500)})},
      {3, tuple({constant(:kill), node})},
      {3, tuple({constant(:restart), node})},
      {1, tuple({constant(:partition_store), node})},
      {1, tuple({constant(:heal_store), node})},
      {4, tuple({constant(:pass), integer(100..1200)})}
    ])
  end

  property "each committed alarm fires at least once across node failures, with bounded duplicates" do
    check all(
            ops <- resize(list_of(alarm_op(), min_length: 15, max_length: 30), 30),
            max_runs: 6,
            max_shrinking_steps: 0
          ) do
      cluster = start()

      try do
        run = Enum.reduce(ops, %{seq: 0, committed: [], dead: MapSet.new()}, &step(cluster, &1, &2))
        Cluster.heal_all(cluster)
        for node <- run.dead, do: Cluster.restart(cluster, node)

        counts =
          Map.new(run.committed, fn key ->
            {key, Await.until(fn -> fires(cluster, key) end, 60_000)}
          end)

        # A committed alarm has to fire, even if its first firing died with a node.
        Await.until(fn -> Enum.all?(run.committed, &((fires(cluster, &1) || 0) >= 1)) end, 60_000)

        total = for key <- run.committed, do: fires(cluster, key)
        assert Enum.all?(total, &(&1 <= @max_attempts)), "duplicates beyond the attempts: #{inspect(total)}"

        IO.puts(
          "alarms: #{length(run.committed)} committed, #{Enum.sum(total) - length(total)} duplicate firings, " <>
            "#{map_size(counts)} cells read"
        )
      after
        Process.unlink(cluster)
        Cluster.stop(cluster)
      end
    end
  end

  defp step(cluster, {:set, node, delay}, run) do
    key = "a#{run.seq + 1}"
    run = %{run | seq: run.seq + 1}
    if set(cluster, node, key, delay, "p-#{key}"), do: %{run | committed: [key | run.committed]}, else: run
  end

  defp step(cluster, {:kill, node}, run) do
    unless node in run.dead, do: Cluster.kill(cluster, node)
    %{run | dead: MapSet.put(run.dead, node)}
  end

  defp step(cluster, {:restart, node}, run) do
    # A node that cannot read the store does not start (design §2.1), so its partition ends first.
    if node in run.dead do
      Cluster.heal_store(cluster, node)
      Cluster.restart(cluster, node)
    end

    %{run | dead: MapSet.delete(run.dead, node)}
  end

  defp step(cluster, {:partition_store, node}, run), do: tap(run, fn _ -> Cluster.partition_store(cluster, node) end)
  defp step(cluster, {:heal_store, node}, run), do: tap(run, fn _ -> Cluster.heal_store(cluster, node) end)
  defp step(_cluster, {:pass, ms}, run), do: tap(run, fn _ -> Process.sleep(ms) end)
end
