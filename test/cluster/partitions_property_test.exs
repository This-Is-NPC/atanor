defmodule Atanor.Cluster.PartitionsPropertyTest do
  @moduledoc """
  The routing of partitioned cells is stable (design §4.2).

  For random partition counts and keys, requests enter the cluster through random nodes. Each one must reach the
  owner of the physical cell the mapping predicts, write there and nowhere else, and read back from any node. The
  mapping gives the same partition on every node.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.ClusterCase

  alias Atanor.Partition
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 300_000

  @names [:n1, :n2, :n3]

  defp post(cluster, via, key, n) do
    {:ok, resp} = request(cluster, via, :post, "/p/#{key}", body: Integer.to_string(n))
    resp
  end

  defp get(cluster, via, path) do
    {:ok, resp} = request(cluster, via, :get, path)
    {resp.status, Jason.decode!(resp.body)}
  end

  property "the routing of partitioned cells is stable" do
    check all(
            partitions <- integer(2..12),
            keys <- uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 12), min_length: 4, max_length: 14),
            vias <- list_of(member_of(@names), length: 14),
            max_runs: 4,
            max_shrinking_steps: 0
          ) do
      cluster = start_cluster(names: @names, workers: [Manifests.partitioned("p", partitions)])
      writes = Enum.zip(keys, vias)

      # The mapping is the same on every node.
      for name <- @names, key <- keys do
        assert {:ok, Partition.index(key, partitions)} ==
                 Cluster.call(cluster, name, Partition, :index, [key, partitions])
      end

      # Each write enters through a random node, runs on the owner of the predicted cell and lands in it.
      for {{key, via}, i} <- Enum.with_index(writes) do
        {:ok, {"events", physical}} = Partition.address({"events", "stream"}, key, partitions)
        assert %{status: 200, body: body} = post(cluster, via, key, i)
        assert %{"cell" => ^physical, "node" => node} = Jason.decode!(body)
        {:ok, owner} = owner(cluster, via, "events", physical)
        assert node == Atom.to_string(owner)
      end

      # Every cell holds exactly the rows of the keys that map to it, and nothing else.
      expected = Enum.group_by(Enum.with_index(keys), fn {key, _} -> Partition.index(key, partitions) end)

      for index <- 0..(partitions - 1) do
        {200, %{"rows" => rows}} = get(cluster, Enum.random(@names), "/cell/#{index}")
        want = for {key, i} <- Map.get(expected, index, []), do: [key, i]
        assert Enum.sort(rows) == Enum.sort(want), "partition #{index} of #{partitions}"
      end

      # A read through any node finds what the key's own write left.
      for {{key, _}, i} <- Enum.with_index(writes), via <- @names do
        assert {200, %{"rows" => [^i]}} = get(cluster, via, "/p/#{key}")
      end

      {200, %{"counts" => counts}} = get(cluster, :n1, "/all")
      assert Enum.sum(counts) == length(keys)
      assert counts == for(index <- 0..(partitions - 1), do: length(Map.get(expected, index, [])))

      Cluster.stop(cluster)
    end
  end
end
