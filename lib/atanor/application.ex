defmodule Atanor.Application do
  @moduledoc false
  use Application

  require Logger

  # The :pg scope shared by every instance in the VM and, through distribution,
  # by the nodes of a cluster: head change notices, alarm schedulers and
  # attached sockets and channels use it.
  @impl true
  def start(_type, _args) do
    children = [
      %{id: Atanor.PG, start: {:pg, :start_link, [Atanor.PG]}},
      Atanor.Channels
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one) do
      # One handler for the VM: each instance says through `stop.sigterm` whether it drains.
      case Atanor.Signal.install() do
        :ok -> :ok
        {:error, reason} -> Logger.warning("atanor: SIGTERM keeps OTP's handler: #{inspect(reason)}")
      end

      {:ok, pid}
    end
  end

  @impl true
  def stop(_state) do
    _ = Atanor.Signal.uninstall()
    :ok
  end
end
