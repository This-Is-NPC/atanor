defmodule Atanor.WakeLogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Atanor.{Cell, RuntimeSample, WakeLog}
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Node

  defp wake(ms, cell \\ "rooms.a"),
    do: WakeLog.handle([:alambique, :cell, :wake], %{duration: ms * 1_000_000}, %{cell: cell, result: :ok}, nil)

  test "a wake of one second or more is logged with its cell and duration" do
    log = capture_log(fn -> wake(1_500) end)
    assert log =~ ~s(slow wake of "rooms.a": 1500 ms)
  end

  test "the log names the time spent in the store" do
    measurements = %{duration: 1_500_000_000, store_time: 1_200_000_000}
    log = capture_log(fn -> WakeLog.handle([:alambique, :cell, :wake], measurements, %{cell: "rooms.a"}, nil) end)
    assert log =~ "in 1200 ms"
  end

  test "a faster wake is not logged" do
    # capture_log sees the log of every test running beside this one, so the cell is this test's own.
    log = capture_log(fn -> wake(999, "rooms.faster") end)
    refute log =~ "rooms.faster"
  end

  describe "wakes" do
    # The event carries no instance, so the nodes of other tests in this VM can count too: only a rise is certain.
    test "a cell woken on the node is counted in the runtime sample" do
      node = Node.start(workers: [Manifests.jobs("jobs")])
      on_exit(fn -> Node.stop(node) end)
      wakes = fn -> RuntimeSample.sample(node.name, System.tmp_dir!()).wakes end
      before = wakes.()
      assert is_integer(before)

      assert {:ok, _} = Cell.query(node.name, {"jobs", "wake-count"}, "SELECT 1")
      Await.until(fn -> wakes.() > before end)
    end
  end

  describe "wake_ms" do
    test "the time of a wake is summed, and the longest is kept, in the runtime sample" do
      node = Node.start(workers: [Manifests.jobs("jobs")])
      on_exit(fn -> Node.stop(node) end)
      wake_ms = fn -> RuntimeSample.sample(node.name, System.tmp_dir!()).wake_ms end
      before = wake_ms.()
      assert %{total: total, max: longest} = before

      event = [:alambique, :cell, :wake]
      measurements = %{duration: 123_456 * 1_000_000}
      WakeLog.handle(event, measurements, %{cell: "rooms.a", result: :ok}, node.name)
      WakeLog.handle(event, measurements, %{cell: "rooms.a", result: :error}, node.name)

      # Other wakes in this VM can add to the sum, never take from it.
      assert wake_ms.().total >= total + 123_456
      assert wake_ms.().max >= max(longest, 123_456)
    end
  end

  test "attaching twice keeps one handler" do
    assert :ok = WakeLog.attach(:wake_log_test)
    assert :ok = WakeLog.attach(:wake_log_test)
    :telemetry.detach({WakeLog, :wake_log_test})
  end
end
