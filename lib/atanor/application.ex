defmodule Atanor.Application do
  @moduledoc false
  use Application

  # The :pg scope shared by every instance in the VM and, through distribution,
  # by the nodes of a cluster: head change notices, alarm schedulers and
  # attached sockets and channels use it.
  @impl true
  def start(_type, _args) do
    children = [
      %{id: Atanor.PG, start: {:pg, :start_link, [Atanor.PG]}},
      Atanor.Channels
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
