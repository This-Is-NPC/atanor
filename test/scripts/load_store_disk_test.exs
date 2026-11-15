defmodule Atanor.LoadStoreDiskTest do
  use ExUnit.Case, async: true

  # The compose arguments and sizes that scripts/load-common gives to the cluster scripts, read without Docker.
  # Compose files are chosen where scripts/cluster-common is sourced, so the check runs it as a child, as cluster-up does.
  defp settings(env) do
    script = ~S"""
    source scripts/load-common
    bash -c 'source scripts/cluster-common; echo "files: ${compose_files[*]##*/}"; echo "storeMemory: $ATANOR_CLUSTER_STORE_MEMORY"; echo "storeTmpfs: $ATANOR_CLUSTER_STORE_TMPFS_SIZE"; echo "nodeTmpfs: $ATANOR_CLUSTER_TMPFS_SIZE"'
    echo "bytes: $store_tmpfs_bytes"
    """

    {out, status} = System.cmd("bash", ["-c", script], env: env, stderr_to_stdout: true)

    if status == 0,
      do: {0, out |> String.split("\n", trim: true) |> Map.new(&List.to_tuple(String.split(&1, ": ", parts: 2)))},
      else: {status, out}
  end

  test "by default the store and the node are in tmpfs" do
    assert {0, s} = settings([])
    assert s["files"] =~ ~r/compose.yml.*compose.tmpfs.yml$/
    refute s["files"] =~ "store-disk"
    assert s["storeTmpfs"] == "1g" and s["bytes"] == "1073741824"
    assert s["storeMemory"] == "3221225472"
  end

  test "ATANOR_LOAD_STORE_DISK=1 puts the store on disk and keeps the node's tmpfs" do
    assert {0, s} = settings([{"ATANOR_LOAD_STORE_DISK", "1"}])
    assert s["files"] =~ ~r/compose.yml.*compose.tmpfs.yml.*compose.store-disk.yml$/
    assert s["nodeTmpfs"] == "256m"
    assert s["bytes"] == "0"
    assert s["storeMemory"] == "2147483648"
  end

  test "ATANOR_LOAD_STORE_DISK takes 0 or 1" do
    assert {1, out} = settings([{"ATANOR_LOAD_STORE_DISK", "yes"}])
    assert out =~ "ATANOR_LOAD_STORE_DISK must be 0 or 1"
  end
end
