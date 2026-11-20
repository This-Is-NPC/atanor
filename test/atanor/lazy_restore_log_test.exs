defmodule Atanor.LazyRestoreLogTest do
  use ExUnit.Case, async: true

  alias Atanor.{LazyRestoreLog, RuntimeSample}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @event [:alambique, :replication, :hydrate]

  test "a hydrate event is counted by result, with its pages, misses and duration, in the runtime sample" do
    node = Node.start(workers: [Manifests.jobs("jobs")])
    on_exit(fn -> Node.stop(node) end)
    lazy = fn -> RuntimeSample.sample(node.name, System.tmp_dir!()).lazy_restores end
    before = lazy.()

    assert %{ok: 0, error: 0, pages: 0, misses: 0, ms_total: 0, ms_max: 0} = before

    measurements = %{duration: 250 * 1_000_000, pages: 40, misses: 3}
    LazyRestoreLog.handle(@event, measurements, %{cell: "rooms.a", result: :ok}, node.name)

    LazyRestoreLog.handle(
      @event,
      %{measurements | duration: 90 * 1_000_000},
      %{cell: "rooms.a", result: :error},
      node.name
    )

    assert lazy.() == %{ok: 1, error: 1, pages: 80, misses: 6, ms_total: 340, ms_max: 250}
  end

  test "attaching twice keeps one handler" do
    assert :ok = LazyRestoreLog.attach(:lazy_restore_log_test)
    assert :ok = LazyRestoreLog.attach(:lazy_restore_log_test)
    :telemetry.detach({LazyRestoreLog, :lazy_restore_log_test})
  end
end
