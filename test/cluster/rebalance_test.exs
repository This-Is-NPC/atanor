defmodule Atanor.Cluster.RebalanceTest do
  @moduledoc """
  The rebalance on join (design §8.1) on a cluster: two nodes serve many live cells under continuous writes, a
  third joins, and the cells that it now prefers move to it, coldest first and at a bounded rate, without losing
  or duplicating an acknowledged write. When the membership does not change nothing moves any more.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, C1, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 180_000

  @cells for i <- 1..90, do: "r#{i}"
  @writers 3
  @rebalance [enabled: true, max_moves_per_s: 20, start_delay_ms: 1_500]

  defp start(rebalance) do
    start_cluster(names: [:n1, :n2], workers: [Manifests.counter("counter")], atanor: [rebalance: rebalance])
  end

  # Each writer owns a share of the cells and writes to one after the other, through the first two peers, until
  # the stop message; it returns the numbers acknowledged for each cell.
  defp writers(cluster) do
    parent = self()

    for index <- 0..(@writers - 1) do
      cells = for {cell, i} <- Enum.with_index(@cells), rem(i, @writers) == index, do: cell
      spawn_link(fn -> send(parent, {:acked, self(), write_loop(cluster, cells, 1, %{})}) end)
    end
  end

  defp write_loop(cluster, cells, n, acked) do
    receive do
      :stop -> acked
    after
      0 ->
        acked =
          Enum.reduce(cells, acked, fn cell, acked ->
            via = Enum.at([:n1, :n2], rem(n, 2))

            case write(cluster, via, cell, n) do
              {200, _} -> Map.update(acked, cell, [n], &[n | &1])
              _ -> acked
            end
          end)

        Process.sleep(20)
        write_loop(cluster, cells, n + 1, acked)
    end
  end

  defp stop(writers) do
    for pid <- writers, do: send(pid, :stop)

    Enum.reduce(writers, %{}, fn pid, all ->
      assert_receive {:acked, ^pid, acked}, 30_000
      Map.merge(all, acked)
    end)
  end

  defp stored(cluster, cell) do
    {:ok, %{status: 200, body: body}} = request(cluster, :n1, :get, "/c/#{cell}")
    Jason.decode!(body)["rows"]
  end

  defp moves(cluster), do: events(cluster, [:atanor, :rebalance, :move])

  # Where each cell is and where its preferred node says it should be, by the view of `:n1`.
  defp placement(cluster) do
    cells = Module.concat(Cluster.instance(cluster), Cells)
    {:ok, config} = Cluster.call(cluster, :n1, Alambique.Config, :fetch!, [cells])

    for cell <- @cells do
      # A cell that is moving right now has no owner for a moment.
      owner = with {:ok, owner} <- owner(cluster, :n1, "log", cell), do: owner
      {:ok, preferred} = Cluster.call(cluster, :n1, Alambique.Membership, :preferred, [config, "log." <> cell])
      {cell, owner, preferred}
    end
  end

  defp runtime(cluster, name) do
    response =
      Req.get!(Cluster.admin_url(cluster, name) <> "/runtime",
        headers: [{"authorization", "Bearer " <> Cluster.admin_token()}]
      )

    response.body["rebalance"]
  end

  test "cells move to a node that joins, under writes, and then nothing moves" do
    cluster = start(@rebalance)
    for cell <- @cells, do: {200, _} = write(cluster, :n1, cell, 0)
    writers = writers(cluster)

    # Before the join every cell is on one of the two and is where it is preferred.
    assert Enum.all?(placement(cluster), fn {_, owner, preferred} -> owner == preferred end)
    assert moves(cluster) == []

    :ok = Cluster.add(cluster, :n3)
    n3 = Cluster.node(cluster, :n3)

    misplaced = fn -> for {_, owner, preferred} <- placement(cluster), owner != preferred, do: preferred end
    pending = Await.until(fn -> misplaced.() |> then(&(&1 != [] and &1)) end, 30_000)
    assert Enum.all?(pending, &(&1 == n3)), "a join moves cells to the new node only"

    # The plan waits for the delay, then moves the misplaced cells; all of them settle.
    Await.until(fn -> misplaced.() == [] end, 90_000)
    Await.until(fn -> Enum.all?([:n1, :n2], &(runtime(cluster, &1)["phase"] == "done")) end, 60_000)

    counts = placement(cluster) |> Enum.frequencies_by(&elem(&1, 1))

    assert counts[n3] >= div(length(@cells), 6),
           "the new node serves #{counts[n3]} of #{length(@cells)}: #{inspect(counts)}"

    assert Enum.sum(Map.values(counts)) == length(@cells)

    done = moves(cluster)
    assert done != [] and Enum.all?(done, &(&1.meta.result == :ok and &1.meta.to == n3))

    # A cell moves at most once, and only the plans of the three members moved anything.
    assert done |> Enum.frequencies_by(& &1.meta.cell) |> Map.values() |> Enum.all?(&(&1 == 1))
    started = events(cluster, [:atanor, :rebalance, :start])
    assert Enum.any?(started, &(&1.measurements.cells > 0 and length(&1.meta.members) == 3))
    assert Enum.all?(started, &(&1.measurements.cells == 0 or length(&1.meta.members) == 3))

    # With the membership unchanged nothing moves, although the writes go on.
    {moved, total} = {length(done), runtime(cluster, :n1)["total"]["moved"] + runtime(cluster, :n2)["total"]["moved"]}
    assert moved == total
    acked = stop(writers)
    assert length(moves(cluster)) == moved
    assert events(cluster, [:atanor, :rebalance, :start]) |> length() == length(started)

    for cell <- @cells do
      rows = stored(cluster, cell)
      sent = Map.get(acked, cell, [])
      assert sent -- rows == [], "cell #{cell} lost acknowledged writes"
      assert rows == Enum.uniq(rows), "cell #{cell} holds a write twice"
    end

    C1.check_epochs(Cluster.events(cluster))
  end

  test "a node that joins and leaves inside the delay moves nothing" do
    cluster = start(Keyword.put(@rebalance, :start_delay_ms, 60_000))
    for cell <- @cells, do: {200, _} = write(cluster, :n1, cell, 0)

    :ok = Cluster.add(cluster, :n3)
    n3 = Cluster.node(cluster, :n3)
    Await.until(fn -> n3 in (runtime(cluster, :n1)["members"] |> Enum.map(&String.to_atom/1)) end, 30_000)
    assert runtime(cluster, :n1)["phase"] == "waiting"
    assert runtime(cluster, :n1)["starts_in_ms"] > 0

    :ok = Cluster.kill(cluster, :n3)
    Await.until(fn -> n3 not in (runtime(cluster, :n1)["members"] |> Enum.map(&String.to_atom/1)) end, 60_000)

    # The plan started again with the new membership, and none ran.
    assert runtime(cluster, :n1)["phase"] == "waiting"
    assert moves(cluster) == []
    assert events(cluster, [:atanor, :rebalance, :start]) == []
  end
end
