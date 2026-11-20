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
    echo "backing: $LOAD_STORE_BACKING"
    echo "nocowDir: $ATANOR_CLUSTER_STORE_NOCOW_DIR"
    """

    {out, status} =
      System.cmd("bash", ["-c", script],
        env: [{"ATANOR_LOAD_CONFIG", Path.join(dir, "round.toml")}, {"XDG_CACHE_HOME", Path.join(dir, "cache")}],
        stderr_to_stdout: true
      )

    if status == 0,
      do: {0, out |> String.split("\n", trim: true) |> Map.new(&List.to_tuple(String.split(&1, ": ", parts: 2)))},
      else: {status, out}
  end

  test "by default the store is a nodatacow host directory and the node is in tmpfs", %{dir: dir} do
    assert {0, s} = settings(dir, "")
    assert s["files"] =~ ~r/compose.yml.*compose.tmpfs.yml.*compose.store-nocow.yml$/
    refute s["files"] =~ "store-disk"
    assert s["backing"] == "nocow" and s["nocowDir"] == Path.join(dir, "cache/atanor-load/store")
    assert s["nodeTmpfs"] == "256m" and s["bytes"] == "0" and s["storeMemory"] == "2147483648"
  end

  test "store.nocow_dir chooses the directory", %{dir: dir} do
    assert {0, s} = settings(dir, "[store]\nnocow_dir = \"/srv/store\"\n")
    assert s["nocowDir"] == "/srv/store"
  end

  test "store.backing = \"tmpfs\" keeps the store in memory", %{dir: dir} do
    assert {0, s} = settings(dir, "[store]\nbacking = \"tmpfs\"\n")
    assert s["files"] =~ ~r/compose.yml.*compose.tmpfs.yml$/
    refute s["files"] =~ "store-disk" or s["files"] =~ "store-nocow"
    assert s["backing"] == "tmpfs" and s["nocowDir"] == ""
    assert s["storeTmpfs"] == "1g" and s["bytes"] == "1073741824"
    assert s["storeMemory"] == "3221225472"
  end

  test "store.backing = \"disk\" puts the store on disk and keeps the node's tmpfs", %{dir: dir} do
    assert {0, s} = settings(dir, "[store]\nbacking = \"disk\"\n")
    assert s["files"] =~ ~r/compose.yml.*compose.tmpfs.yml.*compose.store-disk.yml$/
    refute s["files"] =~ "store-nocow"
    assert s["backing"] == "disk" and s["nocowDir"] == ""
    assert s["nodeTmpfs"] == "256m"
    assert s["bytes"] == "0"
    assert s["storeMemory"] == "2147483648"
  end

  test "store.backing takes nocow, tmpfs or disk", %{dir: dir} do
    assert {1, out} = settings(dir, "[store]\nbacking = \"yes\"\n")
    assert out =~ "store.backing: 'yes' is not one of nocow, tmpfs, disk"
  end

  describe "scripts/load-store-dir" do
    defp store_dir(args), do: System.cmd(Path.expand("scripts/load-store-dir"), args, stderr_to_stdout: true)

    test "refuses an empty path, /, $HOME and a relative path", %{dir: dir} do
      for path <- ["", "/", System.user_home!(), "relative/dir"], action <- ["prepare", "clean"] do
        assert {out, 1} = store_dir([action, path])
        assert out =~ "refusing"
      end

      refute File.exists?(Path.join(dir, "relative"))
    end

    test "prepare creates the directory and sets the C attribute where it can; status reports it", %{dir: dir} do
      target = Path.join(dir, "store")
      assert {out, 0} = store_dir(["prepare", target])
      assert File.dir?(target) and out =~ target
      {status, 0} = store_dir(["status", target])
      {lsattr, _} = System.cmd("lsattr", ["-d", target], stderr_to_stdout: true)
      assert String.trim(status) == if(lsattr =~ ~r/^\S*C/, do: "true", else: "false")
      assert File.ls!(target) == [".atanor-load-store"]
      # again: nothing changes
      assert {_, 0} = store_dir(["prepare", target])
      assert File.ls!(target) == [".atanor-load-store"]
    end

    test "prepare and clean refuse a non-empty directory that is not the lab's, and leave it as it was", %{dir: dir} do
      target = Path.join(dir, "full")
      File.mkdir_p!(target)
      File.write!(Path.join(target, "old"), "x")

      for action <- ["prepare", "clean"] do
        {out, code} = store_dir([action, target])
        assert code == 1 and out =~ "not a store directory of the load lab"
      end

      assert File.ls!(target) == ["old"]
    end

    test "clean of a missing directory does nothing", %{dir: dir} do
      assert {"", 0} = store_dir(["clean", Path.join(dir, "missing")])
    end
  end
end
