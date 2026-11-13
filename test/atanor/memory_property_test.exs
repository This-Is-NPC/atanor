defmodule Atanor.MemoryPropertyTest do
  @moduledoc """
  The wake limits derived from the memory budget (design §4.3): always inside Alambique's range, the worst
  case of the wakes in flight fits the budget, and a bigger budget never gives smaller read-ahead.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.{Config, Memory}

  @mib 1_048_576

  defp budget, do: integer(0..(64 * 1024 * @mib))

  property "the limits stay in range and their worst case fits the budget" do
    check all(bytes <- budget()) do
      %{max_wakes: wakes, fetch_concurrency: fetch, max_inflight_bytes: inflight} = Memory.wake_limits(bytes)

      assert wakes in 1..256
      assert fetch in 1..16
      assert inflight in @mib..(64 * @mib)
      # Below the cost of one wake the minimum of one wake is already over the budget.
      cost = inflight + (fetch + 2) * 65_536
      if bytes >= cost, do: assert(wakes * cost <= bytes)
    end
  end

  property "a bigger budget never gives less read-ahead" do
    check all(a <- budget(), b <- budget()) do
      {small, big} = {Memory.wake_limits(min(a, b)), Memory.wake_limits(max(a, b))}
      assert small.max_inflight_bytes <= big.max_inflight_bytes
      assert small.fetch_concurrency <= big.fetch_concurrency
    end
  end

  property "the budget is the share of the headroom, and grows with the limit and the share" do
    check all(
            limit <- integer(1..(1024 * 1024 * @mib)),
            fraction <- float(min: 0.1, max: 0.99),
            share <- float(min: 0.01, max: 1.0)
          ) do
      memory = %{limit_bytes: limit, refuse_fraction: fraction, wake_fraction: share}
      budget = Memory.wake_budget(memory)

      assert budget <= limit * (1 - fraction) * share + 1
      assert Memory.wake_budget(%{memory | limit_bytes: limit * 2}) >= budget
      assert Memory.wake_budget(%{memory | wake_fraction: min(share * 1.5, 1.0)}) >= budget
    end
  end

  property "the options of the operator win, the others are derived" do
    check all(
            limit <- integer(64..(64 * 1024)),
            wakes <- one_of([constant(nil), integer(1..1000)]),
            fetch <- one_of([constant(nil), integer(1..64)]),
            inflight <- one_of([constant(nil), integer(1..(1024 * @mib))])
          ) do
      awake = if wakes, do: [max_wakes: wakes], else: []
      restore = Enum.reject([fetch_concurrency: fetch, max_inflight_bytes: inflight], &(elem(&1, 1) == nil))

      config =
        Config.build(
          name: :memory_property,
          store: {AlambiqueTestkit.MemoryStore, %{}},
          data_dir: System.tmp_dir!(),
          port: 0,
          memory: [limit_bytes: limit * @mib],
          alambique: [awake: awake, restore: restore]
        )

      derived = Memory.wake_limits(Memory.wake_budget(config.memory))
      opts = config.alambique_opts

      assert opts[:awake][:max_wakes] == (wakes || derived.max_wakes)
      assert opts[:restore][:fetch_concurrency] == (fetch || derived.fetch_concurrency)
      assert opts[:restore][:max_inflight_bytes] == (inflight || derived.max_inflight_bytes)
    end
  end
end
