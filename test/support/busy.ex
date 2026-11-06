defmodule Atanor.Test.Busy do
  @moduledoc "Keeps every scheduler of a peer busy for a while, as a node under CPU load."

  @doc "Starts one spinning process per scheduler; they stop after `ms` milliseconds."
  def spin(ms) do
    until = System.monotonic_time(:millisecond) + ms

    for _ <- 1..System.schedulers_online() do
      spawn(fn -> loop(until) end)
    end

    :ok
  end

  defp loop(until) do
    if System.monotonic_time(:millisecond) < until do
      Enum.reduce(1..10_000, 0, &(&1 + &2))
      loop(until)
    end
  end
end
