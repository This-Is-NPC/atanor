defmodule Atanor.LoadConfigTest do
  use ExUnit.Case, async: true

  # scripts/load_config.py: the round config of the load tests, read, merged over the defaults and validated. No container is started.

  setup do
    dir = Path.join(System.tmp_dir!(), "atanor-load-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "the round files are valid and example.toml holds the defaults", %{dir: dir} do
    {out, status} = System.cmd("python3", ["-I", "test/scripts/load_config_check.py", dir], stderr_to_stdout: true)
    assert status == 0, out
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

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
    assert o["store"] == "disk" and o["min_available_gib"] == 1.0 and o["max_connections"] == 40000

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

  test "round.cases, the store of a measure, the timeouts, the ws cap and the ceiling kind", %{dir: dir} do
    {out, status} = System.cmd("python3", ["-I", "test/scripts/load_config_check.py", dir], stderr_to_stdout: true)
    assert status == 0, out
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

    # round.cases replaces scenarios x measures and sets the order; without it each scenario runs its measures, run_on limiting them
    assert r["cases_order"] == [["B", "ws"], ["A", "cells"], ["A", "swap"]]
    assert r["cases_default"] == [["A", "ws"], ["A", "scale"], ["B", "ws"]]
    assert r["cases_run_on"] == ["round.cases: cannot be used with measures.ws.run_on; remove one of them"]
    assert r["cases_variant"] == ["round.cases[0]: unknown variant 'x', ws has no variants"]

    assert r["cases_bad"] == [
             "round.cases[0]: expected SCENARIO/MEASURE, like A/http-native",
             "round.cases[1]: unknown scenario 'C', expected one of A, B",
             "round.cases[2]: unknown measure 'disk', expected one of http-native, http-wasm, http-wasm-jobs, ws, cells, swap, scale",
             "round.cases[4]: 'A/cells' is listed twice"
           ]

    assert r["variant_table"] == ["measures.ws.variant.v: unknown variant 'v', there is no variant yet"]

    # [measures.M.store] overrides the store for that measure: its own lab (env) and hash, and only the keys it may override
    s = r["store_override"]
    assert s["ws"] == %{"backing" => "disk", "latency_ms" => 2.5} and s["cells"] == %{}
    assert s["env_ws"] == "1" and s["env_cells"] == "0" and s["latency_ws"] == "2.5"
    assert s["hash_ws_changes"] and s["hash_cells_same"]

    n = r["nocow"]
    assert n["hash_same"] and n["hash_backing_changes"]
    assert n["env_dir"] == "/srv/store" and n["env_tmpfs"] == ""
    assert n["relative"] == ["store.nocow_dir: 'store' is not an absolute path (or empty, for the default directory)"]

    assert r["store_override_bad"] == [
             "measures.ws.store.backing: 'usb' is not one of nocow, tmpfs, disk",
             "measures.ws.store.memory: unknown key, expected one of backing, tmpfs_size, latency_ms"
           ]

    # step_timeout_s must cover a step's duration_s and the generator's grace_s, and the join of the scale measure
    assert r["timeout_low"] == [
             "round.step_timeout_s: 100 s is below 210 s (measures.ws duration_s + generator.grace_s) of A/ws"
           ]

    assert r["timeout_ok"] == [] and r["timeout_default_is_valid"] == []

    assert r["timeout_scale_join"] == [
             "round.step_timeout_s: 300 s is below 390 s (the join of scale.join + generator.grace_s) of A/scale"
           ]

    # ws: a node cap must lie above the highest step
    cap = "the highest step, 1000 connections, is not below node.http_max_connections 1000"
    assert r["ws_cap"] == ["measures.ws.steps: " <> cap]
    assert r["ws_cap_ok"] == []
    assert [<<"measures.ws.steps: the highest step, ", _::binary>>] = r["ws_cap_bisect"]

    # ceiling: factors times the ceiling, rounded
    assert r["ceiling_plan"] == ["ceiling", [300, 400, 500, 600]]
    assert r["ceiling_missing"] == ["measures.cells.steps.ceiling: a ceiling plan needs the ceiling"]

    assert r["ceiling_with_values"] == [
             "measures.cells.steps.values: only a ladder uses values; set kind = \"ladder\" or remove them"
           ]

    assert r["scale_per_scenario"] == [%{"http-native:1" => 7}, [2.0]]

    assert r["scale_per_scenario_bad"] == [
             "scale.per_scenario.A.ceilings.cells:9: nodes must be 1 to scale.max_nodes (3)"
           ]

    assert r["errors_off"] == %{"enabled" => false}

    # the hash of a case holds what affects it, and not the output, the host, the timeouts or the other measures' plans
    h = r["case_hash"]
    assert h["stable"] and h["scenario"] and h["swap_section"] and h["scale_sees_load_plans"]
    assert h["ws_only_with_ws"] == [true, false, true, false]
    assert h["store_all"] == [true, true, true, true]

    # the resolved config as TOML reads back to itself (OUT/config.toml)
    assert r["toml_round_trip"] == [true, true, true, true, true]
    assert r["env_scale_no_nodes"] == [false, "1"]
    assert r["env_cap"] == ["", "40000"]

    # the compaction and the S3 pool of a node reach the lab as env lines; at 0 they are empty and the hash is as before
    n = r["node_options"]
    assert n["env_default"] == List.duplicate("", 8)
    assert n["env_set"] == ["67108864", "4", "8", "6", "2", "512", "3000", "+SDio 2 +S 1:1"]

    # node.erl_flags: "" by default and then not in the hash; a quote, ;, $, a backtick, a newline or a double space is refused
    e = n["erl_flags"]
    assert e["default"] == "" and e["default_hash_as_before"] and e["set_in_hash"] == "+SDio 2 +S 1:1"
    assert e["ok"] == [] and e["empty_ok"] == [] and e["bad"] == List.duplicate(1, 8)
    assert n["hash_set_changes"] and n["hash_default_as_before"] and n["round_trip"]
    bad = Enum.join(n["bad"], "\n")
    assert bad =~ "node.compaction.concurrency" and bad =~ "node.compaction.hold_bytes"
    assert bad =~ "node.compaction.release_on: unknown key" and bad =~ "node.store.pool_size"
    assert bad =~ "node.store.pool_timeout_ms" and bad =~ "node.store.bogus: unknown key"

    # node.lazy_restore.min_bytes: unset by default (-1: not in the hash, empty env line); 0 is a value (every restore lazy)
    z = r["lazy_restore"]
    assert z["default"] == -1 and z["env_default"] == "" and z["default_not_in_hash"]
    assert z["env_zero"] == "0" and z["env_set"] == "1048576"
    assert z["zero_in_hash"] == %{"min_bytes" => 0} and z["zero_changes_hash"] and z["round_trip"] == [true, true]
    assert Enum.all?(z["bad"], &(length(&1) == 1))
    assert Enum.join(List.flatten(z["bad"]), "\n") =~ "node.lazy_restore.min_bytes"

    # steps.reset_each_step: off by default, settable for one scenario; only the hash of the case that sets it changes (018f hashes pinned as before the option)
    x = r["reset_each_step"]
    assert x["default"] == false and x["plan_has_no_key"]
    assert x["old_hashes"] == ["5347ec0e9ca0cdd9", "e4de6dd0a98f94af", "a5922958882b75ff"]
    assert x["scenario_only"] == [false, true]
    assert x["hash"] == %{"jobs_B_changes" => true, "jobs_A_same" => true, "ws_B_same" => true, "measure_wide" => true}
    assert x["round_trip"]
    bad = Enum.join(x["bad"], "\n")
    assert bad =~ "measures.ws.steps.reset_each_step: expected true or false" and bad =~ "measures.swap.steps"
  end

  test "the names shared with Alambique, host.timeout_s and the judging of one measure", %{dir: dir} do
    {out, status} = System.cmd("python3", ["-I", "test/scripts/load_config_check.py", dir], stderr_to_stdout: true)
    assert status == 0, out
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

    n = r["renames"]
    assert n["data_tmpfs"] == ["256m", "1g"] and n["env_tmpfs"] == ["256m", "1g"]
    assert n["timeout_s"] == 172_800.0 and n["min_available_gib"] == 6.0
    assert n["old_node_tmpfs"] == ["scenarios.A.node_tmpfs: unknown key (did you mean 'data_tmpfs'?)"]

    assert n["old_min_available_gb"] == [
             "judging.host_memory.min_available_gb: unknown key (did you mean 'min_available_gib'?)"
           ]

    assert n["timeout_bad"] == ["host.timeout_s: 0 is out of range, expected > 0"]

    # [measures.M.judging.RULE] holds only what is given, is merged for that measure only and enters its hash
    m = r["measure_judging"]
    assert m["override"] == %{"p99" => %{"max_ms" => 400.0}, "refused" => %{"enabled" => false}, "stall_repeats" => 2}
    assert m["others"] == %{} and m["general"] == %{"enabled" => true, "max_ms" => 250.0}
    assert m["merged_ws"] == [%{"enabled" => true, "max_ms" => 400.0}, %{"enabled" => false, "max_pct" => 1.0}, 2]
    assert m["merged_cells"] == %{"enabled" => true, "max_ms" => 250.0}
    assert m["hash_ws_changes"] and m["hash_cells_same"] and m["hash_swap_same"] and m["round_trip"]

    assert m["bad"] == [
             "measures.ws.judging.p99.max_ms: -1 is out of range, expected > 0",
             "measures.ws.judging.p99.max: unknown key (did you mean 'max_ms'?)",
             "measures.ws.judging.nope: unknown key, expected one of stall_repeats, errors, p99, refused, memory, fds, delivery, store_fill, store_stall, generator_lag, throttle, host_load, host_busy, generator_swap, host_swap, host_memory"
           ]
  end

  test "[scale.judging.LOAD] judges one load of the scale on its own rules", %{dir: dir} do
    {out, status} = System.cmd("python3", ["-I", "test/scripts/load_config_check.py", dir], stderr_to_stdout: true)
    assert status == 0, out
    s = out |> String.split("\n", trim: true) |> List.last() |> :json.decode() |> Map.fetch!("scale_judging")

    # scale load over measures.scale.judging over [judging], rule by rule
    assert s["cells"] == [
             %{"enabled" => true, "max_ms" => 900.0},
             %{"enabled" => false},
             %{"enabled" => true, "max_pct" => 2.0}
           ]

    assert s["http_native"] == [
             %{"enabled" => true, "max_ms" => 400.0},
             %{"enabled" => true},
             %{"enabled" => true, "max_pct" => 2.0}
           ]

    assert s["measure_only"] == %{"enabled" => true, "max_ms" => 400.0}
    assert s["other_measure"] == %{"enabled" => true, "max_ms" => 250.0}
    assert s["hash_changes"] and s["hash_stable"] and s["hash_cells_same"] and s["round_trip"]

    assert s["bad"] == [
             "scale.judging.cells.p99.max_ms: -1 is out of range, expected > 0",
             "scale.judging.cells.p99.max: unknown key (did you mean 'max_ms'?)",
             "scale.judging.cells.nope: unknown key, expected one of stall_repeats, errors, p99, refused, memory, fds, delivery, store_fill, store_stall, generator_lag, throttle, host_load, host_busy, generator_swap, host_swap, host_memory",
             "scale.judging.ws: unknown load 'ws', expected one of http-native, http-wasm, http-wasm-jobs, cells"
           ]
  end

  test "--env prints the lab's ATANOR_LOAD_* lines of a scenario, with the store of a measure", %{dir: dir} do
    file = Path.join(dir, "round.toml")
    File.write!(file, "[store]\nlatency_ms = 7\n[measures.ws.store]\nbacking = \"disk\"\n")

    {out, 0} = System.cmd("python3", ["-I", "scripts/load_config.py", "--env", file, "B", "ws"])
    lines = String.split(out, "\n", trim: true)
    assert "ATANOR_LOAD_CPUS=2" in lines and "ATANOR_LOAD_MEMORY=2g" in lines and "ATANOR_LOAD_TMPFS_SIZE=1g" in lines
    assert "ATANOR_LOAD_STORE_DISK=1" in lines and "ATANOR_LOAD_STORE_LATENCY_MS=7" in lines
    assert "ATANOR_LOAD_NODES=1" in lines and "ATANOR_LOAD_HTTP_MAX_CONNECTIONS=''" in lines

    assert "ATANOR_LOAD_STORE_NOCOW_DIR=''" in lines

    # the default backing is nocow, in ${XDG_CACHE_HOME:-$HOME/.cache}/atanor-load/store
    {out, 0} =
      System.cmd("python3", ["-I", "scripts/load_config.py", "--env", file, "A", "scale"],
        env: [{"XDG_CACHE_HOME", "/tmp/xdg-cache"}]
      )

    assert "ATANOR_LOAD_STORE_DISK=0" in String.split(out, "\n", trim: true)
    assert "ATANOR_LOAD_STORE_NOCOW_DIR=/tmp/xdg-cache/atanor-load/store" in String.split(out, "\n", trim: true)
    refute out =~ "ATANOR_LOAD_NODES"

    {out, status} = System.cmd("python3", ["-I", "scripts/load_config.py", "--env", file, "C"], stderr_to_stdout: true)
    assert status == 2 and out =~ "--env takes a scenario"
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
