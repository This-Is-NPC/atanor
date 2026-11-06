defmodule AtanorLab.Mesh do
  @moduledoc "Connects this node to its peers and reconnects after a partition: the operator's job (design 8)."
  use GenServer

  def start_link(peers), do: GenServer.start_link(__MODULE__, peers, name: __MODULE__)

  @impl true
  def init(peers) do
    send(self(), :connect)
    {:ok, peers}
  end

  @impl true
  def handle_info(:connect, peers) do
    for peer <- peers, peer != node(), peer not in Node.list(), do: Node.connect(peer)
    Process.send_after(self(), :connect, 1_000)
    {:noreply, peers}
  end
end
