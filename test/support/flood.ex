defmodule Atanor.Test.Flood do
  @moduledoc "Keeps bytes flowing to a peer over distribution, as a large message that fills the link does."

  @doc "Calls `sink/1` on `target` with a 32 KiB message every 20 ms, for `ms` milliseconds."
  def stream(target, ms) do
    payload = :binary.copy(<<1>>, 32_768)
    until = System.monotonic_time(:millisecond) + ms
    loop(target, payload, until)
  end

  defp loop(target, payload, until) do
    if System.monotonic_time(:millisecond) < until do
      :ok = :erpc.call(target, __MODULE__, :sink, [payload], 5_000)
      Process.sleep(20)
      loop(target, payload, until)
    else
      :ok
    end
  end

  @doc false
  def sink(_payload), do: :ok
end
