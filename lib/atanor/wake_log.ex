defmodule Atanor.WakeLog do
  @moduledoc """
  Logs a wake that took `@slow_ms` or more (design §4.3): the cell, the store requests it made, the time they took and its
  duration, so a cell that stays out of service after a takeover can be told from one that never woke.
  The time spent waiting for a wake slot is not in it.
  """
  require Logger

  @slow_ms 1_000

  @doc "Attaches the handler for the node `name`; a second attach for the same name keeps the first."
  @spec attach(atom) :: :ok
  def attach(name) do
    _ = :telemetry.attach({__MODULE__, name}, [:alambique, :cell, :wake], &__MODULE__.handle/4, nil)
    :ok
  end

  @doc false
  def handle(_event, %{duration: duration} = measurements, %{cell: cell} = meta, _config) do
    ms = System.convert_time_unit(duration, :native, :millisecond)
    store_ms = System.convert_time_unit(Map.get(measurements, :store_time, 0), :native, :millisecond)

    if ms >= @slow_ms do
      Logger.info(
        "atanor: slow wake of #{inspect(cell)}: #{ms} ms, #{inspect(meta[:requests])} store requests in #{store_ms} ms, " <>
          "result #{meta[:result]}"
      )
    end
  end
end
