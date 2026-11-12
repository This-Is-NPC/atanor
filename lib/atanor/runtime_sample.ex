defmodule Atanor.RuntimeSample do
  @moduledoc false
  # What a node's memory is made of right now (`GET /runtime`, design §10): VM memory by type, the biggest ETS
  # tables and processes, the cgroup v2 counters and the native Wasm gauges. One bounded scan, no locks.

  @top_ets 5
  @top_processes 10
  @scan_cap 100_000
  @stat_keys ~w(anon file shmem sock slab kernel_stack inactive_file active_file)
  @event_keys ~w(oom oom_kill)

  @doc "The sample of node `name`. `cgroup_dir` is where `memory.current` and its siblings live."
  @spec sample(atom, Path.t()) :: map
  def sample(name, cgroup_dir) do
    infos = process_infos()

    %{
      memory: Map.new(:erlang.memory()),
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      run_queues: :erlang.statistics(:run_queue_lengths),
      ets: ets_top(),
      processes_scanned: length(infos),
      top_message_queue: top(infos, :message_queue_len),
      top_memory: top(infos, :memory),
      cgroup: cgroup(cgroup_dir),
      admission: Atanor.Admission.stats(name),
      wasm: wasm()
    }
  end

  defp ets_top do
    words = :erlang.system_info(:wordsize)

    :ets.all()
    |> Enum.flat_map(fn table ->
      case :ets.info(table, :memory) do
        size when is_integer(size) -> [%{name: inspect(:ets.info(table, :name)), bytes: size * words}]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.bytes, :desc)
    |> Enum.take(@top_ets)
  end

  # A process that died between the list and the call is skipped.
  defp process_infos do
    for pid <- Enum.take(Process.list(), @scan_cap),
        info = Process.info(pid, [:message_queue_len, :memory]),
        do: {pid, Map.new(info)}
  end

  @doc false
  def top(infos, key) do
    infos
    |> Enum.sort_by(fn {_pid, info} -> info[key] end, :desc)
    |> Stream.flat_map(fn {pid, info} ->
      case Process.info(pid, [:registered_name, :initial_call, :current_function]) do
        nil -> []
        details -> [describe(pid, info, Map.new(details))]
      end
    end)
    |> Enum.take(@top_processes)
  end

  defp describe(pid, info, details) do
    %{
      pid: inspect(pid),
      name: name(details[:registered_name]),
      initial_call: mfa(details[:initial_call]),
      current_function: mfa(details[:current_function]),
      message_queue_len: info.message_queue_len,
      memory: info.memory
    }
  end

  defp name(nil), do: nil
  defp name([]), do: nil
  defp name(name), do: inspect(name)

  defp mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp mfa(_), do: nil

  defp cgroup(dir) do
    stat = keyed(dir, "memory.stat")
    events = keyed(dir, "memory.events")

    %{
      memory_current: number(dir, "memory.current"),
      memory_max: number(dir, "memory.max"),
      stat: Map.new(@stat_keys, &{&1, stat[&1]}),
      events: Map.new(@event_keys, &{&1, events[&1]})
    }
  end

  # "max" (no limit) and a missing file are both null.
  defp number(dir, file) do
    with text when is_binary(text) <- read(dir, file),
         {value, ""} <- Integer.parse(String.trim(text)) do
      value
    else
      _ -> nil
    end
  end

  defp keyed(dir, file) do
    for line <- String.split(read(dir, file) || "", "\n", trim: true),
        [key, value] <- [String.split(line)],
        {number, ""} <- [Integer.parse(value)],
        into: %{},
        do: {key, number}
  end

  defp read(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  defp wasm do
    Atanor.Wasm.Stats.read()
  rescue
    _ -> nil
  end
end
