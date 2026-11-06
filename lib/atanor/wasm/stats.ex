defmodule Atanor.Wasm.Stats do
  @moduledoc """
  Counters and gauges kept by the native library (design §14), read with one
  cheap call. `emit/0` sends them as the `[:atanor, :wasm, :native, :stats]`
  telemetry event, so it works as a `:telemetry_poller` measurement:

      {:telemetry_poller,
       measurements: [{Atanor.Wasm.Stats, :emit, []}], period: :timer.seconds(10)}

  The measurements are listed in [telemetry.md](telemetry.md).
  """

  @doc "The native counters and gauges as a map of integers."
  @spec read() :: %{atom => integer}
  def read, do: Atanor.Wasm.Native.stats()

  @doc "Emits `[:atanor, :wasm, :native, :stats]` with the current values."
  @spec emit() :: :ok
  def emit, do: :telemetry.execute([:atanor, :wasm, :native, :stats], read(), %{})
end
