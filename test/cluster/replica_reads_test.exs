defmodule Atanor.Cluster.ReplicaReadsTest do
  @moduledoc """
  Reads of a cell served on the nodes that do not own it (design §19): a bounded request runs on the node
  it reaches, reads from a replica there, and cannot write; the owner of a hot cell turns the replicas on
  by the reads of the whole cluster and off after it cools down.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  @replicas [poll_ms: 50, marker_ttl_ms: 200, refresh_timeout_ms: 1_500]

  defp start(atanor \\ []) do
    start_cluster(
      workers: [Manifests.counter("counter")],
      atanor: [alambique: [replicas: @replicas]] ++ atanor
    )
  end

  defp instance(cluster), do: Cluster.instance(cluster)

  defp set_replicas(cluster, via, cell, on?) do
    {:ok, :ok} = Cluster.call(cluster, via, Atanor.Cell, :replicas, [instance(cluster), {"log", cell}, on?])
  end

  defp replicas_on?(cluster, via, cell) do
    {:ok, {:ok, on?}} = Cluster.call(cluster, via, Atanor.Cell, :replicas, [instance(cluster), {"log", cell}])
    on?
  end

  defp read(cluster, via, cell, ms), do: request(cluster, via, :get, "/r/#{cell}?ms=#{ms}")

  defp replica_reads(cluster, node),
    do: events(cluster, [:alambique, :replica, :read], &(&1.source == :replica)) |> Enum.filter(&(&1.node == node))

  test "a bounded request runs on the ingress node, reads from its replica and cannot write" do
    cluster = start()
    {cell, owner} = owned_cell(cluster, "rr", [:n2, :n3])
    reader = hd([:n1, :n2, :n3] -- [owner])
    set_replicas(cluster, reader, cell, true)

    forwarded = fn ->
      events(cluster, [:atanor, :forward], &(&1.cell == {"log", cell})) |> Enum.count(&(&1.node == reader))
    end

    before = forwarded.()

    # The first reads are the owner's while the replica is built; then the reader answers alone.
    Await.until(
      fn ->
        assert {:ok, %{status: 200, body: body}} = read(cluster, reader, cell, 500)
        assert %{"node" => node, "rows" => [0]} = Jason.decode!(body)
        assert node == Atom.to_string(Cluster.node(cluster, reader))
        replica_reads(cluster, reader) != []
      end,
      30_000
    )

    # The request never went to the owner: the ingress node ran the handler.
    assert forwarded.() == before

    # A write in a bounded request is refused, and the same cell is written through the owner.
    assert {:ok, %{status: 409, body: refused}} =
             request(cluster, reader, :post, "/r/#{cell}?ms=500", body: "9")

    assert Jason.decode!(refused)["error"] == ":read_only"
    assert {200, _} = write(cluster, reader, cell, 5)

    # The replica shows the write within the bound; reading with a longer bound never gives less.
    Await.until(
      fn ->
        {:ok, %{body: body}} = read(cluster, reader, cell, 500)
        Jason.decode!(body)["rows"] == [0, 5]
      end,
      10_000
    )
  end

  test "a strong request for the same cell still runs on the owner" do
    cluster = start()
    {cell, owner} = owned_cell(cluster, "st", [:n2, :n3])
    reader = hd([:n1, :n2, :n3] -- [owner])
    set_replicas(cluster, reader, cell, true)

    assert {:ok, %{status: 200, body: body}} = request(cluster, reader, :get, "/c/#{cell}")
    assert Jason.decode!(body)["node"] == Atom.to_string(Cluster.node(cluster, owner))
  end

  test "the owner turns replicas on for a cell read in the cluster, and off after it cools down" do
    hot = [
      enabled: true,
      move: false,
      replicas: true,
      os_cpu: false,
      interval_ms: 200,
      sustain_ms: 600,
      replica_enter: 20,
      replica_exit: 5,
      replica_hold_ms: 1_500,
      stale_ms: 1_500
    ]

    cluster = start(hot_cells: hot)
    {cell, owner} = owned_cell(cluster, "auto", [:n2])
    readers = [:n1, :n3]
    refute replicas_on?(cluster, owner, cell)

    # About 80 reads per second, all through the nodes that do not own the cell.
    parent = self()

    loads =
      for via <- readers do
        spawn_link(fn ->
          loop = fn loop ->
            receive do
              :stop -> send(parent, {:stopped, via})
            after
              25 ->
                read(cluster, via, cell, 500)
                loop.(loop)
            end
          end

          loop.(loop)
        end)
      end

    [on] =
      Await.until(
        fn -> events(cluster, [:atanor, :hot_cell, :replicas], &(&1.action == :on)) |> then(&(&1 != [] and &1)) end,
        30_000
      )

    assert on.node == owner
    assert on.meta.cell == {"log", cell} and on.meta.result == :ok
    assert on.measurements.reads >= 20
    assert Await.until(fn -> replicas_on?(cluster, owner, cell) end)

    # The readers are served by their replicas.
    Await.until(fn -> Enum.all?(readers, &(replica_reads(cluster, &1) != [])) end, 30_000)

    for pid <- loads, do: send(pid, :stop)
    for via <- readers, do: assert_receive({:stopped, ^via}, 5_000)

    [off] =
      Await.until(
        fn -> events(cluster, [:atanor, :hot_cell, :replicas], &(&1.action == :off)) |> then(&(&1 != [] and &1)) end,
        30_000
      )

    assert off.meta.result == :ok and off.node == owner
    assert off.at - on.at >= 1_500_000
    refute replicas_on?(cluster, owner, cell)

    # A cell that is not hot does not get its replicas turned on again.
    Process.sleep(1_000)
    assert length(events(cluster, [:atanor, :hot_cell, :replicas])) == 2
  end
end
