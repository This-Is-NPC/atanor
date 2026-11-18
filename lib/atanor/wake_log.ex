defmodule Atanor.WakeLog do
  @moduledoc """
  Counts the cells woken on the node, and logs a wake that took `@slow_ms` or more (design §4.3): the cell, the store
  requests it made, the time they took and its duration, so a cell that stays out of service after a takeover can be
  told from one that never woke. The time spent waiting for a wake slot is not in it.
  """
  require Logger

  @slow_ms 1_000

  @doc "Attaches the handler for the node `name`; a second attach for the same name keeps the first."
  @spec attach(atom) :: :ok
  def attach(name) do
    _ = :telemetry.attach({__MODULE__, name}, [:alambique, :cell, :wake], &__MODULE__.handle/4, name)
    :ok
  end

  @doc false
  # Counts the wake that succeeded (`wakes` of `GET /runtime`), then logs a slow one.
  def handle(_event, %{duration: duration} = measurements, %{cell: cell} = meta, name) do
    ms = System.convert_time_unit(duration, :native, :millisecond)
    if name && meta[:result] == :ok, do: Atanor.Admission.wake(name, ms)

    store_ms = System.convert_time_unit(Map.get(measurements, :store_time, 0), :native, :millisecond)

    if ms >= @slow_ms do
      Logger.info(
        "atanor: slow wake of #{inspect(cell)}: #{ms} ms, #{inspect(meta[:requests])} store requests in #{store_ms} ms, " <>
          "result #{meta[:result]}"
      )
    end
  end
end
