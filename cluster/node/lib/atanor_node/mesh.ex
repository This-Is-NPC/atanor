defmodule AtanorNode.Mesh do
  @moduledoc """
  Connects this node to its peers and reconnects after a partition: the operator's job (design 8).
  The peers are named in a list of advertised hosts (`node-1.cluster` to `node-10.cluster`, the network
  aliases of the Compose services, which Docker's DNS resolves while their container runs). A node is
  named `atanor@<advertised host>`, so a restarted container is the same node whatever its address.
  """
  use GenServer

  def start_link(hosts), do: GenServer.start_link(__MODULE__, hosts, name: __MODULE__)

  @impl true
  def init(hosts) do
    send(self(), :connect)
    {:ok, for(host <- hosts, do: :"atanor@#{host}")}
  end

  @impl true
  def handle_info(:connect, peers) do
    for peer <- peers, peer != node(), peer not in Node.list(), do: Node.connect(peer)
    Process.send_after(self(), :connect, 1_000)
    {:noreply, peers}
  end
end
