defmodule Atanor.Admin.ThrottlePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Admin.Throttle

  @limits %{max_failures: 3, failure_window_ms: 100, tracked_addresses: 1_000}

  defp table, do: :ets.new(:attempts, [:set, :public])

  # (client, time step, whether the token is right); time never goes back.
  defp attempts do
    gen all(steps <- list_of({member_of([:a, :b, :c]), integer(0..60), boolean()}, max_length: 80)) do
      {attempts, _} =
        Enum.map_reduce(steps, 0, fn {client, step, right?}, at -> {{client, at + step, right?}, at + step} end)

      attempts
    end
  end

  # Runs the attempts through the throttle and answers `{client, time, right?, admitted?}`.
  defp run(attempts, limits) do
    table = table()

    for {client, at, right?} <- attempts do
      case Throttle.admit(table, client, limits, at) do
        {:ok, window} ->
          if right?, do: Throttle.release(table, client, window)
          {client, at, right?, true}

        {:refused, retry_ms} ->
          assert retry_ms > 0
          {client, at, right?, false}
      end
    end
  end

  property "no address gets more failures than the limit in a window, and one under it is never refused" do
    check all(attempts <- attempts()) do
      for {_client, history} <- Enum.group_by(run(attempts, @limits), &elem(&1, 0)) do
        # A window opens at the first attempt after the previous one ended.
        for window <- split_windows(history, @limits.failure_window_ms) do
          failed = Enum.count(window, fn {_, _, right?, admitted?} -> admitted? and not right? end)
          assert failed <= @limits.max_failures

          # Refused only once the window holds the limit of failures; under it, always admitted.
          Enum.reduce(window, 0, fn {_, _, right?, admitted?}, failures ->
            assert admitted? == failures < @limits.max_failures
            if admitted? and not right?, do: failures + 1, else: failures
          end)
        end
      end
    end
  end

  defp split_windows([], _window), do: []

  defp split_windows([{_, start, _, _} | _] = history, window) do
    {inside, rest} = Enum.split_while(history, fn {_, at, _, _} -> at - start < window end)
    [inside | split_windows(rest, window)]
  end

  property "the table never holds more addresses than its cap" do
    check all(addresses <- list_of(integer(1..500), min_length: 1, max_length: 120)) do
      limits = %{max_failures: 1, failure_window_ms: 10_000, tracked_addresses: 20}
      table = table()

      for address <- addresses, do: Throttle.admit(table, address, limits, 0)
      assert :ets.info(table, :size) <= 20
    end
  end
end
