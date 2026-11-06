defmodule Atanor.TestkitBootReportTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias AtanorTestkit.Cluster.Boot

  test "a boot timeout report names the child that blocks and its stack" do
    parent = self()

    starter =
      spawn(fn ->
        child = %{id: :stuck, start: {__MODULE__, :stuck_start, [parent]}}
        Supervisor.start_link([child], strategy: :one_for_one)
      end)

    assert_receive :blocked, 5_000
    report = Boot.report(starter)

    assert report =~ "stuck_start"
    assert report =~ "Recent peer log"
    Process.exit(starter, :kill)
  end

  test "a starter that dies is reported at once, not after the boot timeout" do
    {starter, ref} = spawn_monitor(fn -> raise "module did not load" end)

    started = System.monotonic_time(:millisecond)
    error = assert_raise RuntimeError, fn -> Boot.await(starter, ref, 30_000) end

    assert error.message =~ "starter exited"
    assert error.message =~ "module did not load"
    assert System.monotonic_time(:millisecond) - started < 5_000
  end

  def stuck_start(parent) do
    send(parent, :blocked)
    receive do: (:never -> :ok)
  end
end
