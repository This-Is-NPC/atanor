defmodule Atanor.Drain do
  @moduledoc false
  # Hands the node's cells off when the instance stops (design §8.11). The
  # supervisor stops its children in reverse start order, so by the time this
  # one stops the listeners are closed and the detector has told the peers that
  # the node leaves; Alambique stops after it.
  use GenServer

  require Logger

  alias Atanor.Registry

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {GenServer, :start_link, [__MODULE__, config]},
      shutdown: config.stop.shutdown_ms
    }
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    {:ok, config}
  end

  @impl true
  def terminate(_reason, config) do
    started = System.monotonic_time()
    Registry.put_state(config.name, :stopping)

    summary =
      try do
        {:ok, summary} = Alambique.drain(config.alambique, options(config.stop))
        summary
      catch
        kind, reason -> %{hibernated: 0, errors: [{:drain, {kind, reason}}]}
      end

    if summary.errors != [] do
      Logger.warning(
        "atanor: drain left #{length(summary.errors)} cells to their leases: #{inspect(summary.errors, limit: 5)}"
      )
    end

    :telemetry.execute(
      [:atanor, :node, :drain],
      %{duration: System.monotonic_time() - started, hibernated: summary.hibernated, errors: length(summary.errors)},
      %{instance: config.name, node: node(), error_list: summary.errors}
    )
  end

  defp options(stop) do
    [timeout: stop.drain_timeout_ms, concurrency: stop.drain_concurrency] |> Enum.reject(&match?({_, nil}, &1))
  end
end
