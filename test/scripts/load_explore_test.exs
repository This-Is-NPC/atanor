defmodule Atanor.LoadExploreTest do
  use ExUnit.Case, async: true

  # scripts/load-explore --dry-run: the commands it would run, read without Docker.
  @script "scripts/load-explore"

  setup do
    dir = Path.join(System.tmp_dir!(), "atanor-load-explore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp summary(dir, scenario, measure, approved) do
    File.write!(Path.join(dir, "#{scenario}_#{measure}.summary.json"), ~s({"approved": #{approved}}))
  end

  defp explore(args, env \\ []),
    do: System.cmd(Path.expand(@script), ["--dry-run" | args], env: env, stderr_to_stdout: true)

  test "is executable", do: assert(File.stat!(@script).mode |> Bitwise.band(0o111) != 0)

  test "steps are 75, 100, 125 and 150 percent of each ceiling and the swap uses the http-wasm-jobs one", %{dir: dir} do
    for {m, v} <- [{"http-native", 400}, {"http-wasm", 333}, {"http-wasm-jobs", 120}, {"ws", 20000}, {"cells", 9000}],
        do: summary(dir, "A", m, v)

    assert {out, 0} = explore(["--from", dir, "--out", "/tmp/x"])
    lines = String.split(out, "\n", trim: true)

    assert "scripts/load-run http-native --steps 300,400,500,600 --step-s 75 --refine 0 --no-confirm" in lines
    assert "scripts/load-run http-wasm --steps 250,333,416,500 --step-s 75 --refine 0 --no-confirm" in lines
    assert "scripts/load-run ws --steps 15000,20000,25000,30000 --step-s 75 --refine 0 --no-confirm" in lines
    assert "scripts/load-run swap --rate 120" in lines
    # a fresh node and store before every measure, the swap last
    assert Enum.count(lines, &(&1 == "scripts/load-env reset")) == 6
    assert List.last(lines) == "scripts/load-run swap --rate 120"
  end

  test "the scenario picks the summaries and --ceiling replaces one", %{dir: dir} do
    summary(dir, "B", "http-native", 900)
    summary(dir, "B", "http-wasm-jobs", 100)

    args = [
      "--from",
      dir,
      "--measures",
      "http-native,swap",
      "--ceiling",
      "http-wasm-jobs=80",
      "--step-s",
      "60",
      "--factors",
      "1,1.5"
    ]

    assert {out, 0} = explore(args, [{"ATANOR_LOAD_SCENARIO", "B"}])

    assert out =~ "scripts/load-run http-native --steps 900,1350 --step-s 60 --refine 0 --no-confirm"
    assert out =~ "scripts/load-run swap --rate 80"
  end

  test "a null ceiling or a missing summary is an error before anything runs", %{dir: dir} do
    summary(dir, "A", "http-native", "null")
    assert {out, 1} = explore(["--from", dir, "--measures", "http-native"])
    assert out =~ "no ceiling for http-native"
    refute out =~ "load-env"

    assert {out, 1} = explore(["--from", dir, "--measures", "ws"])
    assert out =~ "no summary"
  end

  test "scale joins the default round, before the swap, when the previous round has its summary", %{dir: dir} do
    for {m, v} <- [{"http-native", 400}, {"http-wasm", 333}, {"http-wasm-jobs", 120}, {"ws", 20000}, {"cells", 9000}],
        do: summary(dir, "A", m, v)

    File.write!(
      Path.join(dir, "A_scale.summary.json"),
      ~s({"approved": null, "ceilings": {"http-native": {"1": 400, "2": 780}, "cells": {"1": 9000}}})
    )

    assert {out, 0} = explore(["--from", dir, "--out", "/tmp/x"])
    lines = String.split(out, "\n", trim: true)

    scale =
      "scripts/load-run scale --ceilings http-native:1=400,http-native:2=780,cells:1=9000 --factors 0.75,1,1.25,1.5 --step-s 75 --refine 0 --no-confirm"

    assert scale in lines
    assert Enum.find_index(lines, &(&1 == scale)) == length(lines) - 3
    assert List.last(lines) == "scripts/load-run swap --rate 120"
    # scale starts its own nodes: no reset before it
    assert Enum.count(lines, &(&1 == "scripts/load-env reset")) == 6
  end

  test "--ceiling scale= replaces the summary's ceilings and scale can be asked for alone", %{dir: dir} do
    assert {out, 0} =
             explore([
               "--from",
               dir,
               "--measures",
               "scale",
               "--ceiling",
               "scale=http-native:1=100,http-native:2=190",
               "--step-s",
               "60",
               "--",
               "--max-nodes",
               "2"
             ])

    assert out =~
             "scripts/load-run scale --ceilings http-native:1=100,http-native:2=190 --factors 0.75,1,1.25,1.5 --step-s 60 --refine 0 --no-confirm --max-nodes 2"

    refute out =~ "load-env"
  end

  test "a scale summary without ceilings is an error before anything runs", %{dir: dir} do
    File.write!(Path.join(dir, "A_scale.summary.json"), ~s({"approved": null, "ceilings": {}}))
    assert {out, 1} = explore(["--from", dir, "--measures", "scale"])
    assert out =~ "no ceilings for scale"
    refute out =~ "scripts/load-run"
  end

  test "options after -- go to load-run", %{dir: dir} do
    summary(dir, "A", "cells", 1000)
    assert {out, 0} = explore(["--from", dir, "--measures", "cells", "--", "--cell-period", "5"])
    assert out =~ "--no-confirm --cell-period 5"
  end
end
