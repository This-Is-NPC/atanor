defmodule Atanor.Scripts.ReadmeCheckTest do
  @moduledoc "scripts/readme-check: it rejects the README damage that the 0.4.0 release-please run left."
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/readme-check", __DIR__)

  defp run(dir, text) do
    file = Path.join(dir, "README.md")
    File.write!(file, text)
    System.cmd(@script, [file], stderr_to_stdout: true)
  end

  @tag :tmp_dir
  test "a README with a single-line marker and plain addresses passes", %{tmp_dir: dir} do
    text = "version 0.4.0 <!-- x-release-please-version -->\n-p 127.0.0.1:8333:8333 -ip.bind=0.0.0.0\n"
    assert {"", 0} = run(dir, text)
  end

  @tag :tmp_dir
  test "a start and an end marker on one line fail", %{tmp_dir: dir} do
    text = "version <!-- x-release-please-start-version -->0.3.0<!-- x-release-please-end -->,\n"
    assert {out, 1} = run(dir, text)
    assert out =~ "README.md:1: release-please start and end markers on one line"
  end

  @tag :tmp_dir
  test "a replaced address fails", %{tmp_dir: dir} do
    assert {out, 1} = run(dir, "curl http://0.4.0.1:4000/\n")
    assert out =~ "README.md:1: address-like version replace: 0.4.0.1"
  end

  test "the README of the repository passes" do
    assert {"", 0} = System.cmd(@script, [], stderr_to_stdout: true)
  end
end
