defmodule Atanor.Admission do
  @moduledoc """
  Admission control of the HTTP ingress (design §7.1): a node refuses with 503
  `overloaded` before it dies of memory.

  Two gates, checked first in `Atanor.HTTP.call/2`:

    * the memory gate refuses while the working set of the cgroup (`memory.current` minus the
      `inactive_file` of `memory.stat`, so reclaimable page cache never counts) is at least
      `memory: [refuse_fraction:]` of the limit, and resumes below that fraction minus 5 points;
    * the in-flight gate refuses at once when `http: [max_in_flight:]` requests are being served.

  `step/2` is the pure model (state and event to decision), which the property tests check. The node runs
  it as a sampler process, which reads the cgroup every `memory: [sample_ms:]` and publishes the verdict
  in an `:atomics`, so a request pays two reads and an ETS insert.

  A request is an ETS row keyed by its process: the in-flight count is the table size. A handler that is
  killed does not run `after`, so the sampler also drops the rows of dead processes on every tick.

  A sample older than 10 sample periods is ignored (the gate fails open). A dead sampler restarts the
  node (the supervisor is `one_for_all`), and a live one that stalls under CPU starvation must not refuse
  forever on a stale reading; the in-flight gate still bounds the node then.
  """
  use GenServer

  require Logger

  alias Atanor.Memory

  @hysteresis 0.05
  @stale_periods 10

  @refused_memory 1
  @refused_in_flight 2
  @working_set 3
  @refusing 4
  @sampled_at 5

  @doc "The gap, as a fraction of the limit, between the refuse and the resume marks."
  def hysteresis, do: @hysteresis

  ## Pure model

  @type state :: %{
          max_in_flight: pos_integer,
          refuse_at: number | nil,
          resume_at: number | nil,
          in_flight: non_neg_integer,
          refusing: boolean,
          working_set: non_neg_integer
        }
  @type event :: {:sample, non_neg_integer} | :enter | :leave
  @type decision :: :ok | :admit | {:refuse, :memory | :in_flight}

  @doc "The state of a node. `limit` is the memory limit in bytes, `nil` when the memory gate is off."
  @spec new(pos_integer | nil, number | nil, pos_integer) :: state
  def new(limit, refuse_fraction, max_in_flight) do
    {refuse_at, resume_at} =
      if limit && refuse_fraction,
        do: {limit * refuse_fraction, limit * (refuse_fraction - @hysteresis)},
        else: {nil, nil}

    %{
      max_in_flight: max_in_flight,
      refuse_at: refuse_at,
      resume_at: resume_at,
      in_flight: 0,
      refusing: false,
      working_set: 0
    }
  end

  @doc "One event: a sample of the working set, a request that enters, or one that leaves."
  @spec step(state, event) :: {decision, state}
  def step(%{refuse_at: nil} = state, {:sample, bytes}), do: {:ok, %{state | working_set: bytes}}

  def step(state, {:sample, bytes}) do
    refusing =
      cond do
        bytes >= state.refuse_at -> true
        bytes < state.resume_at -> false
        true -> state.refusing
      end

    {:ok, %{state | working_set: bytes, refusing: refusing}}
  end

  def step(%{refusing: true} = state, :enter), do: {{:refuse, :memory}, state}

  def step(%{in_flight: n, max_in_flight: max} = state, :enter) when n >= max, do: {{:refuse, :in_flight}, state}

  def step(state, :enter), do: {:admit, %{state | in_flight: state.in_flight + 1}}

  def step(state, :leave), do: {:ok, %{state | in_flight: max(state.in_flight - 1, 0)}}

  ## Ingress

  @doc false
  @spec enter(atom) :: :ok | {:refuse, :memory | :in_flight}
  def enter(name) do
    handle = handle(name)

    if refusing?(handle) do
      :atomics.add(handle.counters, @refused_memory, 1)
      {:refuse, :memory}
    else
      # A row that exists is the same process entering again: it holds one slot.
      if :ets.insert_new(handle.table, {self()}) and :ets.info(handle.table, :size) > handle.max_in_flight do
        :ets.delete(handle.table, self())
        :atomics.add(handle.counters, @refused_in_flight, 1)
        {:refuse, :in_flight}
      else
        :ok
      end
    end
  end

  @doc false
  @spec leave(atom) :: :ok
  def leave(name) do
    :ets.delete(handle(name).table, self())
    :ok
  end

  defp refusing?(%{memory: false}), do: false

  defp refusing?(%{counters: counters, stale_ms: stale_ms}) do
    :atomics.get(counters, @refusing) == 1 and
      System.monotonic_time(:millisecond) - :atomics.get(counters, @sampled_at) <= stale_ms
  end

  defp handle(name), do: :persistent_term.get({__MODULE__, name})

  @doc """
  What the admission of a running node has done: the requests in flight now, the refusals by reason, the
  last working set and the limit it is judged against (`nil` when the memory gate is off), and whether the
  gate is refusing now.
  """
  @spec stats(atom) :: map
  def stats(name) do
    handle = handle(name)
    counters = handle.counters

    %{
      in_flight: :ets.info(handle.table, :size),
      max_in_flight: handle.max_in_flight,
      refused: %{memory: :atomics.get(counters, @refused_memory), in_flight: :atomics.get(counters, @refused_in_flight)},
      working_set_bytes: if(handle.memory, do: :atomics.get(counters, @working_set)),
      limit_bytes: handle.limit,
      refuse_at_bytes: handle.memory && trunc(handle.model.refuse_at),
      refusing: refusing?(handle)
    }
  end

  ## Sampler

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    {limit, source} = Memory.limit(config.memory)
    fraction = config.memory.refuse_fraction
    memory? = not is_nil(limit) and not is_nil(fraction)
    model = new(limit, fraction, config.http.max_in_flight)

    handle = %{
      table: :ets.new(__MODULE__, [:set, :public, write_concurrency: true]),
      counters: :atomics.new(5, []),
      max_in_flight: config.http.max_in_flight,
      memory: memory?,
      limit: limit,
      model: model,
      stale_ms: @stale_periods * config.memory.sample_ms
    }

    :persistent_term.put({__MODULE__, config.name}, handle)

    if memory?,
      do:
        Logger.info(
          "atanor: refusing requests at #{trunc(model.refuse_at)} bytes of working set (#{source} limit #{limit})"
        )

    state = %{name: config.name, handle: handle, model: model, memory: config.memory}
    {:ok, tick(state, false)}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state, true)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{name: name}), do: :persistent_term.erase({__MODULE__, name})

  defp tick(%{handle: handle} = state, sweep?) do
    if sweep?, do: sweep(handle.table)
    Process.send_after(self(), :tick, state.memory.sample_ms)
    if handle.memory, do: sample(state), else: state
  end

  defp sample(%{handle: %{counters: counters}, model: model, memory: memory} = state) do
    case working_set(memory) do
      {:ok, bytes} ->
        {:ok, model} = step(model, {:sample, bytes})
        :atomics.put(counters, @working_set, bytes)
        :atomics.put(counters, @refusing, if(model.refusing, do: 1, else: 0))
        :atomics.put(counters, @sampled_at, System.monotonic_time(:millisecond))
        %{state | model: model}

      :error ->
        state
    end
  end

  # Rows of killed handlers: their `after` did not run.
  defp sweep(table) do
    for [pid] <- :ets.match(table, {:"$1"}), not Process.alive?(pid), do: :ets.delete(table, pid)
    :ok
  end

  # The working set: usage minus the file cache the kernel can drop. Without `memory.stat` all usage counts.
  defp working_set(%{current_path: current_path, stat_path: stat_path}) do
    with {:ok, text} <- File.read(current_path),
         {current, _} <- Integer.parse(text) do
      {:ok, max(current - inactive_file(stat_path), 0)}
    else
      _ -> :error
    end
  end

  defp inactive_file(path) do
    with {:ok, text} <- File.read(path),
         [_, bytes] <- Regex.run(~r/^inactive_file (\d+)$/m, text) do
      String.to_integer(bytes)
    else
      _ -> 0
    end
  end
end
