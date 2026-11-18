defmodule Atanor.HotCellsMoveTest do
  # A trace pattern on Alambique.move/4 is global to the VM.
  use ExUnit.Case, async: false

  alias Atanor.{Cell, HotCells}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  defp start(extra) do
    node =
      Node.start([workers: [Manifests.probe("moves", cells: %{"notes" => Manifests.notes_migrations()})]] ++ extra)

    on_exit(fn -> Node.stop(node) end)
    node
  end

  # The options HotCells.move/4 gives Alambique.move/4.
  defp move_opts(node, reason) do
    cell = {"notes", "moving"}
    {:ok, _} = Cell.query(node.name, cell, "SELECT 1")

    # A traced process cannot be its own tracer.
    test = self()
    tracer = spawn_link(fn -> forward(test) end)
    :erlang.trace_pattern({Alambique, :move, 4}, true, [:local])
    :erlang.trace(self(), true, [:call, tracer: tracer])
    HotCells.move(node.name, cell, node(), reason)
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern({Alambique, :move, 4}, false, [:local])

    assert_receive {:move, opts}, 5_000
    opts
  end

  defp forward(test) do
    receive do
      {:trace, _, :call, {Alambique, :move, [_, _, _, opts]}} ->
        send(test, {:move, opts})
        forward(test)

      _ ->
        forward(test)
    end
  end

  test "a move leaves the release compaction deadline to Alambique by default" do
    node = start(hot_cells: [enabled: true, move_timeout_ms: 9_000])
    opts = move_opts(node, :manual)
    assert opts[:timeout] == 9_000
    refute Keyword.has_key?(opts, :release_deadline_ms)
  end

  test "hot_cells release_deadline_ms is passed to the move as given" do
    for ms <- [0, 4_000] do
      node = start(hot_cells: [enabled: true, release_deadline_ms: ms])
      assert move_opts(node, :manual)[:release_deadline_ms] == ms
    end
  end
end
