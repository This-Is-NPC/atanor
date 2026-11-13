defmodule Atanor.Cluster.WakeGateOwnerTest do
  @moduledoc """
  Over its memory mark a node refuses the cells nobody holds, not the cells another node owns: those are
  forwarded (design §4.3).
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "a cell owned by another node is served through a node over its mark; a cold one is refused", %{
    tmp_dir: dir
  } do
    current = Path.join(dir, "memory.current")
    File.write!(current, "100\n")
    memory = [limit_bytes: 1_000, current_path: current, stat_path: Path.join(dir, "memory.stat"), sample_ms: 20]

    cluster =
      start_cluster(workers: [Manifests.counter("counter")], peer_atanor: %{n1: [memory: memory]})

    {cell, owner} = owned_cell(cluster, "far", [:n2, :n3])
    assert owner in [:n2, :n3]

    File.write!(current, "900\n")

    Await.until(fn ->
      {:ok, %{refusing: refusing}} = Cluster.call(cluster, :n1, Atanor.Admission, :stats, [Cluster.instance(cluster)])
      refusing
    end)

    # The ingress refuses everything over the mark, so ask the cell layer of `n1` directly.
    query = fn id ->
      Cluster.call(cluster, :n1, Atanor.Cell, :query, [Cluster.instance(cluster), {"log", id}, "SELECT 1"])
    end

    assert {:ok, {:ok, _}} = query.(cell)
    assert {:ok, {:error, {:unavailable, :overloaded}}} = query.("cold")
  end
end
