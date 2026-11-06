defmodule Atanor.HotCellsConfigTest do
  use ExUnit.Case, async: true

  alias Atanor.Config

  defp build(hot_cells, alambique \\ []) do
    Config.build(
      name: :hot_config,
      store: {AlambiqueTestkit.MemoryStore, %{}},
      data_dir: System.tmp_dir!(),
      port: 0,
      hot_cells: hot_cells,
      alambique: alambique
    )
  end

  test "is off by default, with the documented defaults" do
    hot =
      Config.build(name: :hot_config, store: {AlambiqueTestkit.MemoryStore, %{}}, data_dir: "/tmp", port: 0).hot_cells

    assert %{move: true, replicas: false, replica_enter: 1_000, replica_exit: 500, replica_hold_ms: 60_000} = hot

    assert %{enabled: false, interval_ms: 1_000, sustain_ms: 10_000, cpu_enter: 70, cpu_exit: 50, margin: 20} = hot
    assert %{residence_ms: 300_000, node_cooldown_ms: 30_000, max_moves: 1, tags: [], affinity: []} = hot
  end

  test "takes options, tags and affinity rules" do
    %{hot_cells: hot} = build(enabled: true, cpu_enter: 80, tags: ["dedicated"], affinity: [{"rooms", "dedicated"}])
    assert %{enabled: true, cpu_enter: 80, cpu_exit: 50, tags: ["dedicated"], affinity: [{"rooms", "dedicated"}]} = hot
  end

  test "refuses what cannot work" do
    for bad <- [
          [cpu_exit: 90],
          [write_exit: 500],
          [cpu_enter: 101],
          [unknown: 1],
          [sustain_ms: 0],
          [tags: [:atom]],
          [affinity: [{"Not A Namespace", "tag"}]],
          [affinity: ["rooms"]]
        ] do
      assert_raise ArgumentError, fn -> build(bad) end
    end
  end

  describe "replicas" do
    test "turn on with the Alambique replicas, and take their own thresholds" do
      %{hot_cells: hot} =
        build([replicas: true, replica_enter: 300, replica_exit: 100, replica_hold_ms: 5_000, move: false],
          replicas: []
        )

      assert %{replicas: true, replica_enter: 300, replica_exit: 100, replica_hold_ms: 5_000, move: false} = hot
    end

    test "are refused when the Alambique instance has no replicas, or the thresholds cross" do
      assert_raise ArgumentError, ~r/needs the Alambique replicas/, fn -> build(replicas: true) end
      assert_raise ArgumentError, ~r/needs the Alambique replicas/, fn -> build([replicas: true], replicas: false) end
      assert_raise ArgumentError, ~r/replica_exit must be below/, fn -> build([replica_exit: 1_000], replicas: []) end
      assert_raise ArgumentError, fn -> build([replica_hold_ms: 0], replicas: []) end
    end
  end

  describe "the Alambique options that Atanor checks" do
    test "pipeline_depth is 1 to 16 and replicas are off or a keyword list" do
      assert %{alambique_opts: opts} = build(nil, pipeline_depth: 16, replicas: [max_cells: 4])
      assert opts[:pipeline_depth] == 16 and opts[:replicas] == [max_cells: 4]
      assert %{alambique_opts: opts} = build(nil, [])
      refute Keyword.has_key?(opts, :pipeline_depth)
      refute Keyword.has_key?(opts, :replicas)

      for bad <- [[pipeline_depth: 0], [pipeline_depth: 17], [pipeline_depth: "8"], [replicas: true], [replicas: 1]] do
        assert_raise ArgumentError, fn -> build(nil, bad) end
      end
    end
  end
end
