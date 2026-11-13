defmodule AtanorLoad.Application do
  @moduledoc "The node of the product image, plus the native worker `AtanorLoad.Worker` in its code."
  use Application

  @impl true
  def start(_type, _args), do: Supervisor.start_link(Atanor.Daemon.children(), strategy: :one_for_one)
end
