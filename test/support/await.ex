defmodule Atanor.Test.Await do
  @moduledoc "Waits for observable state; the timeout only bounds failure."

  @doc "Returns the first truthy result of `fun`, or fails after `timeout` milliseconds."
  def until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop(fun, deadline)
  end

  defp loop(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          raise ExUnit.AssertionError, message: "condition not met in time"
        else
          Process.sleep(10)
          loop(fun, deadline)
        end

      value ->
        value
    end
  end
end
