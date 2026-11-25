# Memory pressure with and without the idle page-cache shrink of Alambique.
#
#   mise run bench:idle-cache -- off                 # defaults below
#   mise run bench:idle-cache -- on 1500 15000 300   # mode, cells, call period ms, duration s
#
# Arguments, in order (defaults): MODE `off` | `on` (`on` sets `awake: [idle_cache_after_ms:]`), CELLS 1500,
# PERIOD_MS 15000 (each cell is called once per period: choose it between the shrink delay and
# `idle_timeout_ms`), DURATION_S 300, IDLE_TIMEOUT_MS 60000, CLIENTS 64, SHRINK_MS 5000
# (`idle_cache_after_ms` of `on`). Environment of scripts/bench-idle-cache: LIMIT (cgroup MemoryMax,
# default 1200M) and TIMEOUT_S (default 900).
#
# One node over the in-memory store, run inside a systemd scope whose memory limit is the node's
# (`memory: [limit_bytes:]` read from the scope's `memory.max`). Phase 1 wakes every cell with one request,
# phase 2 calls each cell once per period, spread evenly (every request appends a row, as the counter
# worker does). A line every 10 s; the summary and a `RESULT` JSON line follow. Rates exclude phase 1.
# Wakes are `Atanor.Admission.wakes/1`, hibernations under pressure are `Atanor.Pressure.stats/1`.
# The node's own awake budget (`awake: [max_bytes:]`, derived) may also hibernate cells: those show as wakes only.

Code.require_file("load.exs", __DIR__)

