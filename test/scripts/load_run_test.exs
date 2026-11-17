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
             ~w(wake_gate awake_limit busy disk_full queue_timeout worker_queue nested_calls)

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
    assert r["refusals"]["no_runtime"]["refusals"] == :null
    assert "10 503 answers not attributed: no /runtime reading" in r["refusals"]["no_runtime"]["notes"]
    assert r["refusals"]["all_counted"]["refusals"]["unattributed"] == 0
    refute Enum.any?(r["refusals"]["all_counted"]["notes"], &(&1 =~ "not attributed"))

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

    assert File.read!(Path.join([dir, "oom", "A_ws_01-ramp-10.node.log"])) =~ "cannot allocate memory"
    assert File.read!(Path.join([dir, "oom", "A_ws_01-ramp-10.node-state.txt"])) =~ "\"OOMKilled\": true"

    # the store log is timestamped and loses the lines that name a secret
    store_log = File.read!(Path.join([dir, "oom", "A_ws_01-ramp-10.store.log"]))
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

    test "prints nothing and succeeds when the curl in the node fails", %{path: path} do
      {out, status} =
        System.cmd(Path.expand("scripts/load-env"), ["rtt"], env: [{"PATH", path}], stderr_to_stdout: true)

      assert status == 0, out
      assert String.trim(out) == ""
    end

    test "prints nothing and succeeds when there is no node", %{dir: dir} do
      File.write!(Path.join(dir, "docker"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(dir, "docker"), 0o755)

      {out, status} =
        System.cmd(Path.expand("scripts/load-env"), ["rtt"],
          env: [{"PATH", dir <> ":" <> System.get_env("PATH")}],
          stderr_to_stdout: true
        )

      assert status == 0, out
      assert String.trim(out) == ""
    end
  end

  describe "load-common memory limits" do
    defp limits(env) do
      script =
        ~s(source scripts/load-common; echo "$ATANOR_CLUSTER_NODE_MEMORY $ATANOR_CLUSTER_STORE_MEMORY $LOAD_MEMORY_BYTES $ATANOR_CLUSTER_MEMORY_LIMIT")

      {out, status} = System.cmd("bash", ["-c", script], env: env, stderr_to_stdout: true)
      {String.split(String.trim(out)), status}
    end

    test "the container limit is the scenario memory plus the tmpfs, for the node and the store" do
      mib = 1_048_576
      node_a = (512 + 256) * mib
      store = (2048 + 1024) * mib
      assert {[node, st, scenario, node_limit], 0} = limits([{"ATANOR_LOAD_SCENARIO", "A"}])
      assert {node, st, scenario} == {"#{node_a}", "#{store}", "#{512 * mib}"}
      # the node's own limit is the scenario memory, not the container limit with the tmpfs
      assert node_limit == "#{512 * mib}"

      assert {[node, _, scenario, _], 0} = limits([{"ATANOR_LOAD_SCENARIO", "B"}, {"ATANOR_LOAD_TMPFS_SIZE", "768m"}])
      assert {node, scenario} == {"#{(2048 + 768) * mib}", "#{2048 * mib}"}
    end

    test "a size that is not a size is refused" do
      assert {parts, 1} = limits([{"ATANOR_LOAD_TMPFS_SIZE", "lots"}])
      assert Enum.join(parts, " ") =~ "must be sizes"
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
      for name <- ~w(load-env load-common cluster-common), do: File.cp!("scripts/" <> name, Path.join(scripts, name))
      {:ok, scripts: scripts}
    end

    test "limits prints the CPU limits of a node, the store and the balancer", %{scripts: scripts} do
      {out, 0} =
        System.cmd(Path.join(scripts, "load-env"), ["limits"],
          env: [{"ATANOR_LOAD_SCENARIO", "B"}, {"ATANOR_LOAD_STORE_CPUS", "1"}, {"ATANOR_LOAD_LB_CPUS", "0.5"}]
        )

      assert :json.decode(out) == %{"node_cpus" => 2, "store_cpus" => 1, "lb_cpus" => 0.5}
    end

    test "the store round trip is the second request of one curl run, on the reused connection", %{
      dir: dir,
      scripts: scripts
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
        System.cmd(Path.join(scripts, "load-env"), ["rtt"], env: [{"PATH", bin <> ":" <> System.get_env("PATH")}])

      assert String.trim(out) == "30.0"
    end
  end

  describe "the image of the load environment" do
    # load-env swap runs cluster-swap-run, so node B starts from the image of the load environment; the
    # cluster scripts alone keep the cluster image. A copy of the scripts has a stub cluster-swap-run.
    test "load-env swap passes the load image to cluster-swap-run; cluster-common leaves it unset", %{dir: dir} do
      scripts = Path.join(dir, "scripts")
      File.mkdir_p!(scripts)
      for name <- ~w(load-env load-common cluster-common), do: File.cp!("scripts/" <> name, Path.join(scripts, name))
      File.write!(Path.join(scripts, "cluster-swap-run"), "#!/bin/sh\necho \"image=$ATANOR_CLUSTER_IMAGE args=$*\"\n")
      File.chmod!(Path.join(scripts, "cluster-swap-run"), 0o755)

      {out, 0} =
        System.cmd(Path.join(scripts, "load-env"), ["swap", "--rate", "10"], env: [{"ATANOR_CLUSTER_IMAGE", ""}])

      assert String.trim(out) == "image=atanor-cluster-load:local args=--rate 10"

      {out, 0} =
        System.cmd("bash", ["-c", "source scripts/cluster-common; echo \"[${ATANOR_CLUSTER_IMAGE:-unset}]\""],
          env: [{"ATANOR_CLUSTER_IMAGE", nil}]
        )

      assert String.trim(out) == "[unset]"
    end
  end
end
