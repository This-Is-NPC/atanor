defmodule Atanor.Scripts.CheckLogTest do
  @moduledoc "scripts/check-log: the full output of the gate is kept, and a red run ends with the failing tests and the log path."
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check-log", __DIR__)

  @tag :tmp_dir
  test "a failing command keeps its full output and the tail names the failure, the seed and the log", %{tmp_dir: dir} do
    fake = Path.join(dir, "fake")

    File.write!(fake, """
    #!/usr/bin/env bash
    echo "first line of noise"
    echo "Running ExUnit with seed: 4242, max_cases: 24"
    printf '  1) test the thing breaks (Fake.Test)\\n     test/fake_test.exs:7\\n'
    for i in $(seq 1 40); do echo "later noise $i"; done
    echo "Result: 2/3 passed"
    echo "Failed: 1 test"
    exit 3
    """)

    File.chmod!(fake, 0o755)

    {out, status} = System.cmd(@script, [fake], env: [{"ATANOR_CHECK_LOG_DIR", dir}], stderr_to_stdout: true)
    assert status == 3

    log = Path.join(dir, "last.log") |> File.read!()
    assert log =~ "first line of noise"
    assert log =~ "later noise 40"

    tail = out |> String.split("\n", trim: true) |> Enum.take(-15) |> Enum.join("\n")
    assert tail =~ "1) test the thing breaks (Fake.Test)"
    assert tail =~ "test/fake_test.exs:7"
    assert tail =~ "seed: 4242"
    assert tail =~ "Failed: 1 test"
    assert tail =~ Path.join(dir, "check-")
  end

  @tag :tmp_dir
  test "a passing command keeps its log, prints no summary and keeps only the newest logs", %{tmp_dir: dir} do
    env = [{"ATANOR_CHECK_LOG_DIR", dir}, {"ATANOR_CHECK_LOG_KEEP", "2"}]

    for _ <- 1..3 do
      assert {"ok\n", 0} = System.cmd(@script, ["echo", "ok"], env: env, stderr_to_stdout: true)
      Process.sleep(1100)
    end

    assert length(Path.wildcard(Path.join(dir, "check-*.log"))) == 2
    assert File.read!(Path.join(dir, "last.log")) == "ok\n"
  end
end
