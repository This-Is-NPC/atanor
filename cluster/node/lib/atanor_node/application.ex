defmodule AtanorNode.Application do
  @moduledoc """
  One Atanor node of the container cluster. Its settings are `Atanor.Daemon`'s (docs/configuration.md):
  environment variables, with the secrets read from the files the `*_FILE` variables name. It holds
  no worker: deploy with `atanor deploy`.

  `ATANOR_PEERS` is the host names of the nodes, comma separated (see `AtanorNode.Mesh`). Empty: the
  node joins no cluster, as in a swap (docs/how-to-replace-a-node.md).
  """
  use Application

  @impl true
  def start(_type, _args) do
    settings = Atanor.Daemon.load!()

    children = [
      {AtanorNode.Mesh, settings.peers},
      {Atanor, Keyword.put(settings.opts, :name, AtanorNode.Atanor)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AtanorNode.Supervisor)
  end
end
