defmodule Atanor.Drain do
  @moduledoc false
  # Hands the node's cells off (design §8.11). `run/2` drains on demand (`Atanor.drain/2`, the admin API,
  # the CLI and SIGTERM through `Atanor.Signal`) and the stop of the instance runs the same `perform/2`: the node reports `draining`, the
  # running jobs finish, Alambique leaves the membership, refuses new wakes and hibernates the awake cells,
  # releasing each lease. On demand the listeners keep serving the cells the node still holds; at a stop
  # the supervisor has closed them (it stops its children in reverse start order), the detector tells the
  # peers that the node leaves after this child, and Alambique stops after it.
  use GenServer

  require Logger

  alias Atanor.{Jobs, Registry}

  # The whole drain ends at `stop.shutdown_ms`; the supervisor waits a little more, so the end is reported.
  @report_ms 5_000

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {GenServer, :start_link, [__MODULE__, config, [name: name(config.name)]]},
      shutdown: config.stop.shutdown_ms + @report_ms
    }
  end

  def name(instance), do: Module.concat(instance, Drain)

  @doc """
  Drains the node and returns `{:ok, status}` when it ends. A drain already running is joined, and one that
  ended answers with its status. `:exit` (default `stop.exit`) says what ends the node afterwards: `true`
  stops the VM with status 0, or 1 when a cell was left to its lease; a function receives that status.
  """
  @spec run(atom, keyword) :: {:ok, map}
  def run(instance, opts \\ []) do
    exit = Keyword.validate!(opts, exit: nil)[:exit]
    GenServer.call(name(instance), {:drain, exit}, :infinity)
  end

  @doc "The state of the drain: `idle`, `draining` or `drained` (with what it did)."
  @spec status(atom) :: map
  def status(instance), do: GenServer.call(name(instance), :status)

  # The instances of the VM that run `stop: [sigterm: :drain]`, for `Atanor.Signal`.
  @group {__MODULE__, :sigterm}

  @doc false
  @spec instances() :: [atom]
  def instances, do: Enum.map(:pg.get_members(Atanor.PG, @group), &GenServer.call(&1, :instance))

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    if config.stop.sigterm == :drain, do: :pg.join(Atanor.PG, @group, self())
    {:ok, %{config: config, state: :idle, task: nil, waiters: [], summary: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, view(state), state}
  def handle_call(:instance, _from, state), do: {:reply, state.config.name, state}

  def handle_call({:drain, exit}, from, %{state: :idle} = state) do
    config = state.config
    task = Task.async(fn -> perform(config, :api) end)
    {:noreply, %{state | state: :draining, task: task, waiters: [{from, exit}]}}
  end

  def handle_call({:drain, exit}, from, %{state: :draining} = state),
    do: {:noreply, %{state | waiters: [{from, exit} | state.waiters]}}

  def handle_call({:drain, exit}, _from, %{state: :drained} = state) do
    finish(state, exit)
    {:reply, {:ok, view(state)}, state}
  end

  @impl true
  def handle_info({ref, summary}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete(state, summary)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, complete(state, %{hibernated: 0, errors: [{:drain, reason}], duration_ms: 0})}

  def handle_info(_message, state), do: {:noreply, state}

  defp complete(%{waiters: waiters} = state, summary) do
    state = %{state | state: :drained, task: nil, summary: summary, waiters: []}

    for {from, exit} <- Enum.reverse(waiters) do
      GenServer.reply(from, {:ok, view(state)})
      finish(state, exit)
    end

    state
  end

  @impl true
  def terminate(_reason, state) do
    Registry.put_state(state.config.name, :stopping)

    case state do
      %{state: :idle} -> perform(state.config, :stop)
      %{state: :draining, task: task} -> Task.yield(task, state.config.stop.shutdown_ms) || Task.shutdown(task)
      %{state: :drained} -> :ok
    end
  end

  @doc false
  # The drain itself, once, whoever asks. Returns `%{hibernated: n, errors: [{cell, reason}], duration_ms: ms}`.
  def perform(config, trigger) do
    started = System.monotonic_time()
    instance = config.name
    if Registry.state(instance) == :ready, do: Registry.put_state(instance, :draining)

    :telemetry.execute([:atanor, :node, :drain, :start], %{system_time: System.system_time()}, %{
      instance: instance,
      node: node(),
      trigger: trigger
    })

    summary = bounded(config)

    if summary.errors != [] do
      Logger.warning(
        "atanor: drain left #{length(summary.errors)} cells to their leases: #{inspect(summary.errors, limit: 5)}"
      )
    end

    duration = System.monotonic_time() - started

    :telemetry.execute(
      [:atanor, :node, :drain],
      %{duration: duration, hibernated: summary.hibernated, errors: length(summary.errors)},
      %{instance: instance, node: node(), trigger: trigger, error_list: summary.errors}
    )

    Map.put(summary, :duration_ms, System.convert_time_unit(duration, :native, :millisecond))
  end

  # The jobs finish first: a job that runs while its cell is handed off would only fail on it.
  defp bounded(config) do
    task =
      Task.async(fn ->
        Jobs.Drain.run(config)
        {:ok, summary} = Alambique.drain(config.alambique, options(config.stop))
        summary
      end)

    case Task.yield(task, config.stop.shutdown_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, summary} -> summary
      {:exit, reason} -> %{hibernated: 0, errors: [{:drain, reason}]}
      nil -> %{hibernated: 0, errors: [{:drain, :deadline}]}
    end
  end

  defp options(stop), do: [timeout: stop.drain_timeout_ms, concurrency: stop.drain_concurrency]

  defp view(%{state: :idle}), do: %{state: :idle}
  defp view(%{state: :draining}), do: %{state: :draining}
  defp view(%{state: :drained, summary: summary}), do: Map.put(summary, :state, :drained)

  # What ends the node once the cells are handed back; only a drain that was asked for does it.
  defp finish(%{summary: summary, config: config}, exit) do
    status = if summary.errors == [], do: 0, else: 1

    case if(is_nil(exit), do: config.stop.exit, else: exit) do
      true -> System.stop(status)
      false -> :ok
      fun when is_function(fun, 1) -> fun.(status)
    end
  end
end
