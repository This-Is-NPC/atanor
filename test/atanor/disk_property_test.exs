defmodule Atanor.DiskPropertyTest do
  @moduledoc """
  The disk budget over random budgets and uses (design §4.4): the derived Alambique options fit in the
  budget and never override the operator, and the escalation is monotone in the use, with hysteresis.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.{Admission, Disk}

  @mib 1_048_576
  @gap Admission.hysteresis()

  defp budget, do: integer((2 * @mib)..(64 * 1_073_741_824))
  defp cells, do: integer(1..50_000)

  property "the derived WAL mark, WAL allowance and local cache never exceed the budget together" do
    check all(budget <- budget(), cells <- cells()) do
      opts = Disk.alambique_options([awake: [max_cells: cells]], budget, 5_000)
      wal = opts[:wal][:checkpoint_bytes]
      cache = opts[:local_cache][:max_bytes]

      assert wal in @mib..(64 * @mib)
      assert cache > 0
      assert wal + cache <= budget
      # The WAL allowance Alambique enforces and the local cache never exceed the budget together.
      assert opts[:wal][:max_bytes] + cache <= budget
      # What every cell's WAL may hold at its mark, within the half of the budget set aside for it.
      assert min(div(budget, 2), wal * cells) + cache == budget
    end
  end

  property "values the operator gave win" do
    check all(
            budget <- budget(),
            wal <- positive_integer(),
            cache <- positive_integer(),
            interval <- positive_integer()
          ) do
      opts =
        Disk.alambique_options(
          [wal: [checkpoint_bytes: wal], local_cache: [max_bytes: cache, interval_ms: interval]],
          budget,
          5_000
        )

      assert opts[:wal][:checkpoint_bytes] == wal
      assert opts[:local_cache][:max_bytes] == cache
      assert opts[:local_cache][:interval_ms] == interval
    end
  end

  property "a node without a budget keeps the options it was given" do
    check all(wal <- positive_integer()) do
      given = [wal: [checkpoint_bytes: wal]]
      assert Disk.alambique_options(given, nil, 5_000) == given
    end
  end

  @model %{budget: 1_000_000, evict_fraction: 0.7, refuse_fraction: 0.95}
  @rank %{ok: 0, reclaim: 1, refuse: 2}

  defp levels, do: map(list_of(integer(0..1_200_000), max_length: 20), &replay/1)

  defp replay(samples) do
    Enum.reduce(samples, Disk.new_levels(), fn bytes, levels -> elem(Disk.level(levels, bytes, @model), 1) end)
  end

  property "the escalation never falls as the use rises, whatever came before" do
    check all(levels <- levels(), a <- integer(0..1_200_000), b <- integer(0..1_200_000)) do
      {low, high} = {min(a, b), max(a, b)}
      {low_level, _} = Disk.level(levels, low, @model)
      {high_level, _} = Disk.level(levels, high, @model)
      assert @rank[low_level] <= @rank[high_level]
    end
  end

  property "marks: refuses from the refuse mark, reclaims from the evict mark, is quiet below the resume marks" do
    check all(levels <- levels(), bytes <- integer(0..1_200_000)) do
      {level, _} = Disk.level(levels, bytes, @model)
      b = @model.budget

      if bytes >= b * 0.95, do: assert(level == :refuse)
      if bytes >= b * 0.7 and bytes < b * 0.95, do: assert(level in [:reclaim, :refuse])
      if bytes < b * (0.7 - @gap), do: assert(level == :ok)
      if bytes < b * (0.95 - @gap), do: assert(level != :refuse)
    end
  end

  property "hysteresis: between the marks a level holds" do
    check all(levels <- levels(), bytes <- integer(round(1_000_000 * (0.95 - @gap))..(round(1_000_000 * 0.95) - 1))) do
      {_, next} = Disk.level(levels, bytes, @model)
      assert next.refuse == levels.refuse
    end
  end

  property "a use that stays still gives the same level" do
    check all(levels <- levels(), bytes <- integer(0..1_200_000)) do
      {level, next} = Disk.level(levels, bytes, @model)
      assert {level, next} == Disk.level(next, bytes, @model)
    end
  end
end
