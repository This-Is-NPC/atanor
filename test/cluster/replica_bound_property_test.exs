defmodule Atanor.Cluster.ReplicaBoundPropertyTest do
  @moduledoc """
  **R1.** A `{:bounded, ms}` read stays within its bound (design §19.6). Writes go through random nodes to one
  counter cell; bounded requests (`GET /r/CELL?ms=N`, which run on the node they reach) read it through random
  nodes, while the replicas of the cell are switched on and off and the cell moves between nodes. Writes and
  reads are stamped with the clock the peers share, as in C1 (`properties_test.exs`). Every read that answered
  must contain every write acknowledged to its caller more than `ms` before the read started, and nothing that
  was never written. The runs must include reads served by a replica, or the property proves nothing.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.ClusterCase

  alias Atanor.Test.Manifests
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 900_000

  @names [:n1, :n2, :n3]
  @cell "r1"
  # A replica polls every 400 ms, so a bound under that makes a read wait for a refresh, and a bound over it
  # lets the replica answer as it is.
  @replicas [poll_ms: 400, marker_ttl_ms: 200, refresh_timeout_ms: 2_000]
  @bounds [50, 150, 400, 1_000]

  defp op do
    node = member_of(@names)

    frequency([
      {6, tuple({constant(:write), node})},
      {8, tuple({constant(:read), node, member_of(@bounds)})},
      # A write, then a read through another node once the bound has passed: the write must be in it.
      {8, tuple({constant(:write_read), node, node, member_of(@bounds)})},
      {3, tuple({constant(:replicas), node, boolean()})},
      {2, tuple({constant(:move), member_of(@names)})},
      {3, tuple({constant(:pass), integer(50..600)})}
    ])
  end

  property "a bounded read contains every write acknowledged more than ms before it started" do
    {:ok, served} = Agent.start_link(fn -> 0 end)

    check all(ops <- resize(list_of(op(), min_length: 12, max_length: 30), 30), max_runs: 6, max_shrinking_steps: 0) do
      cluster =
        start_cluster(
          names: @names,
          atanor: [alambique: [replicas: @replicas]],
          workers: [Manifests.counter("counter")]
        )

      try do
        {200, _} = write(cluster, :n1, @cell, 0)
        run = Enum.reduce([{:replicas, :n1, true} | ops], new_run(), &step(cluster, &1, &2))
        verify(run)
        Agent.update(served, &(&1 + replica_reads(cluster)))
      after
        Process.unlink(cluster)
        Cluster.stop(cluster)
      end
    end

    assert Agent.get(served, & &1) > 0, "no read was served by a replica in any run"
  end

  defp new_run, do: %{seq: 1, writes: [], reads: []}

  defp step(cluster, {:write, via}, run), do: write_to(cluster, via, run)

  defp step(cluster, {:read, via, ms}, run), do: read_from(cluster, via, ms, run)

  defp step(cluster, {:write_read, writer, reader, ms}, run) do
    run = write_to(cluster, writer, run)
    Process.sleep(ms + 20)
    read_from(cluster, reader, ms, run)
  end

  defp step(cluster, {:replicas, via, on?}, run) do
    instance = Cluster.instance(cluster)
    {:ok, _} = Cluster.call(cluster, via, Atanor.Cell, :replicas, [instance, {"log", @cell}, on?])
    run
  end

  # A move that fails (the cell is moving already, a node is busy) changes nothing the property depends on.
  defp step(cluster, {:move, to}, run) do
    {:ok, owner} = owner(cluster, :n1, "log", @cell)
    from = name_of(cluster, owner)

    if from != to do
      args = [Cluster.instance(cluster), {"log", @cell}, Cluster.node(cluster, to)]
      Cluster.call(cluster, from, Atanor.Cell, :move, args)
    end

    run
  end

  defp step(_cluster, {:pass, ms}, run), do: tap(run, fn _ -> Process.sleep(ms) end)

  defp write_to(cluster, via, run) do
    n = run.seq

    case write(cluster, via, @cell, n) do
      {200, _} -> %{run | seq: n + 1, writes: [{n, now()} | run.writes]}
      _ -> %{run | seq: n + 1}
    end
  end

  defp read_from(cluster, via, ms, run) do
    started = now()

    case request(cluster, via, :get, "/r/#{@cell}?ms=#{ms}") do
      {:ok, %{status: 200, body: body}} ->
        %{"rows" => rows} = Jason.decode!(body)
        %{run | reads: [%{started: started, ms: ms, via: via, rows: rows} | run.reads]}

      _ ->
        run
    end
  end

  defp verify(run) do
    for read <- run.reads do
      due = for {n, acked} <- run.writes, acked + read.ms * 1_000 < read.started, do: n

      assert due -- read.rows == [],
             "read through #{read.via} with bound #{read.ms} ms misses #{inspect(due -- read.rows)}"

      # Only what was attempted, and each number once: a write that got no answer may or may not be in.
      assert Enum.all?(read.rows, &(&1 in 0..run.seq)) and read.rows == Enum.uniq(read.rows)
    end
  end

  defp replica_reads(cluster), do: length(events(cluster, [:alambique, :replica, :read], &(&1.source == :replica)))
end
