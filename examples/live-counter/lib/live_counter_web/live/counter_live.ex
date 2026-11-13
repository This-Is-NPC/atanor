defmodule LiveCounterWeb.CounterLive do
  @moduledoc "A page that shows the count of the `counter` worker, which Atanor serves in this VM, and adds one."
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, count: count(LiveCounter.Worker.call("GET")), node: node(), ingress: Atanor.port(Atanor.Daemon.instance()))}
  end

  @impl true
  def handle_event("increment", _params, socket) do
    {:noreply, assign(socket, count: count(LiveCounter.Worker.call("POST")))}
  end

  defp count({:ok, n}), do: n
  defp count({:error, :not_deployed}), do: "(the counter worker is not deployed)"

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Live counter</h1>
    <p>Count: <span id="count">{@count}</span></p>
    <button id="increment" phx-click="increment">Add one</button>
    <p>Served by <code id="node">{@node}</code>; Atanor's ingress listens on port {@ingress} of the same VM.</p>
    """
  end
end
