defmodule Atanor.Wasm.Cache do
  @moduledoc """
  Compiled components of one instance by component hash (design §14).

  A hit in memory is an ETS read. A miss compiles once however many callers
  wait, or loads the compiled code that an earlier compile left under
  `<data_dir>/wasm`. Entries stay until the instance stops.
  """
  use GenServer

  alias Atanor.Wasm.Native

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: server(config.name)]]}}
  end

  @doc """
  The compiled component of `bytes`, whose SHA-256 (hex) is `hash`. The caller
  waits at most `timeout` ms (the node setting `:compile_timeout_ms`) for a
  compile; one that takes longer goes on in the background and is cached when
  it ends, since a native compile cannot be interrupted.
  """
  @spec fetch(atom, String.t(), binary, timeout) :: {:ok, reference} | {:error, String.t()}
  def fetch(instance, hash, bytes, timeout \\ Atanor.Wasm.settings().compile_timeout_ms) do
    case :ets.lookup(table(instance), hash) do
      [{_, compiled}] ->
        :telemetry.execute([:atanor, :wasm, :load], %{duration: 0, bytes: byte_size(bytes)}, %{
          hash: hash,
          source: :memory
        })

        {:ok, compiled}

      [] ->
        try do
          GenServer.call(server(instance), {:fetch, hash, bytes}, timeout)
        catch
          :exit, {:timeout, _} -> {:error, "compile timed out after #{timeout} ms"}
        end
    end
  end

  defp server(instance), do: Module.concat(instance, WasmCache)
  defp table(instance), do: Module.concat(instance, WasmComponents)

  defp engine_settings do
    settings = Atanor.Wasm.settings()

    %{settings | cpu: Atom.to_string(settings.cpu)}
    |> Map.take([:threads, :queue, :tick_ms, :cpu, :pooling, :max_memory_bytes, :table_elements])
  end

  @impl true
  def init(config) do
    with :ok <- Native.configure(engine_settings()) do
      :ets.new(table(config.name), [:named_table, :set, :protected, read_concurrency: true])
      {:ok, %{table: table(config.name), dir: Path.join(config.data_dir, "wasm"), waiting: %{}, tasks: %{}}}
    else
      {:error, reason} -> {:stop, {:wasm_not_configured, reason}}
    end
  end

  @impl true
  def handle_call({:fetch, hash, bytes}, from, state) do
    case :ets.lookup(state.table, hash) do
      [{_, compiled}] ->
        {:reply, {:ok, compiled}, state}

      [] ->
        waiting = Map.update(state.waiting, hash, [from], &[from | &1])

        if Map.has_key?(state.waiting, hash) do
          {:noreply, %{state | waiting: waiting}}
        else
          dir = state.dir
          task = Task.async(fn -> load(bytes, dir, hash) end)
          {:noreply, %{state | waiting: waiting, tasks: Map.put(state.tasks, task.ref, hash)}}
        end
    end
  end

  @impl true
  def handle_info({ref, result}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {hash, tasks} = Map.pop(tasks, ref)
    {waiters, waiting} = Map.pop(state.waiting, hash)

    reply =
      case result do
        {:ok, compiled} ->
          :ets.insert(state.table, {hash, compiled})
          {:ok, compiled}

        error ->
          error
      end

    for from <- waiters, do: GenServer.reply(from, reply)
    {:noreply, %{state | tasks: tasks, waiting: waiting}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    {hash, tasks} = Map.pop(tasks, ref)
    {waiters, waiting} = Map.pop(state.waiting, hash)
    for from <- waiters, do: GenServer.reply(from, {:error, "compile crashed: #{inspect(reason)}"})
    {:noreply, %{state | tasks: tasks, waiting: waiting}}
  end

  defp load(bytes, dir, hash) do
    started = System.monotonic_time()

    case Native.compile(bytes, dir, hash) do
      {:ok, {compiled, source}} ->
        :telemetry.execute(
          [:atanor, :wasm, :load],
          %{duration: System.monotonic_time() - started, bytes: byte_size(bytes)},
          %{hash: hash, source: source}
        )

        {:ok, compiled}

      {:error, message} ->
        {:error, message}
    end
  end
end
