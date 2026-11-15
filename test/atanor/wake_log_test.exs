defmodule Atanor.WakeLogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Atanor.WakeLog

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

  test "attaching twice keeps one handler" do
    assert :ok = WakeLog.attach(:wake_log_test)
    assert :ok = WakeLog.attach(:wake_log_test)
    :telemetry.detach({WakeLog, :wake_log_test})
  end
end
