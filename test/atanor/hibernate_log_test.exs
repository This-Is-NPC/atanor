defmodule Atanor.HibernateLogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Atanor.{Cell, HibernateLog, RuntimeSample}
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Node

  @event [:alambique, :cell, :hibernate]

  defp hibernate(name, outcome, cell, tail \\ 4, ms \\ 3_000) do
    measurements = %{tail: tail, compact_duration: ms * 1_000_000, duration: 1}
    HibernateLog.handle(@event, measurements, %{cell: cell, reason: :request, compaction: outcome}, name)
  end

  defp hibernations(name), do: RuntimeSample.sample(name, System.tmp_dir!()).hibernations

  describe "counters of GET /runtime" do
    # The event carries no instance, so the nodes of other tests in this VM can count too: only a rise is certain.
    test "each outcome counts in its own counter and the longest tail is kept" do
      node = Node.start(workers: [Manifests.jobs("jobs")])
      on_exit(fn -> Node.stop(node) end)
      before = hibernations(node.name)
      assert %{compaction: %{none: _, done: _, deadline: _, error: _}, tail_max: _} = before

      for outcome <- [:none, :done, :deadline, :error], do: hibernate(node.name, outcome, "jobs.counted", 7, 1)
      hibernate(node.name, :done, "jobs.counted", 3, 1)

      now = hibernations(node.name)
      assert now.compaction.none >= before.compaction.none + 1
      assert now.compaction.done >= before.compaction.done + 2
      assert now.compaction.deadline >= before.compaction.deadline + 1
      assert now.compaction.error >= before.compaction.error + 1
      assert now.tail_max >= 7
    end

    test "a cell hibernated by a real drain is counted" do
      node = Node.start(workers: [Manifests.jobs("jobs")])
      on_exit(fn -> Node.stop(node) end)
      before = hibernations(node.name)
      total = fn h -> h.compaction.none + h.compaction.done end

      assert {:ok, _} = Cell.query(node.name, {"jobs", "hibernate-count"}, "SELECT 1")
      assert {:ok, %{state: :drained}} = Atanor.drain(node.name, exit: false)
      Await.until(fn -> total.(hibernations(node.name)) > total.(before) end)
    end
  end

  describe "warning" do
    test "a compaction cut by its deadline is logged with the cell, tail and time" do
      log = capture_log(fn -> hibernate(nil, :deadline, "jobs.cut", 192, 3_000) end)
      assert log =~ ~s(release compaction of "jobs.cut" ended with deadline after 3000 ms, 192 WAL files)
    end

    test "a failed compaction is logged" do
      log = capture_log(fn -> hibernate(nil, :error, "jobs.failed") end)
      assert log =~ ~s(release compaction of "jobs.failed" ended with error)
    end

    test "a finished or skipped compaction is not logged" do
      log =
        capture_log(fn ->
          hibernate(nil, :done, "jobs.quiet-done")
          hibernate(nil, :none, "jobs.quiet-none")
        end)

      refute log =~ "jobs.quiet"
    end

    test "the warning is limited to one per second per node, the counters are not" do
      node = Node.start(workers: [Manifests.jobs("jobs")])
      on_exit(fn -> Node.stop(node) end)
      before = hibernations(node.name).compaction.deadline

      log =
        capture_log(fn ->
          for n <- 1..3, do: hibernate(node.name, :deadline, "jobs.burst#{n}")
        end)

      assert length(Regex.scan(~r/release compaction of "jobs\.burst/, log)) == 1
      assert hibernations(node.name).compaction.deadline >= before + 3
    end
  end

  test "attaching twice keeps one handler" do
    assert :ok = HibernateLog.attach(:hibernate_log_test)
    assert :ok = HibernateLog.attach(:hibernate_log_test)
    :telemetry.detach({HibernateLog, :hibernate_log_test})
  end
end
