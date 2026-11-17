defmodule Atanor.Pressure do
  @moduledoc """
  Memory pressure (design §4.3): while the working set of the node is at `memory: [hibernate_fraction:]` of
  its limit or more, the node hibernates idle awake cells, the least recently used first, so that it
  does not reach the refuse mark of `Atanor.Admission`.

  Every `memory: [hibernate_interval_ms:]` it reads the working set (`Atanor.Memory.working_set/1`, as
  the admission sampler does) and, at the mark or above, hibernates up to `memory: [hibernate_batch:]` idle
  cells through `Atanor.Disk.hibernate/2`. The memory comes back after the batch, so one batch per
  interval is all it does: the next sample decides whether another is needed. A cell with a call in flight is
  skipped, never forced.
  """
  use GenServer

  alias Atanor.{Disk, Memory}

  @hibernated 1
  @timeout_ms 15_000

  @doc false
  def child_spec(config), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}}

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @doc """
  What node `name` has done under pressure: `%{hibernated: cells, hibernate_at_bytes: mark}`, `nil` when
  the node does not watch its working set (no memory limit, or `hibernate_fraction: nil`).
  """
  @spec stats(atom) :: %{hibernated: non_neg_integer, hibernate_at_bytes: pos_integer} | nil
  def stats(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> nil
      %{counters: counters, mark: mark} -> %{hibernated: :atomics.get(counters, @hibernated), hibernate_at_bytes: mark}
    end
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    memory = config.memory

    case Memory.limit(memory) do
      {limit, _source} when is_integer(limit) and not is_nil(memory.hibernate_fraction) ->
        mark = trunc(limit * memory.hibernate_fraction)
        counters = :atomics.new(1, [])
        :persistent_term.put({__MODULE__, config.name}, %{counters: counters, mark: mark})
        send(self(), :tick)
        {:ok, %{config: config, mark: mark, counters: counters}}

      _ ->
        :ignore
    end
  end

  @impl true
  def handle_info(:tick, %{config: %{memory: memory}} = state) do
    Process.send_after(self(), :tick, memory.hibernate_interval_ms)

    case Memory.working_set(memory) do
      {:ok, bytes} when bytes >= state.mark -> relieve(state, bytes)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{config: config}), do: :persistent_term.erase({__MODULE__, config.name})

  defp relieve(%{config: config, counters: counters}, bytes) do
    alambique = config.alambique

    chosen =
      alambique
      |> Disk.awake_cells()
      |> Enum.reject(&is_nil(&1.last_used))
      |> Enum.sort_by(& &1.last_used)
      |> Enum.take(config.memory.hibernate_batch)

    hibernated =
      chosen
      |> Task.async_stream(&Disk.hibernate(alambique, &1.id),
        max_concurrency: 8,
        timeout: @timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.count(&(&1 == {:ok, :ok}))

    :atomics.add(counters, @hibernated, hibernated)

    :telemetry.execute(
      [:atanor, :memory, :pressure],
      %{working_set_bytes: bytes, candidates: length(chosen), hibernated: hibernated},
      %{instance: config.name}
    )
  end
end
