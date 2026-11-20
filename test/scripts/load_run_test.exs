defmodule Atanor.LoadRunTest do
  use ExUnit.Case, async: true

  # scripts/load-run and scripts/load-env with `docker` and `load-env` stubbed on PATH: no container is started.

  setup do
    dir = Path.join(System.tmp_dir!(), "atanor-load-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "a limit of the node is a result of the step, never a crash of the runner", %{dir: dir} do
    {out, status} = System.cmd("python3", ["-I", "test/scripts/load_run_check.py", dir], stderr_to_stdout: true)
    assert status == 0, out
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

    # load-env rtt fails, the node is fine: the step stays as measured, the rtt is unknown.
    ok = r["rtt_fails"]["record"]
    assert ok["status"] == "ok"
    assert ok["store_rtt_ms"] == :null
    assert "store rtt not measured" in ok["notes"]
    assert ok["diagnostics"] == []

    # cells: p99 and refusals are judged on the hold; the opening's are apart, and the step records the node's connection cap
    hold = r["cells_hold"]["record"]
    assert hold["status"] == "ok" and hold["latency_ms"]["p99"] < 10

    assert hold["opening"]["refused"] == 5 and hold["opening"]["refused_pct"] == 50.0 and
             hold["opening"]["latency_ms"]["p99"] > 250

    assert hold["statuses"] == %{"200" => 15, "503 retry-after" => 5} and hold["http_max_connections"] == 16_384

    # http: the warm-up is the opening, reported apart; the step is judged on the steady part. The generators warm up unless told not to.
    warm = r["http_warmup"]["record"]
    assert warm["status"] == "ok" and warm["latency_ms"]["p99"] < 10
    assert warm["opening"]["refused"] == 5 and warm["opening"]["latency_ms"]["p99"] > 250
    assert r["warmup_commands"] == %{"on" => true, "open_rate" => "100.0", "off" => false, "cells" => false}
    refused = r["cells_hold_refused"]["record"]
    assert refused["status"] == "fail" and refused["stop_reason"] =~ "refused 50.0%"
    assert refused["opening"]["refused"] == 0
    assert r["rtt_fails"]["record"]["opening"] == :null

    # the host's cores: busy cores over 85% of them are INVALID; CPU limits that add up to more than the host's cores are a warning, never a refusal
    assert r["judge_busy"] == ["host saturated: 3.5 busy cores > 3.4 (85% of 4 cores)", :null, :null]
    [[7, three], [5, one], [4, two], [5, _]] = r["cpu_caps"]
    assert three =~ "add up to 7 (3 nodes x 1 + store 2 + balancer 2), more than the host's 4 cores"
    assert one =~ "add up to 5" and two == :null

    # the ws ramp stays under the node's connection cap, and the cap under its descriptor limit
    [reaches, fits, over_fds, below] = r["ws_cap"]
    assert reaches =~ "reaches the node's http.max_connections 16384" and fits == :null
    assert over_fds =~ "not below its descriptor limit 65536" and below == :null
    assert r["max_connections"] == [16_384, 70_000]

    # the admin API is unreachable: the runtime is unknown, the step is not
    assert ok["runtime"] == :null
    assert ok["memory"]["current_max_mb"] == :null

    # the admin API answers: maxima over the samples, the oom kills of the last one, the lists of the sample at the peak
    runtime = r["runtime_ok"]["record"]["runtime"]
    n = r["runtime_ok"]["calls"]
    assert runtime["samples"] == n and n >= 2
    assert runtime["versions"] == %{"atanor" => "0.7.0", "alambique" => "0.14.0"}
    assert runtime["memory_max_bytes"]["total"] == 100 * n
    assert runtime["memory_max_bytes"]["binary"] == 30
    assert runtime["process_count_max"] == 50 + n
    assert runtime["cgroup_max_bytes"] == %{"anon" => 7 * n, "shmem" => 1, "file" => :null, "sock" => 2 * n}
    assert runtime["oom_kill"] == n
    assert [%{"initial_call" => "erlang.apply/2"}] = runtime["at_peak"]["top_memory"]
    assert [%{"name" => "t"}] = runtime["at_peak"]["ets"]
    assert r["runtime_ok"]["record"]["status"] == "ok"

    # the store's tmpfs at 93% with a failing p99: INVALID for the store, not a fail; at 50% the p99 fails the step as usual
    full = r["store_full"]
    assert full["status"] == "invalid" and full["valid"] == false
    assert full["stop_reason"] == "store tmpfs 93.1% > 90%"
    assert full["store"]["tmpfs_max_pct"] == 93.1
    half = r["store_half"]
    assert half["status"] == "fail" and half["valid"] == true
    assert half["stop_reason"] =~ "p99"
    assert half["store"]["tmpfs_max_pct"] == 50.0

    # the store on disk: its disk use is judged, not a tmpfs, and the backing is in the step file
    disk_full = r["disk_full"]
    assert disk_full["status"] == "invalid" and disk_full["valid"] == false
    assert disk_full["stop_reason"] == "store disk 95% > 90%"
    assert disk_full["store_backing"] == "disk" and disk_full["store"]["backing"] == "disk"
    assert disk_full["store"]["tmpfs_max_pct"] == :null
    assert disk_full["store"]["disk_used_max_mb"] == 950.0 and disk_full["store"]["disk_free_min_mb"] == 50.0
    disk_half = r["disk_half"]
    assert disk_half["status"] == "fail" and disk_half["valid"] == true
    assert disk_half["stop_reason"] =~ "p99"
    assert disk_half["store"]["disk_max_pct"] == 50.0
    assert half["store_backing"] == "tmpfs" and half["store"]["backing"] == "tmpfs"
    assert half["store"]["disk_max_pct"] == nil

    # a node that stopped is still the result; the store's share is noted
    dead = r["store_full_dead"]
    assert dead["status"] == "fail" and dead["node_stopped"] == true
    assert "store tmpfs 93.1% > 90%" in dead["notes"]
    assert runtime["cgroup_memory_max_bytes"] == 2

    # the time series: one entry per sample, with the admission and the store fields
    record = r["runtime_ok"]["record"]
    series = record["series"]
    assert length(series) >= 2
    last = List.last(series)
    assert last["working_set"] == 1000 * n
    assert last["refusing"] == 1
    assert last["in_flight"] == n
    assert last["refused_memory"] == 10 * n and last["refused_in_flight"] == n and last["refused_disk"] == 0
    assert last["inactive_file"] == 3 * n and last["anon"] == 7 * n and last["oom_kill"] == n
    assert last["beam_total"] == 100 * n and last["beam_processes"] == :null and last["process_count"] == 50 + n

    assert last["store_shmem"] == 256 * 1_048_576 and last["store_limit"] == 1280 * 1_048_576 and
             is_integer(last["store_s3_errors"])

    # the store breaker (open in the last /runtime sample, closed in the first) and the node's CPU throttling, to place a stall
    assert last["store_breaker_open"] == 1 and hd(series)["store_breaker_open"] == 0
    assert last["node_throttled_ms"] == 1500

    assert r["rtt_fails"]["record"]["series"]
           |> Enum.all?(&(&1["store_breaker_open"] == :null and &1["node_throttled_ms"] == :null))

    assert record["admission"]["refuse_at_bytes"] == 400 * 1_048_576
    assert record["admission"]["refusing_seen"] == true

    # only the causes the node reports are counted; the others are listed as unreported, not shown as 0
    assert record["admission"]["refused"] == %{"memory" => 10 * (n - 1), "in_flight" => n - 1, "disk" => 0}

    assert record["admission"]["refused_unreported"] ==
             ~w(wake_gate awake_limit busy disk_full queue_timeout worker_queue nested_calls unavailable)

    # 503 answers are set against every counter the node grew: 10 answers, wake_gate 6 and busy 1 counted, 3 unattributed
    refusals = r["refusals"]["attributed"]

    assert refusals["refusals"] == %{
             "answers_503" => 10,
             "by_cause" => %{"wake_gate" => 6, "busy" => 1, "memory" => 0},
             "attributed" => 7,
             "unattributed" => 3
           }

    assert "3 of 10 503 answers not attributed: no refusal counter of the node grew for them" in refusals["notes"]
    assert refusals["admission"]["disk_used_max_pct_of_budget"] == 50.0
    assert refusals["evictions"]["counter_in_runtime"] == false
    # the growth of the node's pressure counter over the step, and none without a /runtime reading
    assert refusals["evictions"]["pressure_hibernated"] == 4
    assert r["refusals"]["no_runtime"]["evictions"]["pressure_hibernated"] == :null
    assert r["refusals"]["no_runtime"]["refusals"] == :null
    assert "10 503 answers not attributed: no /runtime reading" in r["refusals"]["no_runtime"]["notes"]
    assert r["refusals"]["all_counted"]["refusals"]["unattributed"] == 0
    refute Enum.any?(r["refusals"]["all_counted"]["notes"], &(&1 =~ "not attributed"))

    # an older node reports none of the newer counters: null, not 0; the 503 reasons come from the generator
    assert refusals["evictions"]["wakes"] == :null
    assert refusals["evictions"]["compaction"] == :null
    assert refusals["admission"]["unavailable_by_reason"] == :null
    assert refusals["statuses_503_by_reason"] == %{}

    # a newer node: `unavailable` is a refusal cause (those 503 answers are attributed), its reasons and the wakes are the growth over the step
    newer = r["refusals"]["newer"]
    assert newer["refusals"]["by_cause"] == %{"unavailable" => 7, "busy" => 1}
    assert newer["refusals"]["attributed"] == 8 and newer["refusals"]["unattributed"] == 2
    assert newer["admission"]["unavailable_by_reason"] == %{"store_unavailable" => 3, "breaker_open" => 0}
    assert newer["admission"]["awake_limit_by"] == %{"no_wait" => 0, "wait_expired" => 4}
    assert refusals["admission"]["awake_limit_by"] == :null
    assert newer["admission"]["refused_unreported"] |> Enum.member?("unavailable") == false
    assert newer["evictions"]["wakes"] == 15

    assert newer["evictions"]["compaction"] == %{
             "none" => 0,
             "done" => 2,
             "deadline" => 2,
             "error" => 0,
             "tail_max" => 192
           }

    # the lazy restores are the growth over the step, `ms_max` the node's longest; an older node reports none (null)
    assert newer["lazy_restores"] == %{
             "ok" => 2,
             "error" => 1,
             "pages" => 60,
             "misses" => 6,
             "ms_total" => 330,
             "ms_max" => 200
           }

    assert refusals["lazy_restores"] == :null

    assert newer["statuses_503_by_reason"] == %{"unavailable/store_unavailable" => 7, "overloaded/busy" => 3}

    assert record["store"]["tmpfs_max_pct"] == 50.0
    assert record["store"]["limit_mb"] == 1280.0
    assert r["rtt_fails"]["record"]["series"] |> Enum.all?(&(&1["working_set"] == :null))

    # the criterion is the node's working set (memory.current - inactive_file, tmpfs included) against the scenario's 512 MB
    assert r["memory_criterion"] == %{
             "service_max_mb" => 650.0,
             "tmpfs_start_mb" => 256.0,
             "tmpfs_max_mb" => 300.0,
             "tmpfs_growth_mb" => 44.0,
             "limit_mb" => 512.0,
             "max_pct_of_limit" => 127.0
           }

    # the swap record is written with the usage against the scenario memory (swap() crashed on a name that did not exist)
    assert r["swap"] == %{
             "status" => "ok",
             "valid" => true,
             "stop_reason" => :null,
             "service_max_mb" => 600.0,
             "limit_mb" => 512.0,
             "refused" => 30
           }

    # the swap runs through load-env; the status of the measure: 1 for an invalid step and for a swap that did not pass
    assert r["swap_command"] == [r["swap_command"] |> hd(), "swap"]
    assert String.ends_with?(hd(r["swap_command"]), "/scripts/load-env")

    assert r["exit_status"] == %{
             "swap_ok" => 0,
             "swap_fail" => 1,
             "swap_invalid" => 1,
             "ramp_ok" => 0,
             "ramp_invalid" => 1
           }

    # host swap: a high, flat level is valid; growth over the limit is not
    assert r["host_swap"]["flat"] == :null
    assert r["host_swap"]["grows"] == "host swap grew 300 MB > 256 MB"

    # the quiet wait and the contamination rule
    assert r["is_quiet"] == %{
             "empty" => false,
             "short" => false,
             "long" => true,
             "burst_resets" => false,
             "burst_last" => false
           }

    assert r["judge_host"] == %{"over" => "host contaminated: net load 1.6 > 1", "at" => :null, "unknown" => :null}
    assert r["net_load"] == %{"busy" => 3.0, "foreign" => 1.0}

    # a lab reading missing in one sample (one failed cgroup read after ~300 CPU s) is skipped, never ~100 foreign cores
    assert r["net_load_gap"] == %{
             "into" => :null,
             "out_of" => :null,
             "generator" => :null,
             "idle_back" => :null,
             "skipped" => 2,
             "mean" => 0.0,
             "max" => 0,
             "verdict" => :null
           }

    assert r["is_quiet_gap"] == false
    assert %{"quiet" => true} = r["wait_quiet"]["idle"]
    assert %{"quiet" => false} = r["wait_quiet"]["busy"]
    assert r["host_busy"]["status"] == "invalid"
    assert r["host_busy"]["stop_reason"] =~ "host busy"
    assert r["host_busy"]["generator_runs"] == 0
    assert r["host_contaminated"]["status"] == "invalid"
    assert r["host_contaminated"]["stop_reason"] =~ ~r/^host contaminated: net load [\d.]+ > 1$/
    assert r["host_contaminated"]["generator_runs"] == 1

    assert [%{"name" => "high"}] = r["peak"]["at_peak"]["ets"]
    assert r["peak"]["samples"] == 2

    # after a failure every refine and the confirmation run on a fresh node; the ramp steps and a clean confirmation do not
    assert r["fresh_after_fail"]["steps"] == [
             ["ramp", "ok", false, false],
             ["ramp", "fail", false, false],
             ["refine", "ok", true, true],
             ["refine", "ok", true, true],
             ["confirm", "ok", true, true]
           ]

    assert r["fresh_after_fail"]["resets"] == ["reset", "info", "reset", "info", "reset", "info"]

    assert r["fresh_never_failed"]["steps"] == [
             ["ramp", "ok", false, false],
             ["ramp", "ok", false, false],
             ["confirm", "ok", false, false]
           ]

    assert r["fresh_never_failed"]["resets"] == []

    # --no-confirm (the exploration round): no confirmation repeat, so no reset after the failing step
    assert r["no_confirm"]["steps"] == [["ramp", "ok", false, false], ["ramp", "fail", false, false]]
    assert r["no_confirm"]["resets"] == []

    # steps.reset_each_step: the lab is reset before every step, the first and the confirmation included
    assert r["reset_each_step"]["steps"] == [
             ["ramp", "ok", true, true],
             ["ramp", "ok", true, true],
             ["confirm", "ok", true, true]
           ]

    assert r["reset_each_step"]["resets"] == ["reset", "info", "reset", "info", "reset", "info"]

    # the bucket as listed over two pages: objects, bytes, counts by prefix and the garbage (multipart uploads never completed)
    b = r["bucket"]
    assert b["usage"]["objects"] == 4 and b["usage"]["bytes"] == 1_048_876 and b["usage"]["truncated"] == false

    assert b["usage"]["groups"] == %{
             "atanor/alarms" => %{"objects" => 1, "bytes" => 0},
             "atanor/cells" => %{"objects" => 2, "bytes" => 300},
             "atanor/packages" => %{"objects" => 1, "bytes" => 1_048_576}
           }

    assert b["usage"]["garbage"] == %{"incomplete_uploads" => 2, "total" => 2}
    assert b["clean_garbage"] == %{"incomplete_uploads" => 0, "total" => 0}

    assert Enum.take(b["queries"], 3) == [
             "list-type=2&max-keys=1000",
             "list-type=2&max-keys=1000&continuation-token=a%2Fb%3D",
             "uploads"
           ]

    assert b["broken"] == :null and b["not_xml"] == :null
    assert b["noted"]["store"]["bucket"]["objects"] == 4 and b["noted"]["store"]["bucket"]["start_bytes"] == 1_048_876
    assert b["noted"]["store"]["garbage"]["total"] == 2
    assert b["noted"]["notes"] == ["store garbage: 2 incomplete multipart uploads in the bucket"]
    assert b["unread"] == %{"store" => %{}, "notes" => []}
    assert b["rows"] == [[1, "10", "4 / 4", "1.0 / 1.0", "**2 GARBAGE**"]] and b["no_rows"] == []

    # the report: the lazy restores of each step with the latency tail, "none" in a step without, a line when no step had any, nothing from an older node
    assert r["lazy_report"]["some"] == [
             "Lazy restores of each step (misses: pages a query waited for):",
             "",
             "- step 1 (100): none; p99 40.0 ms, max 900.0 ms",
             "- step 2 (200): 2 ok, 1 error, 60 pages, 6 misses, restore 330 ms in total, 200 ms the longest; p99 40.0 ms, max 900.0 ms",
             ""
           ]

    assert [line] = Enum.take(r["lazy_report"]["none"], 1)
    assert line =~ "No lazy restores in any step" and line =~ "min_bytes"
    assert r["lazy_report"]["older_node"] == []

    assert r["runtime_garbage"]["record"]["runtime"] == :null
    assert r["runtime_garbage"]["record"]["status"] == "ok"

    for {name, reason} <- [
          {"oom", "node OOM-killed"},
          {"exit_generator", "node exited 137"},
          {"restarted", "node restarted"},
          {"gone", "node container gone"}
        ] do
      record = r[name]["record"]
      assert record["status"] == "fail", name
      assert record["valid"], name
      assert record["stop_reason"] =~ reason, name

      # inspect state, the node log and the store log are kept next to the step file (the store's metrics do not answer in the test)
      assert length(record["diagnostics"]) == 3, name
      assert Enum.all?(record["diagnostics"], &(&1 in r[name]["files"])), name
    end

    assert File.read!(Path.join([dir, "oom", "A", "ws", "step-10.node.log"])) =~ "cannot allocate memory"
    assert File.read!(Path.join([dir, "oom", "A", "ws", "step-10.node-state.txt"])) =~ "\"OOMKilled\": true"

    # the store log is timestamped and loses the lines that name a secret
    store_log = File.read!(Path.join([dir, "oom", "A", "ws", "step-10.store.log"]))
    assert store_log =~ "2026-01-01T00:00:01Z volume growth"
    refute store_log =~ ~r/secret|token|abc123/i

    # a generator failure with a healthy node stays invalid
    assert r["generator_only"]["record"]["status"] == "invalid"
    assert r["generator_only"]["record"]["diagnostics"] == []

    # the node's death ends the round: first failure there, the last good value approved, no bisection or confirmation
    ramp = r["ramp"]
    assert ramp["summary"]["first_failure"] == 20
    assert ramp["summary"]["approved"] == 10
    assert ramp["summary"]["node_stopped"]
    assert ramp["summary"]["stopped_by"] =~ "node OOM-killed"
    assert ramp["generator_runs"] == 2
    assert length(ramp["files"]) == 2

    # a stall of the lab: a high generator lag, or one jump of the node's CPU throttling far above its usual growth; a saturated node is not one
    stall = r["judge_stall"]
    assert stall["lag"] =~ ~r/^stall: generator lag p99 242 ms > 50 ms$/
    assert stall["jump"] =~ ~r/^stall: node CPU throttling grew 6200 ms .* > 5000 ms and 5 x the median 500 ms$/
    assert stall["lag_at_limit"] == :null
    assert stall["saturated"] == :null
    assert stall["saturated_peak"] == :null
    assert stall["small_jump"] == :null
    assert stall["unknown"] == :null
    assert stall["single"] == :null
    assert stall["no_lag"] == :null
    assert stall["missing_key"] == :null

    # a stalled step is repeated once and keeps the first attempt; a repeat that stalls too is INVALID and ends the round
    once = r["stall_once"]
    assert once["runs"] == [10, 10, 20, 20]
    assert once["summary"]["invalid"] == :null
    assert once["first"]["status"] == "ok"
    assert once["first"]["first_attempt"]["status"] == "invalid"
    assert once["first"]["first_attempt"]["stop_reason"] =~ "stall: generator lag"
    assert once["first"]["first_attempt"]["generator"]["lag_p99_ms"] == 242.0
    assert Enum.any?(once["first"]["notes"], &(&1 =~ "repeated once"))

    twice = r["stall_twice"]
    assert twice["runs"] == [10, 10]
    assert length(twice["files"]) == 1
    assert twice["summary"]["invalid"] =~ "stall: generator lag p99 300 ms"
    assert twice["first"]["valid"] == false
    assert twice["first"]["first_attempt"]["stop_reason"] =~ "lag p99 242 ms"

    # lag from a saturated node (the generator released on time) is not a stall: the step fails by p99; late release is a stall
    saturated = r["lag_saturated"]
    assert %{"status" => "fail", "valid" => true, "stop_reason" => "p99 1900.1 ms > 250 ms"} = saturated
    assert saturated["generator"]["lag_p99_ms"] == 162.2
    assert saturated["generator"]["release_lag_p99_ms"] == 1.0

    assert %{"status" => "invalid", "valid" => false, "stop_reason" => "stall: generator lag p99 241.9 ms > 50 ms"} =
             r["lag_stalled"]

    assert %{"status" => "invalid", "stop_reason" => "stall: generator lag p99 162.2 ms > 50 ms"} =
             r["lag_old_generator"]

    assert r["lag_old_generator"]["generator"]["release_lag_p99_ms"] == :null

    # a burst of slow node-to-store requests in the log of a failing step is a store stall: INVALID, repeated once, the evidence in the step file
    once = r["store_stall_once"]
    assert once["runs"] == [10, 10]

    assert %{
             "status" => "fail",
             "valid" => true,
             "stop_reason" => "p99 " <> _,
             "store_stall" => %{"slow_requests" => 0}
           } =
             once["first"]

    first = once["first"]["first_attempt"]
    assert first["status"] == "invalid"

    assert first["stop_reason"] ==
             "stall: store stalled, 12 node-to-store requests took >= 1000 ms within 5 s (slowest 1061 ms)"

    assert %{"slow_requests" => 12, "window_requests" => 12, "stalled" => true, "max_ms" => 1061} = first["store_stall"]

    # a store that stalls again in the repeat stalls at this load every time: the step fails on the store, valid, and the round goes on
    twice = r["store_stall_twice"]
    assert twice["runs"] == [10, 10]
    assert twice["summary"]["invalid"] == :null
    assert twice["summary"]["first_failure"] == 10
    assert %{"status" => "fail", "valid" => true} = twice["first"]

    # the reason keeps the criterion that made the step fail, and the step file lists the criteria
    assert twice["first"]["stop_reason"] ==
             "store: stalled at this step twice (12 node-to-store requests took >= 1000 ms within 5 s (slowest 1061 ms)); failed on: p99 900.1 ms > 250 ms"

    assert twice["first"]["criteria"] == ["p99 900.1 ms > 250 ms"]
    assert twice["first"]["first_attempt"]["stop_reason"] =~ "store stalled"
    assert once["first"]["criteria"] == ["p99 900.1 ms > 250 ms"]

    assert twice["first"]["store_stall"]["stalled"]
    assert twice["first"]["first_attempt"]["stop_reason"] =~ "store stalled"

    # not a stall: slow requests spread over time, a few, under the limit, or the check off; the step fails on p99 as before and is not repeated
    for name <- ["store_slow_spread", "store_few_slow", "store_fast", "store_stall_off"] do
      kept = r[name]
      assert kept["runs"] == [10], name
      assert %{"status" => "fail", "stop_reason" => "p99 " <> _, "first_attempt" => :null} = kept["first"], name
    end

    assert %{"slow_requests" => 12, "window_requests" => 1, "stalled" => false} =
             r["store_slow_spread"]["first"]["store_stall"]

    assert %{"slow_requests" => 2, "window_requests" => 2, "stalled" => false} =
             r["store_few_slow"]["first"]["store_stall"]

    # the evidence is read on every attempt: a log without a slow request is "read, nothing slow" (slow_requests 0), null is only "off"
    assert %{"slow_requests" => 0, "max_ms" => 0, "window_requests" => 0, "stalled" => false} =
             r["store_fast"]["first"]["store_stall"]

    assert r["store_stall_off"]["first"]["store_stall"] == :null

    assert r["store_stall_pure"] == %{
             "off" => :null,
             "none" => %{
               "slow_requests" => 0,
               "max_ms" => 0,
               "window_requests" => 0,
               "window_s" => 5.0,
               "threshold_ms" => 1000.0,
               "min_requests" => 10,
               "stalled" => false
             },
             "judge_none" => :null,
             "judge_clean" => :null
           }

    # a step that passes carries the evidence and stays ok, even when the slow requests are a stall: only a failing step is judged on it
    slow = r["store_pass_slow"]
    assert slow["summary"]["invalid"] == :null
    assert %{"status" => "ok", "valid" => true, "stop_reason" => :null, "first_attempt" => :null} = slow["first"]

    assert %{"slow_requests" => 12, "window_requests" => 12, "stalled" => true, "max_ms" => 1061} =
             slow["first"]["store_stall"]

    assert %{"status" => "ok", "slow_requests" => 0} =
             Map.merge(r["store_pass_clean"]["first"], r["store_pass_clean"]["first"]["store_stall"])

    assert r["store_pass_off"]["first"]["store_stall"] == :null

    # 503s over 1% of the answers fail a step (a criterion, not INVALID); 0.5% and exactly 1% pass; the useful rate leaves the 503s out
    refused = r["refused"]

    assert %{"status" => "fail", "valid" => true, "stop_reason" => "refused 2.0% > 1%", "useful_rate" => 196.0} =
             refused["two_pct"]

    assert refused["two_pct_no_retry"]["status"] == "fail"
    assert refused["two_pct_no_retry"]["stop_reason"] =~ "refused 2.0% > 1%"
    assert %{"status" => "ok", "stop_reason" => :null, "useful_rate" => 199.0} = refused["half_pct"]
    assert %{"status" => "ok", "stop_reason" => :null, "useful_rate" => 198.0} = refused["one_pct"]

    # the swap keeps accepting 503 with Retry-After
    assert r["swap"]["refused"] == 30

    # a step that starts with a dead node is invalid, runs no generator and ends the round
    start = r["dead_at_start"]
    assert start["generator_runs"] == 0
    assert start["summary"]["invalid"] == "node not running at step start"
    assert start["summary"]["node_stopped"]
    assert start["summary"]["approved"] == nil or start["summary"]["approved"] == :null
    assert length(start["files"]) == 1
  end

  test "a round of a config file: the layout, the hash, --skip-done, the plan kinds, the timeouts", %{dir: dir} do
    {out, 0} = System.cmd("python3", ["-I", "test/scripts/load_run_check.py", dir], stderr_to_stdout: true)
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()
    step = fn n -> "A/http-native/step-#{n}.json" end

    # bisect: 10 and 20 pass, 40 fails, the refinement tries 30 (fails) and 25 (passes); the confirmation of the measured 25 is repetition 2.
    # Each file has the phase and the hash of the case; refine and confirm run on a fresh node.
    b = r["bisect"]
    assert b["runs"] == [10, 20, 40, 30, 25, 25]
    assert b["files"] == Enum.sort(Enum.map([10, 20, 40, 30, 25, "25-2"], step))
    assert b["summary"] == %{"good" => 25, "approved" => 25, "confirmed" => true, "first_failure" => 40}

    assert b["phases"][step.(10)] == ["ramp", "ok", "h1"]
    assert b["phases"][step.(40)] == ["ramp", "fail", "h1"]
    assert b["phases"][step.(30)] == ["refine", "fail", "h1"]
    assert b["phases"][step.("25-2")] == ["confirm", "ok", "h1"]
    assert b["fresh"] == [false, true, true, true]

    # ceiling: a ladder of 0.75, 1, 1.25 and 1.5 times 400, refined once and confirmed
    c = r["ceiling"]
    assert c["steps"] == "300,400,500,600"
    assert c["runs"] == [300, 400, 500, 450, 450]
    assert c["good"] == 450 and c["approved"] == 450
    assert step.("450-2") in c["files"] and step.(300) in c["files"]

    # --skip-done: a second run runs nothing and reaches the same verdict (the generator would now fail every step); a deleted
    # confirmation is the only step run again; an INVALID step runs again; a file of another config refuses; --no-skip-done runs all
    s = r["skip_done"]
    assert s["first"] == [10, 20, 40, 20] and s["again"] == []
    assert s["same_summary"] and s["approved"] == 20 and s["hash_in_file"] == "h1"
    assert s["third"] == [20] and s["invalid_reran"] == [40]
    assert s["refused"] =~ "step-10.json was made by another config (config_hash differs)" and s["refused_ran"] == []
    assert s["no_skip"] == [10, 20, 40, 20]
    assert s["files"] == Enum.sort(Enum.map([10, 20, 40, "20-2"], step))

    # the layout: the load and the node count are the variant of the scale measure; the join, the summary and the baseline have their place
    l = r["layout"]
    assert l["files"] == ["A/scale/http-native-n2/step-998-2.json", "A/scale/http-native-n2/step-998.json"]
    assert l["measure"] == "scale" and l["load"] == "http-native" and l["config_hash"] == "h1"
    assert l["join"] == "A/scale/join/step-600" and l["join_float"] == "A/scale/join/step-600"
    assert l["summary"] == "A/ws/summary.json" and l["baseline"] == "A/cells/baseline.json"

    # the swap takes the approved rate of http-wasm-jobs from the layout, and a done swap is not run again
    w = r["swap_nested"]
    assert w["first"] == "ok" and w["again"] == "ok" and w["approved"] == [10, 10]
    assert w["files"] == ["step-10.json"] and w["same_files"] and w["hash"] == "h1"

    # the round's timeout stops before the next step, and nothing was written
    assert r["deadline"] == ["round.timeout_s passed", false]

    # what the config says reaches the arguments; a criterion that is off gets a limit nothing reaches
    d = r["config_defaults"]
    assert d["p99_off"] and d["p99_on"] == 250.0 and d["delivery"] == 0.0 and d["judge_errors"] == false
    assert d["stall_ms"] == 0.0 and d["host_off"] and d["quiet_window"] == 0.0 and d["min_gb"] == 0.0
    assert d["timeout"] == 123.0 and d["no_warmup"] and d["repeats"] == 3 and d["steps"] == "300,400,500,600"
    assert d["hash"] == 64 and d["command"] == "mise run load -- --config c.toml"

    assert d["scale"] == [
             "http-native:1=600,http-native:2=840,cells:1=470,cells:2=750",
             "1,1.5",
             2,
             [490, 650, 810, 975],
             :null
           ]

    # [scale.judging.LOAD]: cells ramps with its own rules, http-native keeps the measure's
    assert r["scale_judging"] == %{
             "ramped" => %{"cells" => [900.0, false], "http-native" => [400.0, true]},
             "args" => [400.0, true]
           }

    assert r["stall_repeats"] == %{"two" => [10, 10, 10, 20, 20], "none" => [10]}

    # the criterion "5xx or error fails a step" is on by default and can be turned off
    assert r["errors"] == [["fail", "errors: 500 x1"], ["ok", :null]]

    # a generator that outlives step_timeout_s is killed by `timeout`: INVALID, and the CPU is read from the generator, not from `timeout`
    t = r["generator_timeout"]
    assert t["status"] == "invalid" and t["valid"] == false
    assert t["stop_reason"] == "timeout: a generator was killed after 1 s (round.step_timeout_s)"
    assert t["seconds"] <= 5 and t["child_pid_read"]
    assert r["generator_ok"]["status"] == "ok" and r["generator_ok"]["stop_reason"] == :null
  end

  test "mise run load: the plan, the lab per scenario, the refusals and the timeout of the round", %{dir: dir} do
    {out, 0} = System.cmd("python3", ["-I", "test/scripts/load_round_check.py", dir], stderr_to_stdout: true)
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

    # --dry-run prints the plan of the official round and starts and writes nothing
    d = r["dry_run"]
    assert d["status"] == 0 and d["hashes"] and d["calls"] == false and d["results_dir"] == false
    assert d["text"] =~ "13 cases, results in REPO/load/results/018f"
    assert d["text"] =~ "each generator process is killed after 600 s (round.step_timeout_s); no round timeout"

    assert d["text"] =~
             "A/http-native      ladder, values 490, 650, 810, 975 req/s; at most 8 steps (3 refine, 1 confirm), 180 s each"

    assert d["text"] =~ "A/http-wasm        bisect, values 25, 50, 100,"
    assert d["text"] =~ "B/ws               ladder, values 15000, 20000, 25000, 30000 connections"
    assert d["text"] =~ "A/scale            scale"
    assert d["text"] =~ "output A/scale/"

    # an invalid config lists every problem and starts nothing
    i = r["invalid"]
    assert i["status"] == 2 and i["calls"] == [] and i["out_made"] == false
    assert i["stderr"] =~ "judging.p99.max_ms: -1 is out of range"
    assert i["stderr"] =~ "nope: unknown key"
    assert i["stderr"] =~ "round.step_timeout_s: 10 s is below 210 s"

    # the lab is started per scenario, each later measure runs on a fresh lab, and the report follows its scenario
    t = r["two"]
    assert t["status"] == 0 and t["config_toml"]

    assert t["calls"] == [
             "mise run load:up",
             "load-run http-native --config OUT/config.toml --scenario A --skip-done",
             "env A http-native",
             "load-env reset",
             "load-run swap --config OUT/config.toml --scenario A --skip-done",
             "env A swap",
             "load-report OUT",
             "mise run load:down",
             "mise run load:up",
             "load-run http-native --config OUT/config.toml --scenario B --skip-done",
             "env B http-native",
             "load-env reset",
             "load-run swap --config OUT/config.toml --scenario B --skip-done",
             "env B swap",
             "load-report OUT",
             "mise run load:down"
           ]

    # a measure with its own store gets its own lab; the next one goes back to the scenario's
    assert r["own_lab"]["calls"] == [
             "mise run load:up",
             "mise run load:down",
             "mise run load:up",
             "mise run load:down",
             "mise run load:up",
             "load-report OUT",
             "mise run load:down"
           ]

    # the scale measure starts its own nodes: no reset before it
    assert r["scale"]["calls"] == ["mise run load:up", "load-env reset", "load-report OUT", "mise run load:down"]

    # INVALID (exit 1) does not stop the other measures but makes the round's status 1; exit 3 (the round's timeout) stops it
    assert r["exits"]["invalid"] == [1, 2]
    assert r["exits"]["stopped"] == [1, 1, true, ["load-report OUT", "mise run load:down"]]

    # --skip-done: a step file of another config refuses the round before any container; the same config runs; --no-skip-done overwrites
    h = r["hash"]
    assert [status, calls, stderr] = h["refused"]
    assert status == 2 and calls == []
    assert stderr =~ "1 step files in OUT were made by another config"
    assert stderr =~ "A/http-native/step-10.json"
    assert h["forced"] == [0, ["A --no-skip-done"]]
    assert h["same_hash_runs"] == [0, 1] and h["skip_flag"]

    # the timeout of the round: the case that passes it ends, the next one does not start, the lab is removed
    s = r["round_timeout"]
    assert s["status"] == 1 and s["runs"] == 1 and s["deadline_passed"] and s["stdout"]
    assert s["calls"] == ["mise run load:up", "load-report OUT", "mise run load:down"]

    # a lab that does not start ends the round, and the lab is removed
    assert r["lab_fails"] == %{"status" => 1, "runs" => 0, "calls" => ["mise run load:up", "mise run load:down"]}

    # a case whose steps and summary are all done (same hash, none INVALID) is reused without a lab; an INVALID step or --no-skip-done runs it
    d = r["done_case"]
    assert d["all_done"] == [0, ["load-report OUT"], 0, true]
    assert d["some_done"] == [0, ["mise run load:up", "load-report OUT", "mise run load:down"], ["cells"]]
    assert d["invalid_step"] == [["mise run load:up", "load-report OUT", "mise run load:down"], 1]
    assert d["no_skip_done"] == [["mise run load:up", "load-report OUT", "mise run load:down"], 1]
  end

  test "mise run load --remote, --status and --fetch with a stubbed ssh, scp and rsync", %{dir: dir} do
    {out, 0} = System.cmd("python3", ["-I", "test/scripts/load_round_check.py", dir], stderr_to_stdout: true)
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()
    head = r["remote"]["head"]

    # the checks run on the host first; the round starts there only when the clone is clean and at the local commit
    s = r["remote"]["start"]
    assert s["status"] == 0
    [check, start] = s["calls"]

    assert check =~
             ~r"^ssh lab :: cd /srv/atanor && git fetch --quiet && git status --porcelain && echo HEAD=\$\(git rev-parse HEAD\) && \(test -f OUT.toml && echo CONFIG=ok"

    assert check =~ "kill -0 $(cat /srv/results/r1/round.pid)"

    assert start =~
             ~r"^ssh lab :: mkdir -p /srv/results/r1 && cd /srv/atanor && setsid nohup sh -c 'echo \$\$ > /srv/results/r1/round.pid; exec timeout --kill-after=60 3600 mise run load -- --config OUT.toml --out /srv/results/r1 --skip-done' > /srv/results/r1/round.log 2>&1 < /dev/null &"

    assert s["stdout"] =~ "local commit  #{head}" and s["stdout"] =~ "remote commit #{head}"
    assert s["stdout"] =~ "--status" and s["stdout"] =~ "--fetch" and s["stdout"] =~ "host.timeout_s"

    # a clone with local changes, at another commit, with a round running, or without the config is refused: one ssh call, nothing started
    dirty = r["remote"]["dirty"]
    assert dirty["status"] == 2 and dirty["calls"] == 1

    assert dirty["stderr"] =~ "has local changes" and dirty["stderr"] =~ "M lib/a.ex" and
             dirty["stderr"] =~ "?? scratch"

    behind = r["remote"]["behind"]
    assert behind["status"] == 2 and behind["calls"] == 1
    assert behind["stdout"] =~ "local commit  #{head}" and behind["stdout"] =~ "remote commit 0123456789abcdef"
    assert behind["stderr"] =~ "not at the local commit"

    assert [2, 1, busy] = r["remote"]["busy"]
    assert busy =~ "a round is already running"
    assert [2, 1, absent] = r["remote"]["absent"]
    assert absent =~ "is not in the clone"
    assert [2, 0, nohost] = r["remote"]["nohost"]
    assert nohost =~ "host.ssh and host.repo must be set"

    # nothing remote happens without one of the flags: a round with host.ssh set runs here
    l = r["remote"]["local_round"]
    assert l["status"] == 0 and l["network"] == [] and l["note"] and l["runs"] == 1

    # --status: alive or not, the end of the log, without the lines that name a secret
    st = r["status"]
    assert st["status"] == 0 and length(st["calls"]) == 1

    assert st["stdout"] =~ "round: running (pid 4242)" and st["stdout"] =~ "measure A/ws step 20" and
             st["stdout"] =~ "last line"

    refute st["stdout"] =~ ~r/secret|token|key|password/i

    # --fetch: rsync of the results directory into the output dir, scp -r without rsync
    f = r["fetch"]
    assert f["rsync"] == [0, ["rsync -a lab:/srv/results/r1/ OUT/"]]
    assert f["scp"] == [0, ["scp -r lab:/srv/results/r1/. OUT/"]]
    assert f["made"]
  end

  test "the old entries are gone: one task runs a round, and load-run takes its settings from the config only" do
    tasks = File.read!("mise.toml")

    for name <- ~w(http-native http-wasm http-wasm-jobs ws cells swap scale explore) do
      refute tasks =~ ~s([tasks."load:#{name}"]), name
    end

    for name <- ["load", ~s("load:up"), ~s("load:down"), ~s("load:report"), ~s("load:config-check")] do
      assert tasks =~ "[tasks.#{name}]", name
    end

    refute File.exists?("scripts/load-explore")
    refute File.exists?("test/scripts/load_explore_test.exs")

    # the only ATANOR_LOAD_* left in load-run are the plumbing that scripts/load and load-env read
    source = File.read!("scripts/load-run")
    assert Regex.scan(~r/ATANOR_LOAD_(?!CONFIG|SCENARIO|MEASURE|NODES|HTTP_MAX_CONNECTIONS)\w+/, source) == []

    {out, 0} = System.cmd("python3", ["-I", "scripts/load-run", "--help"], stderr_to_stdout: true)
    assert out =~ "--config" and out =~ "--skip-done"
    refute out =~ "--step-s" or out =~ "--p99-ms"
  end

  test "mise run load refuses a missing config and prints --help", %{dir: dir} do
    {out, status} =
      System.cmd("python3", ["-I", "scripts/load", "--config", Path.join(dir, "absent.toml"), "--dry-run"],
        stderr_to_stdout: true
      )

    assert status == 2
    assert out =~ "cannot read the file: No such file or directory"

    {out, 0} = System.cmd("python3", ["-I", "scripts/load", "--help"], stderr_to_stdout: true)
    assert out =~ "--skip-done" and out =~ "--dry-run" and out =~ "step-VALUE[-REPETITION].json"
  end

  test "load-env takes the lab's settings from the round config for a scenario and a measure", %{dir: dir} do
    File.write!(
      Path.join(dir, "round.toml"),
      "[store]\nlatency_ms = 7\n[measures.ws.store]\nbacking = \"disk\"\n[node]\nhttp_max_connections = 99999\nerl_flags = \"+SDio 2 +S 1:1\"\n[node.compaction]\nhold_bytes = 67108864\n[node.lazy_restore]\nmin_bytes = 0\n[node.store]\npool_size = 512\n[scenarios.B]\nnodes = 2\n"
    )

    env = fn scenario, measure ->
      script =
        "source scripts/load-common; echo \"$LOAD_SCENARIO $LOAD_CPUS $LOAD_MEMORY $LOAD_STORE_LATENCY_MS $LOAD_STORE_DISK $LOAD_NODES $ATANOR_CLUSTER_HTTP_MAX_CONNECTIONS [$ATANOR_CLUSTER_COMPACTION_HOLD_BYTES|$ATANOR_CLUSTER_COMPACTION_CONCURRENCY|$ATANOR_CLUSTER_S3_POOL_SIZE] <$ATANOR_CLUSTER_ERL_ZFLAGS> {$ATANOR_CLUSTER_LAZY_RESTORE_MIN_BYTES}\""

      {out, 0} =
        System.cmd("bash", ["-c", script],
          env: [
            {"ATANOR_LOAD_CONFIG", Path.join(dir, "round.toml")},
            {"ATANOR_LOAD_SCENARIO", scenario},
            {"ATANOR_LOAD_MEASURE", measure},
            {"ATANOR_LOAD_CPUS", "9"},
            {"ATANOR_LOAD_NODES", nil}
          ],
          stderr_to_stdout: true
        )

      String.trim(out)
    end

    # the config replaces the ATANOR_LOAD_* it names (ATANOR_LOAD_CPUS=9 here); the store of a measure follows its override
    # the compaction and the pool options reach the cluster's variables (empty when not set)
    # erl_flags becomes ERL_ZFLAGS of the node (ATANOR_CLUSTER_ERL_ZFLAGS), lazy_restore.min_bytes its lazy restore threshold (0 is a value)
    assert env.("A", "http-native") == "A 1 512m 7 0 1 99999 [67108864||512] <+SDio 2 +S 1:1> {0}"
    assert env.("A", "ws") == "A 1 512m 7 1 1 99999 [67108864||512] <+SDio 2 +S 1:1> {0}"
    assert env.("B", "cells") == "B 2 2g 7 0 2 99999 [67108864||512] <+SDio 2 +S 1:1> {0}"
  end

  test "a stall of the harness's own ticker next to an open breaker marks a stop of the whole VM", %{dir: dir} do
    {out, 0} = System.cmd("python3", ["-I", "test/scripts/load_run_check.py", dir], stderr_to_stdout: true)
    r = out |> String.split("\n", trim: true) |> List.last() |> :json.decode()

    together = r["stalls_together"]
    assert together["vm_pause_suspected"] == true
    assert together["breaker_open_at_s"] == [10.0]
    assert together["ticker_stalls"] == [%{"t" => 7.0, "overshoot_s" => 5.5}]

    # a stall long before the breaker opened, or an open breaker with no stall, is a fault of the node or the store
    assert r["stalls_apart"]["vm_pause_suspected"] == false

    assert r["stalls_no_breaker"] == %{
             "ticker_stalls" => [%{"t" => 3.0, "overshoot_s" => 5.5}],
             "breaker_open_at_s" => [],
             "vm_pause_suspected" => false
           }

    assert r["stalls_none"] == :null

    # the ticker records the sleep that overshot, not the one that did not
    assert r["ticker"] == [1.5]
  end

  describe "load-env rtt" do
    setup %{dir: dir} do
      File.write!(Path.join(dir, "round.toml"), "")
      docker = Path.join(dir, "docker")

      File.write!(docker, """
      #!/bin/sh
      case "$1" in
        ps) echo abc123 ;;
        exec) exit 1 ;;
      esac
      """)

      File.chmod!(docker, 0o755)
      {:ok, path: dir <> ":" <> System.get_env("PATH")}
    end

    test "prints nothing and succeeds when the curl in the node fails", %{dir: dir, path: path} do
      {out, status} =
        System.cmd(Path.expand("scripts/load-env"), ["rtt"],
          env: [{"PATH", path}, {"ATANOR_LOAD_CONFIG", Path.join(dir, "round.toml")}],
          stderr_to_stdout: true
        )

      assert status == 0, out
      assert String.trim(out) == ""
    end

    test "prints nothing and succeeds when there is no node", %{dir: dir} do
      File.write!(Path.join(dir, "docker"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(dir, "docker"), 0o755)

      {out, status} =
        System.cmd(Path.expand("scripts/load-env"), ["rtt"],
          env: [{"PATH", dir <> ":" <> System.get_env("PATH")}, {"ATANOR_LOAD_CONFIG", Path.join(dir, "round.toml")}],
          stderr_to_stdout: true
        )

      assert status == 0, out
      assert String.trim(out) == ""
    end
  end

  describe "load-common memory limits" do
    # `toml` is a round config; the scenario is the internal ATANOR_LOAD_SCENARIO.
    defp limits(dir, toml, scenario) do
      File.write!(Path.join(dir, "limits.toml"), toml)

      script =
        ~s(source scripts/load-common; echo "$ATANOR_CLUSTER_NODE_MEMORY $ATANOR_CLUSTER_STORE_MEMORY $LOAD_MEMORY_BYTES $ATANOR_CLUSTER_MEMORY_LIMIT")

      env = [{"ATANOR_LOAD_CONFIG", Path.join(dir, "limits.toml")}, {"ATANOR_LOAD_SCENARIO", scenario}]
      {out, status} = System.cmd("bash", ["-c", script], env: env, stderr_to_stdout: true)
      {String.split(String.trim(out)), status}
    end

    test "the container limit is the scenario memory plus the tmpfs, for the node and the store", %{dir: dir} do
      mib = 1_048_576
      node_a = (512 + 256) * mib
      store = (2048 + 1024) * mib
      assert {[node, st, scenario, node_limit], 0} = limits(dir, "[store]\nbacking = \"tmpfs\"\n", "A")
      assert {node, st, scenario} == {"#{node_a}", "#{store}", "#{512 * mib}"}
      # a store that is not in tmpfs has no tmpfs to add
      assert {[_, st, _, _], 0} = limits(dir, "", "A")
      assert st == "#{2048 * mib}"
      # the node's own limit is the scenario memory, not the container limit with the tmpfs
      assert node_limit == "#{512 * mib}"

      assert {[node, _, scenario, _], 0} = limits(dir, "[scenarios.B]\ndata_tmpfs = \"768m\"\n", "B")
      assert {node, scenario} == {"#{(2048 + 768) * mib}", "#{2048 * mib}"}

      # scenario B's data dir is 1 GB by default (A's is 256 MB), so its disk budget does not put cells to sleep before the memory does
      assert {[node, _, scenario, node_limit], 0} = limits(dir, "", "B")
      assert {node, scenario, node_limit} == {"#{(2048 + 1024) * mib}", "#{2048 * mib}", "#{2048 * mib}"}
    end

    test "every compose call of load-env (add-node starts nodes 2 and 3) uses the tmpfs layout of node 1", %{dir: dir} do
      script = ~s(source scripts/load-common; printf '%s\\n' "${compose_files[@]}")
      File.write!(Path.join(dir, "tmpfs.toml"), "")

      {out, 0} =
        System.cmd("bash", ["-c", script],
          env: [{"ATANOR_CLUSTER_TMPFS", ""}, {"ATANOR_LOAD_CONFIG", Path.join(dir, "tmpfs.toml")}]
        )

      assert out =~ "cluster/compose.tmpfs.yml"

      File.write!(Path.join(dir, "disk.toml"), "[store]\nbacking = \"disk\"\n")
      {out, 0} = System.cmd("bash", ["-c", script], env: [{"ATANOR_LOAD_CONFIG", Path.join(dir, "disk.toml")}])
      assert out =~ "cluster/compose.tmpfs.yml" and out =~ "cluster/compose.store-disk.yml"
    end

    test "a size that is not a size is refused by the config", %{dir: dir} do
      assert {parts, 1} = limits(dir, "[scenarios.A]\ndata_tmpfs = \"lots\"\n", "A")
      assert Enum.join(parts, " ") =~ "scenarios.A.data_tmpfs: 'lots' is not a size"
    end

    test "without a round config the lab's scripts refuse to start" do
      script = ~s(source scripts/load-common)
      {out, status} = System.cmd("bash", ["-c", script], env: [{"ATANOR_LOAD_CONFIG", nil}], stderr_to_stdout: true)
      assert status == 1
      assert out =~ "ATANOR_LOAD_CONFIG must name the round config"
    end

    test "the settings of the environment do not change the lab: only the config does", %{dir: dir} do
      File.write!(Path.join(dir, "env.toml"), "")
      script = ~s(source scripts/load-common; echo "$LOAD_CPUS $LOAD_STORE_DISK")

      {out, 0} =
        System.cmd("bash", ["-c", script],
          env: [
            {"ATANOR_LOAD_CONFIG", Path.join(dir, "env.toml")},
            {"ATANOR_LOAD_CPUS", "9"},
            {"ATANOR_LOAD_STORE_DISK", "1"}
          ]
        )

      assert String.trim(out) == "1 0"
    end
  end

  describe "cluster-swap-run run()" do
    # main() is not run (the module is not `__main__`), and run() is called
    # directly with a `docker` stub that fails (the full run needs a cluster).
    test "a failing command surfaces its stderr and stdout", %{dir: dir} do
      File.write!(Path.join(dir, "docker"), "#!/bin/sh\necho 'out line'\necho 'no such service: node-9' >&2\nexit 1\n")
      File.chmod!(Path.join(dir, "docker"), 0o755)

      script = """
      g = {"__file__": "scripts/cluster-swap-run", "__name__": "cluster_swap_run"}
      exec(compile(open("scripts/cluster-swap-run").read(), "cluster-swap-run", "exec"), g)
      g["run"]("docker", "compose", "up", "-d", "--no-deps", "node-9")
      """

      {out, status} =
        System.cmd("python3", ["-I", "-c", script],
          env: [{"PATH", dir <> ":" <> System.get_env("PATH")}],
          stderr_to_stdout: true
        )

      assert status == 1
      assert out =~ "docker compose up -d --no-deps node-9 exited 1"
      assert out =~ "no such service: node-9"
      assert out =~ "out line"
    end

    # B that exited ends the run at once with its status and last log lines, not after the timeout.
    test "a node B that exited stops the run with its exit code and logs", %{dir: dir} do
      File.write!(Path.join(dir, "docker"), """
      #!/bin/sh
      case "$1" in
        inspect) echo "exited 127 " ;;
        logs) echo "exec: /opt/atanor/bin/atanor: not found" ;;
      esac
      """)

      File.chmod!(Path.join(dir, "docker"), 0o755)
      {out, status, seconds} = wait_for_b(dir, 60)

      assert status == 127
      assert out =~ "atanor-cluster-node-2 is exited with status 127"
      assert out =~ "exec: /opt/atanor/bin/atanor: not found"
      assert seconds < 10
    end

    test "a node B that turns unhealthy stops the run", %{dir: dir} do
      File.write!(Path.join(dir, "docker"), """
      #!/bin/sh
      case "$1" in
        inspect) echo "running 0 unhealthy" ;;
        logs) echo "boot failed" ;;
      esac
      """)

      File.chmod!(Path.join(dir, "docker"), 0o755)
      {out, status, seconds} = wait_for_b(dir, 60)

      assert status == 1
      assert out =~ "atanor-cluster-node-2 is unhealthy"
      assert out =~ "boot failed"
      assert seconds < 10
    end

    defp wait_for_b(dir, timeout) do
      script = """
      g = {"__file__": "scripts/cluster-swap-run", "__name__": "cluster_swap_run"}
      exec(compile(open("scripts/cluster-swap-run").read(), "cluster-swap-run", "exec"), g)
      g["wait_for_b"]("b", "atanor-cluster-node-2", #{timeout})
      """

      started = System.monotonic_time(:second)

      {out, status} =
        System.cmd("python3", ["-I", "-c", script],
          env: [{"PATH", dir <> ":" <> System.get_env("PATH")}],
          stderr_to_stdout: true
        )

      {out, status, System.monotonic_time(:second) - started}
    end
  end

  describe "the measurements of load-env" do
    setup %{dir: dir} do
      scripts = Path.join(dir, "scripts")
      File.mkdir_p!(scripts)

      for name <- ~w(load-env load-common cluster-common load_config.py),
          do: File.cp!("scripts/" <> name, Path.join(scripts, name))

      File.write!(Path.join(dir, "round.toml"), "[store]\ncpus = 1\n[balancer]\ncpus = 0.5\n")
      {:ok, scripts: scripts, config: Path.join(dir, "round.toml")}
    end

    test "limits prints the CPU limits of a node, the store and the balancer, from --config and --scenario", %{
      scripts: scripts,
      config: config
    } do
      {out, 0} = System.cmd(Path.join(scripts, "load-env"), ["limits", "--config", config, "--scenario", "B"])
      assert :json.decode(out) == %{"node_cpus" => 2, "store_cpus" => 1, "lb_cpus" => 0.5}

      {out, 0} =
        System.cmd(Path.join(scripts, "load-env"), ["--scenario", "A", "limits"], env: [{"ATANOR_LOAD_CONFIG", config}])

      assert :json.decode(out)["node_cpus"] == 1
    end

    test "the store round trip is the second request of one curl run, on the reused connection", %{
      dir: dir,
      scripts: scripts,
      config: config
    } do
      # a stub docker: `ps` finds a node; `exec ... curl URL URL` answers the connect-heavy first time, then the reused one
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)

      File.write!(Path.join(bin, "docker"), """
      #!/bin/sh
      case "$1" in
        ps) echo node1 ;;
        exec) n=0; for a in "$@"; do case $a in http://*) n=$((n+1)) ;; esac; done
              if [ $n -ge 2 ]; then printf '0.080\\n0.030\\n'; else printf '0.080\\n'; fi ;;
      esac
      """)

      File.chmod!(Path.join(bin, "docker"), 0o755)

      {out, 0} =
        System.cmd(Path.join(scripts, "load-env"), ["rtt"],
          env: [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"ATANOR_LOAD_CONFIG", config}]
        )

      assert String.trim(out) == "30.0"
    end
  end

  describe "the image of the load environment" do
    # load-env swap runs cluster-swap-run, so node B starts from the image of the load environment; the
    # cluster scripts alone keep the cluster image. A copy of the scripts has a stub cluster-swap-run.
    test "load-env swap passes the load image to cluster-swap-run; cluster-common leaves it unset", %{dir: dir} do
      scripts = Path.join(dir, "scripts")
      File.mkdir_p!(scripts)

      for name <- ~w(load-env load-common cluster-common load_config.py),
          do: File.cp!("scripts/" <> name, Path.join(scripts, name))

      File.write!(Path.join(scripts, "cluster-swap-run"), "#!/bin/sh\necho \"image=$ATANOR_CLUSTER_IMAGE args=$*\"\n")
      File.chmod!(Path.join(scripts, "cluster-swap-run"), 0o755)
      File.write!(Path.join(dir, "round.toml"), "")

      {out, 0} =
        System.cmd(Path.join(scripts, "load-env"), ["swap", "--rate", "10"],
          env: [{"ATANOR_CLUSTER_IMAGE", ""}, {"ATANOR_LOAD_CONFIG", Path.join(dir, "round.toml")}]
        )

      assert String.trim(out) == "image=atanor-cluster-load:local args=--rate 10"

      {out, 0} =
        System.cmd("bash", ["-c", "source scripts/cluster-common; echo \"[${ATANOR_CLUSTER_IMAGE:-unset}]\""],
          env: [{"ATANOR_CLUSTER_IMAGE", nil}]
        )

      assert String.trim(out) == "[unset]"
    end
  end
end
