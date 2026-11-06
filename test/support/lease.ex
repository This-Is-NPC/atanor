defmodule Atanor.Test.Lease do
  @moduledoc "Reads the lease of a cell in a peer, for tests of takeovers."

  @doc "The lease (`owner`, `epoch`, ...) of the Alambique cell `id` of `instance`, read from the store."
  def read(instance, id) do
    alambique = Alambique.Config.fetch!(Atanor.Registry.config(instance).alambique)
    {:ok, location} = Alambique.Placement.locate(alambique, id)
    Alambique.Lease.read(Alambique.Config.lease_ctx(alambique, location), id)
  end
end