defmodule Bench.IdleCache do
  alias Atanor.Bench.Load
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @window_s 10

  def main(argv) do
    [mode, cells, period, duration, idle, clients, shrink] =
      argv ++ Enum.drop(["off", "1500", "15000", "300", "60000", "64", "5000"], length(argv))

    mode in ["off", "on"] or raise "mode must be off or on, got #{mode}"

    [cells, period, duration, idle, clients, shrink] =
      Enum.map([cells, period, duration, idle, clients, shrink], &String.to_integer/1)

    run(%{mode: mode, cells: cells, period: period, duration: duration, idle: idle, clients: clients, shrink: shrink})
  end

  defp run(o) do
    {limit, current, stat} = cgroup()
    dir = Path.join(System.tmp_dir!(), "atanor-bench-idle-cache-#{System.unique_integer([:positive])}")
    awake = if o.mode == "on", do: [idle_cache_after_ms: o.shrink], else: []

    node =
      Node.start(
        data_dir: dir,
        memory: [limit_bytes: limit, current_path: current, stat_path: stat],
        alambique: [idle_timeout_ms: o.idle, lease_ttl_ms: 60_000, awake: awake]
      )

    try do
      {:ok, _} = Node.deploy(node, Manifests.counter("counter"))
      pressure = Atanor.Pressure.stats(node.name) || raise "the node does not watch its working set"
      cells = Module.concat(node.name, Cells)
      memory = %{current_path: current, stat_path: stat}
      IO.puts("machine: #{Load.machine()}")

      IO.puts(
        "mode #{o.mode}, #{o.cells} cells, period #{o.period} ms, #{o.duration} s, limit #{mb(limit)} MB, hibernate mark #{mb(pressure.hibernate_at_bytes)} MB\n"
      )

      IO.puts("   t s  awake  ws MB  hibernated  wakes   ok  failed  p50 ms  p99 ms")

      request = fn i -> {"POST", "/c/cell-#{i}", [], "#{i}"} end
      wake = Load.run(node.port, o.clients, {:requests, o.cells}, request)
      IO.puts("wake phase: #{o.cells} cells in #{Float.round(wake.seconds, 1)} s, #{wake.errors} failed")

      samples = :ets.new(:samples, [:public, :duplicate_bag])
      sampler = spawn_link(fn -> sample(samples, memory, cells) end)
      base = %{hib: Atanor.Pressure.stats(node.name).hibernated, wakes: Atanor.Admission.wakes(node.name)}
      started = System.monotonic_time(:millisecond)
      per_window = div(o.cells * @window_s * 1000, o.period)

      windows =
        for w <- 0..(div(o.duration, @window_s) - 1) do
          offset = w * per_window

          pace = fn i ->
            k = offset + i
            due = started + div(k * o.period, o.cells)
            Process.sleep(max(due - System.monotonic_time(:millisecond), 0))
            {"POST", "/c/cell-#{rem(k, o.cells)}", [], "#{k}"}
          end

          r = Load.run(node.port, o.clients, {:requests, per_window}, pace)
          line(node, cells, memory, started, r)
          r
        end

      Process.unlink(sampler)
      Process.exit(sampler, :kill)
      summary(o, node, limit, pressure, base, samples, windows, started)
    after
      Node.stop(node)
    end
  end

  defp line(node, cells, memory, started, r) do
    {:ok, ws} = Atanor.Memory.working_set(memory)
    t = round((System.monotonic_time(:millisecond) - started) / 1000)

    IO.puts(
      :io_lib.format("~5B  ~5B  ~5B  ~10B  ~5B  ~4B  ~6B  ~6s  ~6s", [
        t,
        awake(cells),
        mb(ws),
        Atanor.Pressure.stats(node.name).hibernated,
        Atanor.Admission.wakes(node.name),
        r.count - r.errors,
        r.errors,
        "#{r.p50}",
        "#{r.p99}"
      ])
    )
  end

  defp summary(o, node, limit, pressure, base, samples, windows, started) do
    minutes = (System.monotonic_time(:millisecond) - started) / 60_000
    hib = Atanor.Pressure.stats(node.name).hibernated - base.hib
    wakes = Atanor.Admission.wakes(node.name) - base.wakes
    ws = for {:ws, v} <- :ets.tab2list(samples), do: v
    awake = for {:awake, v} <- :ets.tab2list(samples), do: v
    ok = windows |> Enum.map(&(&1.count - &1.errors)) |> Enum.sum()
    failed = windows |> Enum.map(& &1.errors) |> Enum.sum()

    result = %{
      mode: o.mode,
      cells: o.cells,
      period_ms: o.period,
      duration_s: o.duration,
      limit_mb: mb(limit),
      hibernate_mark_mb: mb(pressure.hibernate_at_bytes),
      minutes: Float.round(minutes, 2),
      hibernated_per_min: Float.round(hib / minutes, 2),
      wakes_per_min: Float.round(wakes / minutes, 2),
      ws_mean_mb: Float.round(Enum.sum(ws) / max(length(ws), 1) / 1_048_576, 1),
      ws_max_mb: mb(Enum.max(ws, fn -> 0 end)),
      awake_mean: Float.round(Enum.sum(awake) / max(length(awake), 1), 1),
      ok: ok,
      failed: failed
    }

    IO.puts(
      "\nsummary (steady phase, #{result.minutes} min): pressure hibernations #{result.hibernated_per_min}/min, wakes #{result.wakes_per_min}/min"
    )

    IO.puts(
      "working set mean #{result.ws_mean_mb} MB, max #{result.ws_max_mb} MB of #{result.limit_mb} MB; awake cells mean #{result.awake_mean}; requests ok #{ok}, failed #{failed}"
    )

    IO.puts("RESULT " <> Jason.encode!(result))
  end

  # The working set and the awake cells every second.
  defp sample(table, memory, cells) do
    with {:ok, ws} <- Atanor.Memory.working_set(memory), do: :ets.insert(table, {:ws, ws})
    :ets.insert(table, {:awake, awake(cells)})
    Process.sleep(1_000)
    sample(table, memory, cells)
  end

  defp awake(cells), do: Alambique.cells(cells, limit: 1).count
  defp mb(bytes), do: round(bytes / 1_048_576)

  # The scope's own cgroup: its limit is the node's.
  defp cgroup do
    ["0::" <> path] =
      "/proc/self/cgroup"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "0::"))

    dir = "/sys/fs/cgroup" <> path

    limit =
      case dir |> Path.join("memory.max") |> File.read() do
        {:ok, text} -> Integer.parse(String.trim(text))
        _ -> :error
      end

    case limit do
      {bytes, ""} -> {bytes, Path.join(dir, "memory.current"), Path.join(dir, "memory.stat")}
      _ -> raise "cgroup #{dir} has no memory limit: run this through scripts/bench-idle-cache (systemd-run scope)"
    end
  end
end

Bench.IdleCache.main(System.argv())
