defmodule AtanorDaemon.Application do
  @moduledoc """
  The Atanor daemon: one node, the processes of `Atanor.Daemon.children/1`. Its settings are
  `Atanor.Daemon`'s (docs/configuration.md): environment variables, with the secrets read from the
  files the `*_FILE` variables name. It holds no worker: deploy with `atanor deploy`.

  The node finds the others through the store (`Atanor.Discovery`, docs/design.md §8.16).
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(Atanor.Daemon.children(), strategy: :one_for_one, name: AtanorDaemon.Supervisor)
  end
end
