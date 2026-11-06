defmodule Atanor.HTTP.SocketBucketTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.HTTP.Socket

  defp bucket(rate, burst, now \\ 0), do: %Socket{rate: rate, burst: burst, tokens: burst, refilled: now}

  # Runs the arrivals (gaps in ms) and returns the accepted count, the bucket and the arrival times.
  defp run(state, gaps, start \\ 0) do
    Enum.reduce(gaps, {0, state, start}, fn gap, {accepted, state, now} ->
      now = now + gap

      case Socket.take(state, now) do
        {:ok, state} -> {accepted + 1, state, now}
        :limit -> {accepted, state, now}
      end
    end)
  end

  defp params, do: tuple({integer(1..200), integer(1..300)})

  # A burst of frames at one instant passes exactly `burst` times, then the next frame is refused.
  property "the burst passes at once and no more" do
    check all({rate, burst} <- params(), extra <- integer(1..5)) do
      {accepted, _, _} = run(bucket(rate, burst), List.duplicate(0, burst + extra))
      assert accepted == burst
    end
  end

  # Over any run the accepted frames never exceed the burst plus what the rate refilled in the elapsed time.
  property "accepted frames stay within burst + rate * elapsed" do
    check all(rate <- integer(1..200), burst <- integer(1..5), gaps <- list_of(integer(0..60), max_length: 400)) do
      {accepted, state, elapsed} = run(bucket(rate, burst), gaps)
      assert accepted <= burst + rate * elapsed / 1000 + 1.0e-6
      assert state.tokens >= 0 and state.tokens <= burst
    end
  end

  # A refused frame does not lose the time that passed: after the wait for one token it is accepted.
  property "a refused bucket accepts again after one refill period" do
    check all({rate, burst} <- params(), gaps <- list_of(integer(0..30), max_length: 200)) do
      {_, state, now} = run(bucket(rate, burst), gaps)
      {_, drained, now} = run(state, List.duplicate(0, burst + 1), now)
      wait = ceil(1000 / rate) + 1
      assert {:ok, _} = Socket.take(drained, now + wait)
    end
  end

  # Idle time never banks more than the burst.
  property "idle time refills up to the burst only" do
    check all({rate, burst} <- params(), idle <- integer(0..1_000_000)) do
      {accepted, _, _} = run(bucket(rate, burst), [idle] ++ List.duplicate(0, burst + 3))
      assert accepted == burst
    end
  end

  # With frames spaced at least 1/rate apart and a burst of one, none is ever refused.
  property "a steady sender at the allowed rate is never refused" do
    check all(rate <- integer(1..200), n <- integer(1..100)) do
      gap = ceil(1000 / rate)
      {accepted, _, _} = run(bucket(rate, 1), List.duplicate(gap, n))
      assert accepted == n
    end
  end
end
