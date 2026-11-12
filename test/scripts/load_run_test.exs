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
end
