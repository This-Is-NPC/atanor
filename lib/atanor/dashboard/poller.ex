if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Poller do
    @moduledoc false
    # Emits the native counters of the WASM library and of Alambique as
    # telemetry events, which the metrics page charts (docs/telemetry.md).
    use GenServer

    def start_link(period_ms), do: GenServer.start_link(__MODULE__, period_ms)

    @impl true
    def init(period_ms) do
      send(self(), :poll)
      {:ok, period_ms}
    end

    @impl true
    def handle_info(:poll, period_ms) do
      Atanor.Wasm.Stats.emit()
      Alambique.NativeStats.emit()
      Process.send_after(self(), :poll, period_ms)
      {:noreply, period_ms}
    end
  end
end
