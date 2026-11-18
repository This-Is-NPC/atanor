defmodule Atanor.HibernateLog do
  @moduledoc """
  Counts the cells hibernated on the node by the outcome of the compaction Alambique runs before the release
  (`hibernations` of `GET /runtime`), and logs a warning, at most once per second, when it ended at its deadline or
  failed: the cell leaves a long WAL chain behind and its next wake reads many segments (design §4.3).
  """
  require Logger

  @doc "Attaches the handler for the node `name`; a second attach for the same name keeps the first."
  @spec attach(atom) :: :ok
  def attach(name) do
    _ = :telemetry.attach({__MODULE__, name}, [:alambique, :cell, :hibernate], &__MODULE__.handle/4, name)
    :ok
  end

  @doc false
  def handle(_event, measurements, %{compaction: outcome} = meta, name) do
    tail = Map.get(measurements, :tail, 0)
    if name, do: Atanor.Admission.hibernation(name, outcome, tail)

    if outcome in [:deadline, :error] and (is_nil(name) or Atanor.Admission.warn_hibernation?(name)) do
      ms = System.convert_time_unit(Map.get(measurements, :compact_duration, 0), :native, :millisecond)

      Logger.warning(
        "atanor: release compaction of #{inspect(meta[:cell])} ended with #{outcome} after #{ms} ms, " <>
          "#{tail} WAL files left in its chain (reason #{meta[:reason]})"
      )
    end
  end
end
