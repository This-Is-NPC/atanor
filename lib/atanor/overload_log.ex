defmodule Atanor.OverloadLog do
  @moduledoc """
  Counts the wakes Alambique refused with `{:error, :overloaded}` by the reason of its
  `[:alambique, :admission, :overloaded]` event (`awake_limit_by` of `GET /runtime`).

  The event is VM-wide and carries no instance, so a VM that runs more than one Atanor instance counts a refusal on
  each of them, as `WakeLog` and `HibernateLog` do.
  """

  @doc "Attaches the handler for the node `name`; a second attach for the same name keeps the first."
  @spec attach(atom) :: :ok
  def attach(name) do
    _ = :telemetry.attach({__MODULE__, name}, [:alambique, :admission, :overloaded], &__MODULE__.handle/4, name)
    :ok
  end

  @doc false
  def handle(_event, _measurements, %{reason: reason}, name) do
    if name, do: Atanor.Admission.overloaded(name, reason)
    :ok
  end
end
