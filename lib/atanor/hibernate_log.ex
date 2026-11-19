defmodule Atanor.HibernateLog do
  @moduledoc """
  Counts the cells hibernated on the node by the outcome of the compaction Alambique runs before the release
  (`hibernations` of `GET /runtime`), and logs a warning, at most once per second, when it ended at its deadline
  (also `deadline_error`: cut while listing, before the chain was known), was refused by the node's
  `release_concurrency` (`busy`) or failed: the cell may leave a long WAL
  chain behind and its next wake reads many segments (design §4.3). `tail` is what remained after the compaction.
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

    if outcome in [:deadline, :deadline_error, :busy, :error] and
         (is_nil(name) or Atanor.Admission.warn_hibernation?(name)) do
      ms = System.convert_time_unit(Map.get(measurements, :compact_duration, 0), :native, :millisecond)

      Logger.warning(
        "atanor: release compaction of #{inspect(meta[:cell])} ended with #{outcome} after #{ms} ms, " <>
          left(outcome, tail) <> " (reason #{meta[:reason]})"
      )
    end
  end

  # `busy` never looked at the chain: `tail` is 0 and says nothing.
  defp left(:busy, _tail), do: "no place free among `release_concurrency`, the chain was not compacted"
  defp left(_outcome, tail), do: "#{tail} WAL files left in its chain"
end
