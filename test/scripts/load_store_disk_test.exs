defmodule Atanor.LoadStoreDiskTest do
  use ExUnit.Case, async: true

  # The compose arguments and sizes that scripts/load-common gives to the cluster scripts, read without Docker.
  # Compose files are chosen where scripts/cluster-common is sourced, so the check runs it as a child, as cluster-up does.
  setup do
    dir = Path.join(System.tmp_dir!(), "atanor-load-store-disk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp settings(dir, toml) do
    File.write!(Path.join(dir, "round.toml"), toml)

    script = ~S"""
    source scripts/load-common
    bash -c 'source scripts/cluster-common; echo "files: ${compose_files[*]##*/}"; echo "storeMemory: $ATANOR_CLUSTER_STORE_MEMORY"; echo "storeTmpfs: $ATANOR_CLUSTER_STORE_TMPFS_SIZE"; echo "nodeTmpfs: $ATANOR_CLUSTER_TMPFS_SIZE"'
    echo "bytes: $store_tmpfs_bytes"
    """

    {out, status} =
      System.cmd("bash", ["-c", script],
        env: [{"ATANOR_LOAD_CONFIG", Path.join(dir, "round.toml")}],
        stderr_to_stdout: true
      )

    if status == 0,
      do: {0, out |> String.split("\n", trim: true) |> Map.new(&List.to_tuple(String.split(&1, ": ", parts: 2)))},
      else: {status, out}
  end

  test "by default the store and the node are in tmpfs", %{dir: dir} do
    assert {0, s} = settings(dir, "")
    assert s["files"] =~ ~r/compose.yml.*compose.tmpfs.yml$/
    refute s["files"] =~ "store-disk"
    assert s["storeTmpfs"] == "1g" and s["bytes"] == "1073741824"
    assert s["storeMemory"] == "3221225472"
  end

  test "store.backing = \"disk\" puts the store on disk and keeps the node's tmpfs", %{dir: dir} do
    assert {0, s} = settings(dir, "[store]\nbacking = \"disk\"\n")
    assert s["files"] =~ ~r/compose.yml.*compose.tmpfs.yml.*compose.store-disk.yml$/
    assert s["nodeTmpfs"] == "256m"
    assert s["bytes"] == "0"
    assert s["storeMemory"] == "2147483648"
  end

  test "store.backing takes tmpfs or disk", %{dir: dir} do
    assert {1, out} = settings(dir, "[store]\nbacking = \"yes\"\n")
    assert out =~ "store.backing: 'yes' is not one of tmpfs, disk"
  end
end
