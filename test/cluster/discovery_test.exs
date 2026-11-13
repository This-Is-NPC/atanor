defmodule Atanor.Cluster.DiscoveryTest do
  @moduledoc """
  Discovery through the store (design §8.16) between real nodes that are not connected to each other at
  start: each publishes itself in the node registry and `Atanor.Discovery` connects to the peers it lists.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 180_000

  @ttl_ms 2_000
  @skew_ms 400
  @discover [ttl_ms: @ttl_ms, renew_ms: 200]

  defp start(names) do
    start_cluster(
      names: names,
      ttl_ms: @ttl_ms,
      skew_margin_ms: @skew_ms,
      discover: @discover,
      workers: [Manifests.counter("counter")]
    )
  end

  # The peer names `via` is connected to (the test VM, which started the peers, is not one).
  defp connected(cluster, via) do
    {:ok, nodes} = Cluster.call(cluster, via, Node, :list, [])
    for name <- Cluster.names(cluster), name != via, Cluster.node(cluster, name) in nodes, do: name
  end

  # The peer names `via` reads from the registry.
  defp listed(cluster, via) do
    {:ok, peers} = Cluster.call(cluster, via, Alambique, :peers, [Module.concat(Cluster.instance(cluster), Cells)])

    for %{advertise: advertise} <- peers,
        name <- Cluster.names(cluster),
        Atom.to_string(Cluster.node(cluster, name)) == advertise,
        do: name
  end

  # Every node is connected to the others and lists them in the registry.
  defp await_mesh(cluster, names) do
    for via <- names do
      others = Enum.sort(names -- [via])

      Await.until(
        fn -> Enum.sort(connected(cluster, via)) == others and Enum.sort(listed(cluster, via)) == others end,
        60_000
      )
    end
  end

  test "two nodes that were never connected find each other" do
    cluster = start([:n1, :n2])
    await_mesh(cluster, [:n1, :n2])

    # They are one cluster: a cell owned by the other node is served through this one.
    {_cell, owner} = owned_cell(cluster, "two", [:n2])
    assert owner == :n2
    assert events(cluster, [:atanor, :discovery, :connect], &(&1.result == :ok)) != []
  end

  test "three nodes find each other" do
    cluster = start([:n1, :n2, :n3])
    await_mesh(cluster, [:n1, :n2, :n3])
  end

  test "a node that starts later joins on its own" do
    cluster = start([:n1, :n2])
    await_mesh(cluster, [:n1, :n2])

    Cluster.add(cluster, :n3)
    await_mesh(cluster, [:n1, :n2, :n3])

    joined =
      await_events(
        cluster,
        [:atanor, :discovery, :joined],
        &(&1.advertise == Atom.to_string(Cluster.node(cluster, :n3)))
      )

    assert Enum.any?(joined, &(&1.node == :n1))
  end

  test "a node that stopped is forgotten, and the detector keeps the connection" do
    cluster = start([:n1, :n2, :n3])
    await_mesh(cluster, [:n1, :n2, :n3])

    supervisor = Module.concat(Cluster.instance(cluster), Supervisor)
    assert {:ok, :ok} = Cluster.call(cluster, :n3, Supervisor, :stop, [supervisor])

    for via <- [:n1, :n2], do: Await.until(fn -> listed(cluster, via) == [Enum.find([:n1, :n2], &(&1 != via))] end)
    for via <- [:n1, :n2], do: assert(:n3 in connected(cluster, via), "discovery disconnected #{via} from n3")

    await_events(cluster, [:atanor, :discovery, :left], &(&1.advertise == Atom.to_string(Cluster.node(cluster, :n3))))
  end

  test "a node that was killed without leaving is forgotten after the TTL" do
    cluster = start([:n1, :n2, :n3])
    await_mesh(cluster, [:n1, :n2, :n3])

    t0 = now()
    Cluster.kill(cluster, :n3)

    for via <- [:n1, :n2], do: Await.until(fn -> listed(cluster, via) == [Enum.find([:n1, :n2], &(&1 != via))] end)
    IO.puts("killed node forgotten after #{div(now() - t0, 1_000)} ms (ttl #{@ttl_ms} ms, skew #{@skew_ms} ms)")

    # The survivors still form one cluster.
    await_mesh(cluster, [:n1, :n2])
  end

  test "a node of another group is listed but not dialled" do
    cluster =
      start_cluster(
        names: [:n1, :n2, :n3],
        ttl_ms: @ttl_ms,
        skew_margin_ms: @skew_ms,
        discover: @discover,
        peer_discover: %{n3: [meta: %{"group" => "b"}]}
      )

    # n1 and n2 form a cluster, and n3 is in the store for both.
    for via <- [:n1, :n2] do
      Await.until(fn -> :n3 in listed(cluster, via) and connected(cluster, via) == [:n1, :n2] -- [via] end, 60_000)
    end

    # Each side said that it leaves the other group alone: n3 about n1 and n2, and they about n3.
    ignored = fn name ->
      advertise = Atom.to_string(Cluster.node(cluster, name))

      events(cluster, [:atanor, :discovery, :ignored], &(&1.advertise == advertise))
      |> Enum.map(& &1.node)
      |> Enum.uniq()
    end

    Await.until(fn -> Enum.sort(ignored.(:n3)) == [:n1, :n2] end)
    Await.until(fn -> :n3 in ignored.(:n1) and :n3 in ignored.(:n2) end)

    assert connected(cluster, :n3) == []
    for via <- [:n1, :n2], do: refute(:n3 in connected(cluster, via))
  end
end
