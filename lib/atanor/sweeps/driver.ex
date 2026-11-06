defmodule Atanor.Sweeps.Driver do
  @moduledoc false
  # One driver per operation. The lease is in the operation record; a driver
  # that loses the record stops. Pages are checkpointed before the next one.

  use GenServer

  alias Atanor.Sweeps
  alias Atanor.Diagnostics.Breadcrumb

  def child_spec({instance, id}) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [{instance, id}]},
      restart: :temporary
    }
  end

  def start_link({instance, id}), do: GenServer.start_link(__MODULE__, {instance, id})

  @impl true
  def init({instance, id}) do
    state = %{instance: instance, id: id, lease_id: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}
    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: step(state)

  @impl true
  def handle_info(:tick, state), do: step(state)

  @impl true
  def terminate(_reason, state) do
    try do
      Sweeps.release(state.instance, state.id, state.lease_id)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp step(state) do
    result =
      Breadcrumb.wrap(state.instance, %{kind: "sweep", operation_id: state.id}, fn ->
        Sweeps.drive_page(state.instance, state.id, state.lease_id)
      end)

    case result do
      :again ->
        {:noreply, state, {:continue, :tick}}

      # Waits for the canary window or the next guard sample, renewing the lease.
      {:wait, ms} ->
        Process.send_after(self(), :tick, min(ms, Atanor.Registry.config(state.instance).sweeps.renew_ms))
        {:noreply, state}

      :retry ->
        Process.sleep(Atanor.Registry.config(state.instance).sweeps.retry_ms)
        {:noreply, state, {:continue, :tick}}

      _ ->
        {:stop, :normal, state}
    end
  end
end
