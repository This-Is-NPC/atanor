defmodule Atanor.Cluster.AdminTest do
  @moduledoc "The admin API gathers its answers from every node (design §10)."
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.Manifests
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  setup do
    %{cluster: start_cluster(workers: [Manifests.counter("counter")])}
  end

  defp admin(cluster, name, path) do
    resp =
      Req.get!(Cluster.admin_url(cluster, name) <> path,
        headers: [{"authorization", "Bearer " <> Cluster.admin_token()}],
        retry: false,
        decode_body: false,
        receive_timeout: 20_000
      )

    {resp.status, Jason.decode!(resp.body)}
  end

  test "deployments and health list every node", %{cluster: c} do
    expected = Enum.map(Cluster.names(c), &Atom.to_string(Cluster.node(c, &1)))

    for via <- Cluster.names(c) do
      assert {200, %{"partial" => false, "nodes" => nodes}} = admin(c, via, "/deployments")
      assert Map.keys(nodes) |> Enum.sort() == Enum.sort(expected)

      assert Enum.all?(nodes, fn {_, %{"status" => "ok", "workers" => [%{"worker" => "counter", "error" => nil}]}} ->
               true
             end)

      assert {200, %{"nodes" => health}} = admin(c, via, "/health")
      assert Enum.sort(health) == Enum.sort(expected)
    end
  end

  test "a node that fails to answer is marked and the answer is partial", %{cluster: c} do
    watcher = Module.concat(Cluster.instance(c), Watcher)
    {:ok, :ok} = Cluster.call(c, :n2, :sys, :suspend, [watcher])

    assert {200, %{"partial" => true, "nodes" => nodes}} = admin(c, :n1, "/deployments")
    n2 = Atom.to_string(Cluster.node(c, :n2))
    assert %{"status" => "error", "reason" => reason} = nodes[n2]
    assert reason =~ "timeout"
    assert %{"status" => "ok"} = nodes[Atom.to_string(Cluster.node(c, :n1))]

    {:ok, :ok} = Cluster.call(c, :n2, :sys, :resume, [watcher])
  end

  test "cells: counts of every node and pages from one", %{cluster: c} do
    for i <- 1..9, do: {200, _} = post(c, :n1, "cell#{i}", i)

    assert {200, %{"total" => 9, "partial" => false, "nodes" => nodes}} = admin(c, :n3, "/cells")
    assert nodes |> Map.values() |> Enum.map(& &1["count"]) |> Enum.sum() == 9
    assert nodes |> Map.values() |> Enum.count(&(&1["count"] > 0)) > 1

    {node, %{"count" => count}} = Enum.find(nodes, fn {_, %{"count" => count}} -> count > 1 end)
    assert {200, %{"node" => ^node, "cells" => cells, "next" => cursor}} = admin(c, :n3, "/cells?node=#{node}&limit=1")
    assert [%{"namespace" => "log", "key" => "cell" <> _}] = cells
    assert cursor == hd(cells)["id"]

    assert {200, %{"cells" => rest}} = admin(c, :n3, "/cells?node=#{node}&after=#{cursor}")
    assert length(rest) == count - 1
  end

  test "a node that died leaves the lists", %{cluster: c} do
    Cluster.kill(c, :n2)
    dead = Atom.to_string(Cluster.node(c, :n2))

    Atanor.Test.Await.until(
      fn ->
        {200, %{"nodes" => nodes}} = admin(c, :n1, "/health")
        dead not in nodes
      end,
      10_000
    )

    assert {200, %{"partial" => false, "nodes" => nodes}} = admin(c, :n1, "/deployments")
    assert map_size(nodes) == 2
  end

  defp post(cluster, via, cell, n) do
    {:ok, resp} = request(cluster, via, :post, "/c/#{cell}", body: Integer.to_string(n))
    {resp.status, resp.body}
  end
end
