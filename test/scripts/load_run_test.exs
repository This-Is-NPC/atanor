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

    assert record["admission"]["refuse_at_bytes"] == 400 * 1_048_576
    assert record["admission"]["refusing_seen"] == true

    assert record["admission"]["refused"] == %{
             "memory" => 10 * (n - 1),
             "in_flight" => n - 1,
             "disk" => 0,
             "queue_timeout" => 0
           }

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
             "limit_mb" => 512.0
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
      # inspect state and log tail are kept next to the step file
      assert length(record["diagnostics"]) == 2, name
      assert Enum.all?(record["diagnostics"], &(&1 in r[name]["files"])), name
    end

    assert File.read!(Path.join([dir, "oom", "A_ws_01-ramp-10.node.log"])) =~ "cannot allocate memory"
    assert File.read!(Path.join([dir, "oom", "A_ws_01-ramp-10.node-state.txt"])) =~ "\"OOMKilled\": true"

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

    # a step that starts with a dead node is invalid, runs no generator and ends the round
    start = r["dead_at_start"]
    assert start["generator_runs"] == 0
    assert start["summary"]["invalid"] == "node not running at step start"
    assert start["summary"]["node_stopped"]
    assert start["summary"]["approved"] == nil or start["summary"]["approved"] == :null
    assert length(start["files"]) == 1
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
