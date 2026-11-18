defmodule Atanor.Scripts.PackScoreboardTest do
  @moduledoc "scripts/pack-scoreboard: the release asset unpacks into a directory that `atanor deploy` publishes with no Rust toolchain."
  use ExUnit.Case, async: true

  alias Atanor.CLI
  alias Atanor.Deployments
  alias Atanor.Test.Manifests

  @script Path.expand("../../scripts/pack-scoreboard", __DIR__)

  @tag :tmp_dir
  @tag timeout: 600_000
  test "the packed example deploys and activates from its unpacked directory", %{tmp_dir: dir} do
    out = Path.join(dir, "out")
    assert {log, 0} = System.cmd(@script, [out, "9.9.9"], stderr_to_stdout: true)
    assert log =~ "atanor-scoreboard-9.9.9.tar.gz"

    asset = Path.join(out, "atanor-scoreboard-9.9.9.tar.gz")
    assert {sums, 0} = System.cmd("sha256sum", ["-c", "atanor-scoreboard-9.9.9.tar.gz.sha256"], cd: out)
    assert sums =~ "OK"

    unpacked = Path.join(dir, "unpacked")
    File.mkdir_p!(unpacked)
    assert {_, 0} = System.cmd("tar", ["-xzf", asset, "-C", unpacked])
    assert Enum.sort(File.ls!(Path.join(unpacked, "scoreboard"))) == ["atanor.json", "scoreboard.wasm"]

    store = Manifests.memory_store("p")
    open = fn _url, _env -> {:ok, store, []} end
    argv = ["deploy", Path.join(unpacked, "scoreboard"), "--bucket", "s3://b/p", "--activate"]
    assert {0, deployed, ""} = CLI.run(argv, %{env: %{}, cwd: dir, stdin: fn _ -> :eof end, open_store: open})

    assert deployed =~ "(scoreboard, wasm, "
    assert {:ok, %{revision: 1}} = Deployments.head(store, "scoreboard")
  end
end
