defmodule Atanor.Sweeps.Supervisor do
  @moduledoc false
  use DynamicSupervisor

  def child_spec(config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, type: :supervisor}
  end

  def start_link(config), do: DynamicSupervisor.start_link(__MODULE__, config, name: name(config.name))

  @doc "The dynamic supervisor of the instance's sweep drivers."
  def name(instance), do: Module.concat(instance, SweepsSupervisor)

  @impl true
  def init(_config), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule Atanor.Sweeps.Manager do
  @moduledoc false
  # Polls the operation records and starts a driver for every running operation
  # that has no live lease, up to `sweeps.max_active` on this node.

  use GenServer

  require Logger

  alias Atanor.Sweeps
  alias Atanor.Sweeps.{Driver, Supervisor}

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: name(config.name)]]}}
  end

  def name(instance), do: Module.concat(instance, SweepsManager)

  @impl true
  def init(config) do
    Process.send_after(self(), :poll, config.sweeps.poll_ms)
    {:ok, %{config: config, drivers: %{}, terminal: %{}}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    Process.send_after(self(), :poll, state.config.sweeps.poll_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    drivers = for {id, {ref, other}} <- state.drivers, other != pid, into: %{}, do: {id, {ref, other}}
    {:noreply, %{state | drivers: drivers}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp poll(state) do
    instance = state.config.name
    now = System.os_time(:millisecond)
    alive = for {id, {ref, pid}} <- state.drivers, Process.alive?(pid), into: %{}, do: {id, {ref, pid}}
    state = %{state | drivers: alive}

    known = for {key, {op, expires}} <- state.terminal, expires > now, into: %{}, do: {key, op}

    case Sweeps.list(instance, nil, state.config.sweeps.max_records, known) do
      {:ok, operations} ->
        operations = cleanup(instance, operations, state.config, now)
        state = %{state | terminal: terminal(operations, state.terminal, known, state.config.sweeps.reread_ms, now)}

        Enum.reduce(Enum.sort_by(operations, & &1["created_at_ms"]), state, fn op, acc ->
          if map_size(acc.drivers) < acc.config.sweeps.max_active and start?(op, acc.drivers, now) do
            case DynamicSupervisor.start_child(Supervisor.name(instance), {Driver, {instance, op["id"]}}) do
              {:ok, pid} ->
                ref = Process.monitor(pid)
                %{acc | drivers: Map.put(acc.drivers, op["id"], {ref, pid})}

              {:error, {:already_started, pid}} ->
                ref = Process.monitor(pid)
                %{acc | drivers: Map.put(acc.drivers, op["id"], {ref, pid})}

              {:error, reason} ->
                Logger.warning("atanor: could not start sweep #{op["id"]}: #{inspect(reason)}")
                acc
            end
          else
            acc
          end
        end)

      {:error, reason} ->
        Logger.warning("atanor: could not list sweep operations: #{inspect(reason)}")
        state
    end
  rescue
    exception ->
      Logger.warning("atanor: sweep manager failed: " <> Exception.format(:error, exception, __STACKTRACE__))
      state
  end

  # A finished record is kept for `reread_ms`, spread per key so the rereads do not coincide.
  defp terminal(operations, old, known, reread_ms, now) do
    for op <- operations, Sweeps.terminal?(op), into: %{} do
      key = "operations/" <> op["id"]

      case old do
        %{^key => entry} when is_map_key(known, key) -> {key, entry}
        _ -> {key, {op, now + reread_ms + :erlang.phash2(key, max(div(reread_ms, 2), 1))}}
      end
    end
  end

  defp cleanup(instance, operations, config, now) do
    store = Atanor.Store.handle(instance)

    Enum.reject(operations, fn op ->
      old? =
        Sweeps.terminal?(op) and
          now - (op["updated_at_ms"] || op["created_at_ms"] || 0) > config.sweeps.retention_ms

      if old? do
        Atanor.Sweeps.Undo.delete(instance, op["id"])
        _ = Atanor.Store.delete(store, "operations/" <> op["id"])
        true
      else
        false
      end
    end)
  end

  defp start?(op, drivers, now) do
    op["state"] == "running" and not Map.has_key?(drivers, op["id"]) and
      (op["driver"] == nil or op["lease_until_ms"] <= now or op["driver"] == to_string(node()))
  end
end
