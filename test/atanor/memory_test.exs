defmodule Atanor.MemoryTest do
  use ExUnit.Case, async: true

  alias Atanor.Config

  @moduletag :tmp_dir

  defp build(opts, alambique \\ []) do
    Config.build(
      name: :memory_config,
      store: {AlambiqueTestkit.MemoryStore, %{}},
      data_dir: System.tmp_dir!(),
      port: 0,
      alambique: alambique,
      memory: opts
    )
  end

  defp cgroup(dir, content) do
    path = Path.join(dir, "memory.max")
    File.write!(path, content)
    [cgroup_path: path]
  end

  defp max_bytes(config), do: config.alambique_opts[:awake][:max_bytes]

  test "a cgroup limit gives half of it to the awake cells", %{tmp_dir: dir} do
    config = build(cgroup(dir, "2147483648\n"))
    assert max_bytes(config) == 1_073_741_824
    assert config.memory.awake_source == :cgroup
  end

  test "awake_fraction sets the share", %{tmp_dir: dir} do
    assert max_bytes(build(cgroup(dir, "1000\n") ++ [awake_fraction: 0.25])) == 250
    assert max_bytes(build(cgroup(dir, "1000\n") ++ [awake_fraction: 1])) == 1_000
  end

  test "limit_bytes wins over the cgroup", %{tmp_dir: dir} do
    config = build(cgroup(dir, "1000\n") ++ [limit_bytes: 4_000])
    assert max_bytes(config) == 2_000
    assert config.memory.awake_source == :limit_bytes
  end

  test "no ceiling when the cgroup says max, is missing, or is unreadable", %{tmp_dir: dir} do
    for content <- ["max\n", "", "lots\n", "0\n"] do
      config = build(cgroup(dir, content))
      assert config.memory.awake_source == :none
      refute Keyword.has_key?(config.alambique_opts, :awake)
    end

    config = build(cgroup_path: Path.join(dir, "missing"))
    assert config.memory.awake_source == :none
    refute Keyword.has_key?(config.alambique_opts, :awake)
  end

  test "an explicit awake max_bytes wins, and nil keeps no ceiling", %{tmp_dir: dir} do
    memory = cgroup(dir, "1000\n")
    config = build(memory, awake: [max_bytes: 77, max_cells: 5])
    assert config.alambique_opts[:awake] == [max_bytes: 77, max_cells: 5]
    assert config.memory.awake_source == :option

    assert max_bytes(build(memory, awake: [max_bytes: nil])) == nil
  end

  test "the other awake limits are kept when the ceiling is derived", %{tmp_dir: dir} do
    config = build(cgroup(dir, "1000\n"), awake: [cache_kib: 64, max_cells: 5])
    assert Keyword.take(config.alambique_opts[:awake], [:cache_kib, :max_cells]) == [cache_kib: 64, max_cells: 5]
    assert max_bytes(config) == 500
  end

  test "the defaults read the cgroup of the machine" do
    config = Config.build(name: :memory_defaults, store: {AlambiqueTestkit.MemoryStore, %{}}, data_dir: "/tmp", port: 0)

    assert Map.delete(config.memory, :awake_source) ==
             %{
               limit_bytes: nil,
               awake_fraction: 0.5,
               cgroup_path: "/sys/fs/cgroup/memory.max",
               refuse_fraction: 0.85,
               sample_ms: 100,
               current_path: "/sys/fs/cgroup/memory.current",
               stat_path: "/sys/fs/cgroup/memory.stat"
             }
  end

  test "wrong values are refused at start" do
    for bad <- [
          [limit_bytes: 0],
          [limit_bytes: "1G"],
          [awake_fraction: 0],
          [awake_fraction: 1.5],
          [awake_fraction: "half"],
          [cgroup_path: nil],
          [refuse_fraction: 0.05],
          [refuse_fraction: 1.5],
          [refuse_fraction: "most"],
          [sample_ms: 0],
          [current_path: nil],
          [stat_path: 1],
          [size: 1],
          :big
        ] do
      assert_raise ArgumentError, ~r/:memory/, fn -> build(bad) end
    end

    for bad <- [
          [awake: [max_bytes: 0]],
          [awake: [max_bytes: 1.5]],
          [awake: [cache_kib: nil]],
          [awake: [cache_kib: 0]],
          [idle_timeout_ms: 0],
          [idle_timeout_ms: :infinity]
        ] do
      assert_raise ArgumentError, ~r/:alambique/, fn -> build([], bad) end
    end

    assert build([], awake: [cache_kib: 512, max_bytes: nil], idle_timeout_ms: 300_000)
  end
end
