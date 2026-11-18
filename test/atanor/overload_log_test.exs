defmodule Atanor.OverloadLogTest do
  @moduledoc """
  The wakes Alambique refuses with `{:error, :overloaded}` are counted by the reason of its event in
  `admission.awake_limit_by`. The event is VM-wide, so the test is not async: no other node counts meanwhile.
  """
  use ExUnit.Case, async: false

  alias Atanor.{Admission, Cell, OverloadLog, Registry}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  test "a refused wake counts under the reason of the event, beside awake_limit" do
    node =
      Node.start(
        workers: [Manifests.probe("wakes", cells: %{"notes" => Manifests.notes_migrations()})],
        alambique: [awake: [max_wakes: 1, wake_queue_ms: 1]]
      )

    on_exit(fn -> Node.stop(node) end)

    assert %{no_wait: 0, queue_full: 0, wait_expired: 0, crowded: 0, max_children: 0} =
             Admission.stats(node.name).awake_limit_by

    # This process takes the only wake slot, so the next wake waits 1 ms in the queue and is refused.
    {:ok, config} = Alambique.Config.fetch(Registry.config(node.name).alambique)
    assert :ok = Alambique.Admission.begin_wake(config, 0)
    assert {:error, :overloaded} = Cell.owner(node.name, {"notes", "cold"})
    Alambique.Admission.release(config)

    assert %{wait_expired: 1, no_wait: 0} = Admission.stats(node.name).awake_limit_by
  end

  test "each reason has its own counter and an unknown one is ignored" do
    node = Node.start()
    on_exit(fn -> Node.stop(node) end)

    for reason <- [:no_wait, :queue_full, :crowded, :crowded, :max_children, :unknown],
        do: OverloadLog.handle([:alambique, :admission, :overloaded], %{}, %{reason: reason}, node.name)

    assert %{no_wait: 1, queue_full: 1, wait_expired: 0, crowded: 2, max_children: 1} =
             Admission.stats(node.name).awake_limit_by
  end
end
