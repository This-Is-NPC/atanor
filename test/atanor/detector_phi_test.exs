defmodule Atanor.Detector.PhiTest do
  @moduledoc "The phi accrual math (design §8.7)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Detector.Phi

  @ms 1_000

  defp window(intervals, size \\ 100) do
    {phi, _} =
      Enum.reduce(intervals, {Phi.new(0, 1_000 * @ms, size, 0.25), 0}, fn interval, {phi, at} ->
        {Phi.heartbeat(phi, at + interval), at + interval}
      end)

    phi
  end

  defp phi_at(phi, elapsed, min_std \\ 100 * @ms, pause \\ 0), do: Phi.phi(phi, phi.last + elapsed, min_std, pause)

  property "phi never decreases while a heartbeat is awaited" do
    check all(
            intervals <- list_of(integer(500..1_500), min_length: 1, max_length: 150),
            a <- integer(0..30_000),
            b <- integer(0..30_000),
            pause <- integer(0..3_000)
          ) do
      phi = window(Enum.map(intervals, &(&1 * @ms)))
      {early, late} = {min(a, b) * @ms, max(a, b) * @ms}
      assert phi_at(phi, early, 100 * @ms, pause * @ms) <= phi_at(phi, late, 100 * @ms, pause * @ms)
    end
  end

  test "phi is small at the expected interval and large long after it" do
    phi = window(List.duplicate(1_000 * @ms, 50))
    assert phi_at(phi, 1_000 * @ms) < 1
    assert phi_at(phi, 1_500 * @ms) < phi_at(phi, 2_000 * @ms)
    assert phi_at(phi, 3_000 * @ms) > 8
  end

  test "the same delay is less suspect on a jittery link" do
    steady = window(List.duplicate(1_000 * @ms, 100))
    jittery = window(Enum.flat_map(1..50, fn _ -> [500 * @ms, 1_500 * @ms] end))
    assert phi_at(jittery, 2_500 * @ms, 10 * @ms) < phi_at(steady, 2_500 * @ms, 10 * @ms)
  end

  test "the acceptable pause shifts phi and the minimum deviation bounds it" do
    steady = window(List.duplicate(1_000 * @ms, 100))
    assert phi_at(steady, 3_000 * @ms, 100 * @ms, 2_000 * @ms) < phi_at(steady, 3_000 * @ms, 100 * @ms, 0)
    assert phi_at(steady, 1_500 * @ms, 1_000 * @ms) < phi_at(steady, 1_500 * @ms, 10 * @ms)
  end

  test "phi is finite however long the silence" do
    phi = window(List.duplicate(1_000 * @ms, 10))
    assert phi_at(phi, 100_000_000 * @ms) == 300.0
  end

  test "the window keeps the newest intervals only" do
    phi = window(List.duplicate(100 * @ms, 100) ++ List.duplicate(1_000 * @ms, 20), 20)
    assert phi.count == 20
    assert phi_at(phi, 1_200 * @ms) < 2
  end

  test "touch moves the baseline without recording an interval" do
    phi = window(List.duplicate(1_000 * @ms, 10))
    touched = Phi.touch(phi, phi.last + 60_000 * @ms)
    assert touched.count == phi.count
    assert Phi.elapsed(touched, touched.last + 5 * @ms) == 5 * @ms
  end
end
