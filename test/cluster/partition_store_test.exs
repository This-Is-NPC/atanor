defmodule Atanor.Cluster.PartitionStoreTest do
  @moduledoc "The cluster testkit: a store partition of a peer ends with one heal, however many times it was started."
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  test "two partitions of the same peer are healed together" do
    cluster = start_cluster(names: [:n1])
    {mod, config} = Cluster.store(cluster)
    read = fn -> Cluster.call(cluster, :n1, mod, :get, [config, "no-such-key"]) end

    assert {:ok, {:error, :not_found}} = read.()

    :ok = Cluster.partition_store(cluster, :n1)
    :ok = Cluster.partition_store(cluster, :n1)
    assert {:ok, {:error, :partitioned}} = read.()

    :ok = Cluster.heal_store(cluster, :n1)
    assert {:ok, {:error, :not_found}} = read.()
  end
end
