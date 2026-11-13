defmodule LiveCounter.Application do
  @moduledoc """
  The Atanor node (settings from the environment, docs/configuration.md) and the Phoenix endpoint, in one
  supervision tree and one VM. Atanor starts first: the page reads a worker that the node serves.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = Atanor.Daemon.children() ++ [{Phoenix.PubSub, name: LiveCounter.PubSub}, LiveCounterWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: LiveCounter.Supervisor)
  end
end
