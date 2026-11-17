defmodule Atanor.LoadConfigTest do
  use ExUnit.Case, async: true

  # scripts/load_config.py: the round config of the load tests, read, merged over the defaults and validated. No container is started.

  setup do
    dir = Path.join(System.tmp_dir!(), "atanor-load-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "the round files are valid and the defaults are today's", %{dir: dir} do
    {out, status} = System.cmd("python3", ["-I", "test/scripts/load_config_check.py", dir], stderr_to_stdout: true)
    assert status == 0, out
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

    # every default equals the default of load-run's arguments (52 compared), and so do its ramps, measures and scale loads
    assert r["mismatch"] == %{}
    assert r["checked"] == 52
    assert r["ramps"] == r["ramps_of_load_run"] |> Map.new(fn {k, [a, b]} -> {k, [a / 1, b / 1]} end)
    assert r["units_match"] and r["scale_loads_match"]

    # example.toml is the defaults, key for key
    assert r["example_is_default"]

    # 018f.toml: the steps of the official round, per scenario
    o = r["official"]
    assert o["plans"]["A_http-native"] == [490, 650, 810, 975]
    assert o["plans"]["B_http-native"] == [1125, 1500, 1875, 2250]
    assert o["plans"]["A_ws"] == [2400, 3200, 4000, 4800]
    assert o["plans"]["B_ws"] == [15000, 20000, 25000, 30000]
    assert o["plans"]["A_cells"] == [353, 470, 588, 705]
    assert o["plans"]["B_cells"] == [1500, 2000, 2500, 3000]
    assert o["plans"]["A_http-wasm-jobs"] == [34, 45, 56, 68]
    assert o["plans"]["B_http-wasm-jobs"] == [68, 90, 112, 135]
    assert o["http_wasm"] == "bisect"

    assert o["scale"]["ceilings"] == %{
             "http-native:1" => 600,
             "http-native:2" => 840,
             "cells:1" => 470,
             "cells:2" => 750
           }

    assert o["scale"]["max_nodes"] == 2 and o["scale"]["ceiling_factors"] == [1.0, 1.5] and
             o["scale"]["join"]["enabled"]

    assert o["scale_run_on"] == ["A"]
    assert o["store"] == "disk" and o["min_available_gb"] == 1.0 and o["max_connections"] == 40000

    # the hash is stable (the spelling of a value does not matter) and changes with a value
    assert r["hash"] == %{"stable" => true, "changes" => true, "length" => 64}
  end

  test "an invalid config is refused with every problem", %{dir: dir} do
    {out, status} = System.cmd("python3", ["-I", "test/scripts/load_config_check.py", dir], stderr_to_stdout: true)
    assert status == 0, out
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

    assert r["unknown_key"] == ["measures.cells.steps.factr: unknown key (did you mean 'factor'?)"]
    assert r["unknown_table"] == ["judgng: unknown key (did you mean 'judging'?)"]

    assert r["wrong_type"] == [
             "judging.p99.max_ms: expected a number, got a string",
             "judging.delivery.enabled: expected true or false, got a whole number"
           ]

    assert r["out_of_range"] == [
             "judging.delivery.min_ratio: 1.5 is out of range, expected > 0 and <= 1",
             "judging.refused.max_pct: 0 is out of range, expected > 0 and <= 100",
             "measures.cells.steps.refine: -1 is out of range, expected >= 0"
           ]

    assert Enum.any?(r["unknown_measure"], &String.starts_with?(&1, "measures.disk: unknown measure 'disk'"))
    assert Enum.any?(r["unknown_measure"], &String.starts_with?(&1, "round.measures[1]: 'disk' is not one of"))
    assert Enum.any?(r["unknown_scenario"], &String.starts_with?(&1, "scenarios.C: unknown scenario 'C'"))

    assert r["ladder_without_values"] == ["measures.cells.steps.values: a ladder needs values"]
    assert "measures.cells.steps.values: the values must grow, each above the one before" in r["ladder_not_growing"]
    assert r["bisect_start_above_max"] == ["measures.ws.steps: start 100 is above max 50"]

    assert r["bisect_with_values"] == [
             "measures.ws.steps.values: only a ladder uses values; set kind = \"ladder\" or remove them"
           ]

    assert r["per_scenario_not_in_round"] == ["measures.ws.per_scenario.B: scenario B is not in round.scenarios"]
    assert r["per_scenario_ladder"] == ["measures.ws.per_scenario.B.values: a ladder needs values"]
    assert r["bad_size"] == ["scenarios.A.memory: 'lots' is not a size, use a whole number with k, m or g (512m, 2g)"]

    assert r["ceiling_key"] == [
             "scale.ceilings.cells: expected LOAD:NODES, like http-native:2",
             "scale.ceilings.cells:9: nodes must be 1 to scale.max_nodes (3)",
             "scale.ceilings.ws:1: ws is not in scale.loads"
           ]

    assert r["ssh_without_repo"] == ["host.repo: required when host.ssh is set"]
    assert r["many"] == 3
    assert [<<"not valid TOML", _::binary>>] = Enum.map(r["not_toml"], &binary_part(&1, 0, 14))
    assert r["missing_file"] == ["cannot read the file: No such file or directory"]
  end

  test "--check prints the resolved config, or every problem and exit status 1", %{dir: dir} do
    ok = Path.join(dir, "ok.toml")
    File.write!(ok, "[judging.p99]\nmax_ms = 300\n")
    {out, 0} = System.cmd("python3", ["-I", "scripts/load_config.py", "--check", ok], stderr_to_stdout: false)
    assert :json.decode(out)["judging"]["p99"] == %{"enabled" => true, "max_ms" => 300.0}

    bad = Path.join(dir, "bad.toml")
    File.write!(bad, "[judging.p99]\nmax_ms = -1\n[nope]\n")
    {out, status} = System.cmd("python3", ["-I", "scripts/load_config.py", "--check", bad], stderr_to_stdout: true)
    assert status == 1
    assert out =~ "invalid load config #{bad}"
    assert out =~ "judging.p99.max_ms: -1 is out of range"
    assert out =~ "nope: unknown key"
  end
end
