defmodule Atanor.Jobs.Slots do
  @moduledoc false
  # Per-node concurrency slots for jobs (design §15.5). A job that cannot get
  # a slot stays pending; the wake-up is re-armed, so waiting costs no attempt.

  use GenServer

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: name(config.name)]]}}
  end

  @doc "The slots process of an instance."
  def name(instance), do: Module.concat(instance, JobSlots)

  @doc """
  Takes a slot for `worker` on behalf of the calling process; `:none` when the node or worker limit is
  full. A slot is given back when its holder exits, so a process that dies between claiming a job and
  starting it does not keep the slot for good.
  """
  @spec checkout(atom, String.t()) :: :ok | :none
  def checkout(instance, worker), do: call(instance, {:checkout, worker, self()}, :none)

  @doc "Returns a slot the calling process holds; nothing when it holds none."
  @spec release(atom, String.t()) :: :ok
  def release(instance, worker), do: call(instance, {:release, worker, self()}, :ok)

  @doc """
  Hands a slot the calling process holds to `pid`. A `pid` that already exited gives it back.
  """
  @spec transfer(atom, String.t(), pid) :: :ok
  def transfer(instance, worker, pid), do: call(instance, {:transfer, worker, self(), pid}, :ok)

  @doc "Stops granting slots: a node that is stopping claims no new job."
  @spec close(atom) :: :ok
  def close(instance), do: call(instance, :close, :ok)

  @doc "Whether the node stopped granting slots."
  @spec closed?(atom) :: boolean
  def closed?(instance), do: call(instance, :closed?, true)

  @doc "The current slot counts."
  @spec stats(atom) :: map
  def stats(instance), do: GenServer.call(name(instance), :stats)

  # A node that is stopping has no slots process: it grants nothing, and has nothing to give back.
  defp call(instance, message, stopped) do
    GenServer.call(name(instance), message)
  catch
    :exit, {:noproc, _} -> stopped
  end

  @impl true
  def init(config) do
    {:ok, %{config: config, total: 0, workers: %{}, closed: false, holds: %{}}}
  end

  @impl true
  def handle_call({:checkout, worker, pid}, _from, state) do
    limits = state.config.jobs
    used = Map.get(state.workers, worker, 0)

    if not state.closed and state.total < limits.concurrency and used < limits.worker_concurrency do
      state = %{state | total: state.total + 1, workers: Map.put(state.workers, worker, used + 1)}
      {:reply, :ok, hold(state, worker, pid)}
    else
      {:reply, :none, state}
    end
  end

  def handle_call({:release, worker, pid}, _from, state) do
    case find(state, worker, pid) do
      nil -> {:reply, :ok, state}
      ref -> {:reply, :ok, give_back(state, ref)}
    end
  end

  def handle_call({:transfer, worker, from, to}, _from, state) do
    case find(state, worker, from) do
      nil ->
        {:reply, :ok, state}

      ref ->
        {_, state} = pop_hold(state, ref)
        {:reply, :ok, hold(state, worker, to)}
    end
  end

  def handle_call(:closed?, _from, state), do: {:reply, state.closed, state}

  def handle_call(:close, _from, state), do: {:reply, :ok, %{state | closed: true}}

  def handle_call(:stats, _from, state) do
    reply = %{node: node(), running: state.total, workers: state.workers, limits: state.config.jobs}
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, if(is_map_key(state.holds, ref), do: give_back(state, ref), else: state)}
  end

  defp hold(state, worker, pid) do
    ref = Process.monitor(pid)
    %{state | holds: Map.put(state.holds, ref, {pid, worker})}
  end

  defp find(state, worker, pid) do
    Enum.find_value(state.holds, fn {ref, held} -> if held == {pid, worker}, do: ref end)
  end

  defp pop_hold(state, ref) do
    Process.demonitor(ref, [:flush])
    {held, holds} = Map.pop(state.holds, ref)
    {held, %{state | holds: holds}}
  end

  defp give_back(state, ref) do
    {{_pid, worker}, state} = pop_hold(state, ref)
    used = Map.get(state.workers, worker, 0)
    workers = if used <= 1, do: Map.delete(state.workers, worker), else: Map.put(state.workers, worker, used - 1)
    %{state | total: max(state.total - 1, 0), workers: workers}
  end
end
