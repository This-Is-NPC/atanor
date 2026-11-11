defmodule Atanor.Takeover.ThrottleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Takeover.Throttle

  defp table, do: :ets.new(:throttle, [:set, :public])

  test "a burst within the interval emits once, then reports the suppressed count" do
    t = table()
    assert {:emit, 0} = Throttle.admit(t, 0, 1_000)
    for ms <- 1..999//111, do: assert(:suppress = Throttle.admit(t, ms, 1_000))
    assert Throttle.pending(t) == 9
    assert {:emit, 9} = Throttle.admit(t, 1_000, 1_000)
    assert Throttle.pending(t) == 0
  end

  property "events are bounded by the span and every refusal is accounted for" do
    check all(
            interval <- integer(1..500),
            deltas <- list_of(integer(0..300), min_length: 1, max_length: 200)
          ) do
      times = Enum.scan(deltas, &(&1 + &2))
      t = table()
      results = Enum.map(times, &Throttle.admit(t, &1, interval))
      emitted = for {:emit, n} <- results, do: n
      span = List.last(times) - hd(times)

      assert length(emitted) <= ceil(span / interval) + 1
      assert Enum.sum(emitted) + Throttle.pending(t) == length(times) - length(emitted)
    end
  end
end
