defmodule Atanor.WakeLimitCauseTest do
  @moduledoc """
  A wake that Alambique refuses with a bare `{:error, :overloaded}` (the wake slots and queue are full, as when
  many cells wake at once) names its gate, `awake_limit`, for the 503 body and the counters.
  """
  use ExUnit.Case, async: true

  alias Atanor.{Cell, Registry}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  test "the owner lookup that wakes a cell names awake_limit when the wake is refused" do
    node =
      Node.start(
        workers: [Manifests.probe("wakes", cells: %{"notes" => Manifests.notes_migrations()})],
        alambique: [awake: [max_wakes: 1, wake_queue_ms: 1]]
      )

    on_exit(fn -> Node.stop(node) end)

    # This process takes the only wake slot and holds it, so the next wake waits 1 ms in the queue and is refused.
    {:ok, config} = Alambique.Config.fetch(Registry.config(node.name).alambique)
    assert :ok = Alambique.Admission.begin_wake(config, 0)

    Cell.clear_unavailable()
    assert {:error, :overloaded} = Cell.owner(node.name, {"notes", "cold"})
    assert Cell.overload_cause() == :awake_limit

    Alambique.Admission.release(config)
    assert {:ok, _} = Cell.owner(node.name, {"notes", "cold"})
  end
end
