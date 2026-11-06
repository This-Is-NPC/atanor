defmodule AtanorLab.Events do
  @moduledoc """
  Writes the failure-detection and placement events of this node to the journal, one line each, for the scenarios to
  count, and counts the bounded reads by who answered (`AtanorLab.Stats`).
  """
  require Logger

  @events [
    [:atanor, :node, :suspect],
    [:atanor, :node, :down],
    [:atanor, :node, :link_broken],
    [:atanor, :node, :alive],
    [:atanor, :node, :drain],
    [:atanor, :cell, :take_over],
    [:atanor, :hot_cell, :decision],
    [:atanor, :hot_cell, :move],
    [:atanor, :hot_cell, :replicas]
  ]

  def attach do
    :telemetry.attach_many(__MODULE__, @events, &__MODULE__.log/4, nil)
    :telemetry.attach({__MODULE__, :replica_reads}, [:alambique, :replica, :read], &AtanorLab.Stats.replica_read/4, nil)
  end

  def log([:atanor | event], measurements, meta, _config) do
    Logger.info(
      "lab-event #{Enum.join(event, ".")} #{inspect(Map.delete(meta, :instance), limit: 8)} #{inspect(measurements)}"
    )
  end
end
