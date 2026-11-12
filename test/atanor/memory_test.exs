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
    assert Keyword.take(config.alambique_opts[:awake], [:max_bytes, :max_cells]) == [max_bytes: 77, max_cells: 5]
    assert config.memory.awake_source == :option

    assert max_bytes(build(memory, awake: [max_bytes: nil])) == nil
  end

  test "the other awake limits are kept when the ceiling is derived", %{tmp_dir: dir} do
    config = build(cgroup(dir, "1000\n"), awake: [cache_kib: 64, max_cells: 5])
    assert Keyword.take(config.alambique_opts[:awake], [:cache_kib, :max_cells]) == [cache_kib: 64, max_cells: 5]
    assert max_bytes(config) == 500
  end

  defp wakes(config) do
    {config.alambique_opts[:awake][:max_wakes], config.alambique_opts[:restore][:fetch_concurrency],
     config.alambique_opts[:restore][:prefetch_bytes]}
  end

  @mib 1_048_576

  test "the wakes in flight are derived from the headroom above the refuse mark", %{tmp_dir: dir} do
    # 15% of the limit is headroom, half of it is for wakes: 38.4 MiB on 512 MiB, 153.6 MiB on 2 GiB.
    assert wakes(build(cgroup(dir, "#{512 * @mib}\n"))) == {11, 1, 2_516_582}
    assert wakes(build(cgroup(dir, "#{2048 * @mib}\n"))) == {11, 4, 10_066_329}

    # The limit may be the option's, and the refuse mark and the share move the headroom.
    assert wakes(build(limit_bytes: 2048 * @mib)) == {11, 4, 10_066_329}
    assert {w, _, _} = wakes(build(limit_bytes: 2048 * @mib, refuse_fraction: 0.5))
    assert w == 10
    assert {_, _, p} = wakes(build(limit_bytes: 2048 * @mib, refuse_fraction: 0.5))
    assert p == 33_554_432
    assert {_, _, p} = wakes(build(limit_bytes: 2048 * @mib, wake_fraction: 1))
    assert p == 20_132_659
  end

  test "an operator's wake limits win one by one", %{tmp_dir: dir} do
    memory = cgroup(dir, "#{512 * @mib}\n")
    assert wakes(build(memory, awake: [max_wakes: 100])) == {100, 1, 2_516_582}
    assert wakes(build(memory, restore: [fetch_concurrency: 8])) == {11, 8, 2_516_582}
    assert wakes(build(memory, restore: [prefetch_bytes: 1_000])) == {11, 1, 1_000}

    assert wakes(build(memory, awake: [max_wakes: 256], restore: [fetch_concurrency: 16, prefetch_bytes: 67_108_864])) ==
             {256, 16, 67_108_864}
  end

  test "a node without a limit keeps Alambique's wake limits", %{tmp_dir: dir} do
    config = build(cgroup(dir, "max\n"))
    assert wakes(config) == {nil, nil, nil}
    refute Keyword.has_key?(config.alambique_opts, :restore)
  end

  test "the defaults read the cgroup of the machine" do
    config = Config.build(name: :memory_defaults, store: {AlambiqueTestkit.MemoryStore, %{}}, data_dir: "/tmp", port: 0)

    assert Map.delete(config.memory, :awake_source) ==
             %{
               limit_bytes: nil,
               awake_fraction: 0.5,
               wake_fraction: 0.5,
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
          [wake_fraction: 0],
          [wake_fraction: 1.5],
          [wake_fraction: "most"],
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
