defmodule Atanor.AwakeBudgetTest do
  @moduledoc """
  `awake: [max_bytes:]` keeps the native memory of a node flat as more cells wake (design §4.3).
  Run alone: `mix test test/atanor/awake_budget_test.exs`.
  """
  # Not async: the memory of the node is measured, so no other test may run beside it.
  use ExUnit.Case, async: false

  alias Atanor.{Env, Overview}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @notes Manifests.notes_migrations()
  @first 20
  @row String.duplicate("x", 1_000)
  # 150 KB of rows against a 64 KiB page cache: each awake cell fills its cache.
  @rows 150
  @budget 2_000_000
  @evict [:alambique, :admission, :evict]

  defp start(awake) do
    manifest = Manifests.probe("budget", cells: %{"notes" => @notes})
    node = Node.start(workers: [manifest], alambique: [awake: [cache_kib: 64] ++ awake])
    on_exit(fn -> Node.stop(node) end)
    {:ok, deployment} = Atanor.Registry.deployment(node.name, "budget")
    {node, Env.new(node.name, deployment)}
  end

  # Wakes the cells of `range`; every call must answer. Returns the memory the cells use in the NIF's
  # allocator: `system` without the memory of the stores and the VM that the cells' data also fills.
  defp wake(env, range) do
    for n <- range do
      cell = {"notes", "c#{n}"}
      for _ <- 1..@rows, do: {:ok, _} = Env.execute(env, cell, "INSERT INTO notes (body) VALUES (?)", [@row])
      assert {:ok, %{rows: [[@rows]]}} = Env.query(env, cell, "SELECT count(*) FROM notes")
    end

    m = :erlang.memory()
    m[:system] - m[:atom] - m[:binary] - m[:code] - m[:ets]
  end

  def forward(_event, %{bytes: bytes}, meta, pid), do: send(pid, {:evict, bytes, meta})

  # Memory after `@first` cells, and its growth when 3 times as many wake after them.
  defp growth(awake) do
    {node, env} = start(awake)
    base = wake(env, 1..@first)
    grown = wake(env, (@first + 1)..(4 * @first))
    {grown - base, Overview.cells_count(node.name).count}
  end

  test "with max_bytes the memory stops growing with the cells that wake; without it, it grows" do
    {unbounded, awake} = growth([])
    assert awake == 4 * @first
    # The comparison is only meaningful if the cells do cost memory.
    assert unbounded > 4 * @budget

    :telemetry.attach(__MODULE__, @evict, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(__MODULE__) end)

    {bounded, awake} = growth(max_bytes: @budget)
    assert bounded < @budget
    assert awake < @first
    assert_receive {:evict, bytes, %{max_bytes: @budget}}
    assert bytes <= @budget
  end
end
