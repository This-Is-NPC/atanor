defmodule Atanor.LazyRestoreLog do
  @moduledoc """
  Counts the lazy restores of the node (`lazy_restores` of `GET /runtime`): a cell whose files are at least
  `lazy_restore: [min_bytes:]` wakes before its pages are all fetched, and a query that needs a missing page
  waits for it on its dirty I/O thread. `pages` is what the restore fetched, `misses` the pages a query waited for.
  """

  @doc "Attaches the handler for the node `name`; a second attach for the same name keeps the first."
  @spec attach(atom) :: :ok
  def attach(name) do
    _ = :telemetry.attach({__MODULE__, name}, [:alambique, :replication, :hydrate], &__MODULE__.handle/4, name)
    :ok
  end

  @doc false
  def handle(_event, measurements, meta, name) do
    ms = System.convert_time_unit(Map.get(measurements, :duration, 0), :native, :millisecond)

    if name,
      do:
        Atanor.Admission.lazy_restore(
          name,
          meta[:result],
          Map.get(measurements, :pages, 0),
          Map.get(measurements, :misses, 0),
          ms
        )
  end
end
