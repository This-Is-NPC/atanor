defmodule Atanor.LoadScaleTest do
  use ExUnit.Case, async: true

  # The scale measure of scripts/load-run (1 to 3 nodes behind the balancer, then the join) with `docker`, `load-env`, the balancer
  # and the generator stubbed: no container is started. The stub lab holds 100 req/s per node.

  setup do
    dir = Path.join(System.tmp_dir!(), "atanor-load-scale-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "gain, spread detection, lifecycle of the nodes, INVALID and --max-nodes", %{dir: dir} do
    {out, status} = System.cmd("python3", ["-I", "test/scripts/load_scale_check.py", dir], stderr_to_stdout: true)
    assert status == 0, out
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

    # the gain over one node, with the ideal and the efficiency; nothing without the 1-node ceiling
    assert r["gain"]["1"] == %{"ceiling" => 400, "gain" => 1.0, "ideal" => 1, "efficiency" => 1.0}
    assert r["gain"]["2"] == %{"ceiling" => 760, "gain" => 1.9, "ideal" => 2, "efficiency" => 0.95}
    assert r["gain"]["3"] == %{"ceiling" => 1100, "gain" => 2.75, "ideal" => 3, "efficiency" => 0.92}
    assert r["gain_no_base"] == %{}
    assert r["steps_of"] == [[300, 400, 500, 600], [1], [300]]
    assert r["parse_ceilings"] == %{"http-native:1" => 400, "cells:2" => 9000}

    # how far the shares are from 1/N, and the spread: the first of `hold` consecutive good readings; a short run or too few requests is not one
    assert r["deviation"] == [0.0, 0.5, 1.0, :null]
    assert r["spread_time"] == %{"held" => 2, "short" => :null, "never" => :null, "too_few" => :null}
    assert r["interval_points"] == [[0, %{"node-1" => 10, "node-2" => 0}], [1, %{"node-1" => 10, "node-2" => 10}]]

    # the requests of a step are the growth of the balancer's counters; the cells awake are the last reading
    d = r["distribution"]
    assert d["requests"] == %{"node-1" => 200, "node-2" => 100}
    assert d["request_share"] == %{"node-1" => 0.667, "node-2" => 0.333}
    assert d["request_deviation"] == 0.333
    assert d["cells_awake"] == %{"node-1" => 30, "node-2" => 10}
    assert d["cells_deviation"] == 0.5
    assert r["distribution_none"] == [:null, :null]

    # what the balancer and the admin API do not say is null
    assert r["haproxy"] == %{
             "requests" => %{"node-1" => 120, "node-2" => 80},
             "backend" => %{"stot" => 200, "hrsp_5xx" => 5, "econ" => 1, "eresp" => 2, "wretr" => 3, "wredis" => 4},
             "down" => :null,
             "none" => :null
           }

    assert r["cells_by_node"] == [%{"node-1" => 7}, :null]

    # a scale step goes through the balancer
    assert r["target"] == [["127.0.0.1", "8080"], ["127.0.0.1", "4000"], ["--host", "127.0.0.1", "--port", "8080"]]

    # the lifecycle: 1, 2 and 3 nodes, each ramp starting at the ceiling of one node fewer; every step is a record of `scale`
    ramp = r["ramp"]
    assert ramp["ceilings"] == %{"http-native" => %{"1" => 100, "2" => 195, "3" => 244}}
    assert ramp["approved"] == [100, 195, 244] and ramp["confirmed"] == [true, true, true]
    assert ramp["gain"]["2"]["gain"] == 1.95 and ramp["gain"]["2"]["ideal"] == 2
    assert ramp["gain"]["3"]["gain"] == 2.44 and ramp["gain"]["3"]["efficiency"] == 0.81
    assert ramp["largest_fit"] == 3 and ramp["invalid"] == :null and ramp["exit"] == 0
    assert Enum.all?(ramp["stopped_by"], &(&1 =~ "p99"))
    assert Enum.all?(ramp["records"], &match?(["scale", "http-native", _, _, _], &1))
    assert Enum.map(ramp["records"], &Enum.at(&1, 2)) |> Enum.uniq() == [1, 2, 3]
    assert ramp["files"] == ["A/scale/http-native-n3/step-195.json", "A/scale/http-native-n3/step-244.json"]
    assert ramp["distribution"]["requests"] |> Map.keys() |> Enum.sort() == ["node-1", "node-2"]
    assert ramp["distribution"]["request_deviation"] == 0.0

    # the join is skipped on request
    assert ramp["join_note"] == "join skipped (--no-join)"

    # --max-nodes 2: no configuration with 3 nodes; the join has 2
    max = r["max_nodes"]
    assert max["resets"] == [1, 2]
    assert max["configs"] == [["http-native", 1], ["http-native", 2]]
    assert max["join_nodes"] == 2 and max["largest_fit"] == 2 and max["advice"] == :null

    # the host over its limit at 3 nodes: that step is INVALID, no larger one runs, the largest that fit is recorded, the exit status is 1
    invalid = r["invalid"]
    assert invalid["statuses"] == ["invalid"] and invalid["valid"] == [false]
    assert invalid["invalid"] =~ ~r/^host contaminated: net load [\d.]+ > 1$/
    assert [%{"load" => "http-native", "nodes" => 3}] = invalid["invalids"]
    assert invalid["largest_fit"] == 2 and invalid["ceilings"] == [1, 2]
    assert invalid["advice"] == "the lab did not hold 3 nodes: rerun with --max-nodes 2"
    assert invalid["exit"] == 1

    # not even one node fits: nothing larger is started
    one = r["invalid_one"]
    assert one["largest_fit"] == 0 and one["configs"] == [1] and one["resets"] == [1]
    assert one["advice"] =~ "not even one node"

    # the exploration: the steps are fractions of earlier ceilings, a configuration without one is skipped, no confirmation
    explore = r["explore"]

    assert explore["configs"] == [
             [1, 100, :null, :null],
             [2, 200, :null, :null],
             [3, :null, :null, "no ceiling for http-native on 3 nodes in --ceilings"]
           ]

    assert explore["gain"] == %{"1" => 1.0, "2" => 2.0}
    assert explore["steps"] == ["step-100.json", "step-200.json", "step-300.json"]

    # the cells load goes through the same machinery
    assert r["cells"]["loads"] == ["cells"] and r["cells"]["approved"] == [100, 195]

    # one of three nodes dies during a step: the step fails and names the node
    dies = r["node_dies"]
    assert dies["status"] == "fail" and dies["node_stopped"] == true
    assert dies["reason"] == "node-2: node OOM-killed"
    assert dies["nodes"] == 3 and dies["measure"] == "scale" and dies["diagnostics"] == 3
    assert dies["files"] == ["step-10.node.log"]

    # the join: node 2 starts under the load; the requests spread as soon as it is in rotation, the cells when they move
    join = r["join"]
    assert join["status"] == "ok" and join["windows"] == [1, 2]
    assert join["requests_spread_s"] > 0 and join["requests_spread_s"] < 1.0
    assert join["cells_spread_s"] > join["requests_spread_s"] and join["cells_spread_s"] < 2.0
    assert join["since_ready"] <= join["requests_spread_s"]
    assert join["ready_s"] >= 0.2
    assert join["requests_share_end"] == %{"node-1" => 0.5, "node-2" => 0.5}
    assert join["cells_share_end"] == %{"node-1" => 0.5, "node-2" => 0.5}
    state = %{"moves" => 3, "total" => %{"moved" => 7}}
    assert join["rebalance"] == %{"node-1" => state, "node-2" => state}

    # every reading of a window has the 5xx and the moves since the previous one: the lone node refuses, the moves are the nodes' totals
    series = r["join_series"]
    assert [[:null, %{"node-1" => 7}], [n, %{"node-1" => 7}]] = series["lone"]
    assert n > 0
    assert series["joined"] == [0, %{"node-1" => 7, "node-2" => 7}, 0]

    assert series["in_band_s"] > 0 and series["in_band_s"] <= join["cells_spread_s"] and
             series["first_window_in_band"] == :null

    assert r["window_series"] == [
             %{
               "t" => 0.0,
               "moved" => %{"node-1" => 1, "node-2" => :null},
               "new_5xx" => :null,
               "moved_new" => :null,
               "runtime_errors" => %{}
             },
             %{
               "t" => 2.0,
               "moved" => %{"node-1" => 4, "node-2" => 2},
               "new_5xx" => 3,
               "moved_new" => 5,
               "runtime_errors" => %{}
             },
             %{"t" => 4.0, "moved" => %{}, "new_5xx" => :null, "moved_new" => :null, "runtime_errors" => %{}}
           ]

    # the host's cores run out at 2 nodes: that step is INVALID and the larger ones are not run
    saturated = r["saturated"]
    assert saturated["invalid"] =~ ~r/^host saturated: [\d.]+ busy cores > 1.6 \(20% of 8 cores\)$/
    assert saturated["largest_fit"] == 1
    assert join["errors_before"] > 0 and join["generator"] == 10
    assert join["file"] == ["A/scale/join/step-2000.json"] and join["notes"] == []

    # without a rebalance the cells never spread, and no field of it is needed; with no cells reading everything about them is null
    none = r["join_no_rebalance"]
    assert none["status"] == "ok" and none["requests_spread"] == true
    assert none["cells_spread_s"] == :null and none["cells_share_end"] == %{"node-1" => 1.0, "node-2" => 0.0}
    assert none["rebalance"] == %{"node-1" => :null, "node-2" => :null}
    assert none["notes"] == ["no node reports a rebalance state in /runtime"]
    missing = r["join_missing_fields"]
    assert missing["status"] == "ok" and missing["requests_spread"] == true
    assert missing["cells_spread_s"] == :null and missing["cells_share_end"] == :null

    # a step on two nodes records every node's throttling, in-flight maximum and refusals; the 503 answers are attributed over both nodes
    two = r["two_nodes"]
    assert two["series_nodes"] == ["node-1", "node-2"]
    [n1, n2] = [two["per_node"]["node-1"], two["per_node"]["node-2"]]
    assert {n1["in_flight_max"], n2["in_flight_max"]} == {4, 9}
    assert n1["throttled_ms"] == 0 and n2["throttled_ms"] > 0 and n2["throttled_jump_ms"] > 0
    assert {n1["refused"]["wake_gate"], n2["refused"]["wake_gate"]} == {3, 4}
    assert n1["runtime_failed"] == 0 and n1["runtime_error"] == :null

    assert two["refusals"] == %{
             "answers_503" => 10,
             "by_cause" => %{"wake_gate" => 7, "busy" => 0},
             "attributed" => 7,
             "unattributed" => 3
           }

    assert "3 of 10 503 answers not attributed: no refusal counter of the node grew for them" in two["notes"]

    assert two["evictions"] == %{
             "counter_in_runtime" => false,
             "cells_awake_start" => 7,
             "cells_awake_end" => 7,
             "cells_awake_change" => 0,
             # the stub nodes report no pressure counter
             "pressure_hibernated" => :null,
             "wakes" => :null,
             "wake_ms" => :null,
             "compaction" => :null,
             "disk_used_max_pct_of_budget" => 10.0,
             "disk_budget_bytes" => 100 * 1_048_576
           }

    # the counters of a newer node are read when present and null when absent: node 1 reports them, node 2 does not
    new = r["two_nodes_new"]
    assert new["wakes"] == 7
    assert new["unavailable_by_reason"] == %{"store_unavailable" => 2, "breaker_open" => 1}
    assert new["by_reason"] == %{"unavailable/store_unavailable" => 7, "overloaded/busy" => 3}
    [one, two_] = [new["per_node"]["node-1"], new["per_node"]["node-2"]]
    assert one["wakes"] == 7 and one["unavailable_by_reason"] == %{"store_unavailable" => 2, "breaker_open" => 1}
    assert one["refused"] == %{"unavailable" => 3}
    assert one["versions"] == %{"atanor" => "0.7.0", "alambique" => "0.14.0"} and two_["versions"] == :null
    assert two_["wakes"] == :null and two_["unavailable_by_reason"] == :null and two_["refused"] == %{"busy" => 0}

    # `unavailable` is a refusal cause: the 503 answers it counted are attributed
    assert new["refusals"] == %{
             "answers_503" => 10,
             "by_cause" => %{"unavailable" => 3, "busy" => 0},
             "attributed" => 3,
             "unattributed" => 7
           }

    # nodes that report another disk budget are named in the step's notes; equal budgets, or none, add no note
    assert "nodes differ in disk_budget_bytes: node-1 #{100 * 1_048_576}, node-2 #{200 * 1_048_576}" in new["notes"]
    same = r["two_nodes_same_budget"]
    refute Enum.any?(same["notes"], &(&1 =~ "disk_budget_bytes"))
    assert same["wakes"] == :null and same["unavailable_by_reason"] == :null and same["by_reason"] == %{}
    assert same["per_node"] == %{"node-1" => [:null, :null], "node-2" => [:null, :null]}

    budgets = r["join_budgets"]
    assert budgets["budgets"] == %{"node-1" => 100 * 1_048_576, "node-2" => 200 * 1_048_576}
    assert Enum.any?(budgets["notes"], &(&1 =~ "nodes differ in disk_budget_bytes"))
    assert r["join_no_budgets"]["budgets"] == %{"node-1" => :null, "node-2" => :null}
    refute Enum.any?(r["join_no_budgets"]["notes"], &(&1 =~ "disk_budget_bytes"))

    # the rebalance of a window is read mid-plan and at its end (later moves); a silent node is named with its error; an ok join keeps the evidence
    end_ = r["join_end"]
    assert end_["status"] == "ok"
    assert end_["observed"]["node-1"]["total"]["moved"] < end_["end"]["node-1"]["total"]["moved"]
    assert end_["observed"]["node-2"] == :null and end_["end"]["node-2"] == :null
    assert end_["first"] == [:null, :null]

    assert [first_failures, %{"node-2" => %{"readings" => readings, "error" => "TimeoutError: timed out"}}] =
             end_["failures"]

    assert first_failures == %{} and readings > 0
    assert end_["silent_samples"] == [[], ["node-2"]]

    assert end_["diagnostics"] == [
             "step-2000.node-1.node-state.txt",
             "step-2000.node-1.node.log",
             "step-2000.node-2.node-state.txt",
             "step-2000.node-2.node.log",
             "step-2000.store.log"
           ]

    assert Enum.all?(end_["diagnostics"], &(&1 in end_["files"]))
    assert "step-2000.window-1.runtime.json" in end_["files"]
    assert "step-2000.window-2.runtime.json" in end_["files"]
    assert end_["runtime_window_2"]["node-2"] == %{"error" => "TimeoutError: timed out"}
    assert end_["runtime_window_2"]["node-1"]["rebalance"]["total"]["moved"] > 0

    # the same host guards as a step: a busy host, a contaminated one and a lab that does not start are INVALID
    assert r["join_busy"]["status"] == "invalid" and r["join_busy"]["valid"] == false
    assert r["join_busy"]["reason"] =~ "host busy"
    assert r["join_contaminated"]["status"] == "invalid"
    assert r["join_contaminated"]["reason"] =~ ~r/^host contaminated: net load [\d.]+ > 1$/
    saturated_join = r["join_saturated"]
    assert saturated_join["status"] == "invalid" and saturated_join["valid"] == false
    assert saturated_join["reason"] =~ ~r/^host saturated: [\d.]+ busy cores > 1.6 \(20% of 8 cores\)$/
    assert saturated_join["busy"] > 1.6
    assert r["join_lab"] == %{"status" => "invalid", "reason" => "the lab did not start with 1 nodes"}

    # the report: the gain per node and the join
    {report, 0} = System.cmd("python3", ["-I", "scripts/load-report", ramp["dir"]], stderr_to_stdout: true)
    assert report =~ "### scale"
    assert report =~ "Node versions: node-1 atanor 0.7.0 / alambique 0.14.0"
    assert report =~ "| http-native | 2 | 195 | 1.95x | 2x | 97% | yes |"
    assert report =~ "| http-native | 3 | 244 | 2.44x | 3x | 81% | yes |"
    assert report =~ "#### http-native on 3 nodes"
    assert File.exists?(Path.join(ramp["dir"], "report.md"))
  end
end
