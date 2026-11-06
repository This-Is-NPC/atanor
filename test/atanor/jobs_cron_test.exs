defmodule Atanor.Jobs.CronTest do
  use ExUnit.Case, async: true

  alias Atanor.Jobs.Cron

  @base 1_767_225_600_000

  test "macros and steps produce the expected next minute" do
    assert {:ok, at} = Cron.next_after("@hourly", @base)
    assert rem(at, 3_600_000) == 0

    assert {:ok, at} = Cron.next_after("*/15 * * * *", @base)
    assert rem(at, 900_000) == 0
  end

  test "weekdays and month boundaries are UTC" do
    # 2026-01-01 is a Thursday; the next Monday 00:00 is 2026-01-05.
    assert {:ok, at} = Cron.next_after("0 0 * * 1", DateTime.to_unix(~U[2026-01-01 00:00:00Z], :millisecond))
    assert DateTime.to_unix(DateTime.from_unix!(at, :millisecond), :millisecond) == 1_767_571_200_000
  end

  test "day-of-month and day-of-week are ORed when both are restricted" do
    from = DateTime.to_unix(~U[2026-01-01 00:00:00Z], :millisecond)
    # The 13th or a Friday: 2026-01-02 is the first Friday.
    assert {:ok, at} = Cron.next_after("0 0 13 * 5", from)
    assert DateTime.to_unix(DateTime.from_unix!(at, :millisecond), :millisecond) == 1_767_312_000_000
  end

  test "leap day is found and impossible expressions are refused" do
    from = DateTime.to_unix(~U[2025-01-01 00:00:00Z], :millisecond)
    assert {:ok, at} = Cron.next_after("0 0 29 2 *", from)
    assert DateTime.to_unix(DateTime.from_unix!(at, :millisecond), :millisecond) == 1_835_395_200_000

    assert {:error, _} = Cron.parse("60 * * * *")
    assert {:error, _} = Cron.parse("* * * *")
  end

  # Reductions, not time: the work done does not depend on how busy the machine is.
  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_} = Process.info(self(), :reductions)
    {after_ - before, result}
  end

  test "an impossible schedule is refused without scanning the minutes" do
    for expression <- ["0 0 31 2 *", "0 0 30 2 *", "0 0 31 4,6,9,11 *"] do
      {work, result} = reductions(fn -> Cron.next_after(expression, @base) end)
      assert {:error, :no_match} = result
      assert work < 1_000_000, "#{expression} took #{work} reductions"
    end
  end

  test "a rare schedule is found exactly and without scanning the minutes" do
    {work, result} = reductions(fn -> Cron.next_after("59 23 31 12 *", @base) end)
    assert {:ok, at} = result
    assert at == DateTime.to_unix(~U[2026-12-31 23:59:00Z], :millisecond)
    assert work < 1_000_000
  end
end
