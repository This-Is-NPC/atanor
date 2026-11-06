# Store round trips of the job path against SeaweedFS (design §12.13).
#
#   mise run bench:job-trips
#   mise run bench:job-trips -- --jobs 100 --latency 25,100 --concurrency 1,16
#   mise run bench:job-trips -- --raw        # also list every method and path seen
#
# Options (defaults): --jobs 100, --latency 25,100 (ms added to every store request),
# --concurrency 1,16 (`jobs.cell_concurrency`), --handler writes,none (the handler writes two rows, or
# nothing: the job path alone; both print a split), --enqueuers 16, --tick-ms 1000
# (`alarms.tick_ms`), --timeout-s 600 per case, --raw, --feed BATCHES/LINGER_MS,... (`alambique: [feed:
# [object_batches:, linger_ms:]]` per case; without it Atanor's defaults, 16/250).
#
# For each case one node runs over SeaweedFS behind a counting proxy that delays
# each request (bench/store_proxy.exs). N jobs are enqueued in one cell, due at
# at about one instant, so none runs while the others are being enqueued. Then the drain
# is timed from the first claim to the last finish. Requests are counted at the
# proxy, per phase: setup (cell wake, migrations), enqueue and drain.

Code.require_file("store_proxy.exs", __DIR__)

defmodule Bench.JobTrips do
  alias Atanor.{Alarms, Cell, Jobs, Registry}
  alias Atanor.Bench.StoreProxy
  alias Atanor.Dev.SeaweedFS
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  def main(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          jobs: :integer,
          latency: :string,
          concurrency: :string,
          enqueuers: :integer,
          tick_ms: :integer,
          timeout_s: :integer,
          raw: :boolean,
          handler: :string,
          trace: :boolean,
          feed: :string
        ]
      )

    opts = %{
      jobs: opts[:jobs] || 100,
      latency: ints(opts[:latency] || "25,100"),
      concurrency: ints(opts[:concurrency] || "1,16"),
      enqueuers: opts[:enqueuers] || 16,
      tick_ms: opts[:tick_ms] || 1_000,
      timeout_s: opts[:timeout_s] || 600,
      raw: opts[:raw] || false,
      handler: handlers(opts[:handler] || "writes,none"),
      trace: opts[:trace] || false,
      feed: feeds(opts[:feed])
    }

    IO.puts("jobs: #{opts.jobs}, enqueuers: #{opts.enqueuers}, alarms.tick_ms: #{opts.tick_ms}\n")

    for feed <- opts.feed, latency <- opts.latency, concurrency <- opts.concurrency do
      if feed, do: IO.puts("feed: #{inspect(feed)}")
      results = for handler <- opts.handler, do: {handler, run(opts, latency, concurrency, handler, feed)}
      if length(results) == 2, do: report_split(opts.jobs, latency, concurrency, results)
    end
  end

  defp feeds(nil), do: [nil]

  defp feeds(text) do
    for pair <- String.split(text, ",", trim: true) do
      [batches, linger] = String.split(pair, "/")
      [object_batches: String.to_integer(batches), linger_ms: String.to_integer(linger)]
    end
  end

  defp handlers(text) do
    for name <- String.split(text, ",", trim: true) do
      case name do
        "writes" -> :writes
        "none" -> :none
      end
    end
  end

  defp uptime,
    do: "uptime" |> System.cmd([]) |> elem(0) |> String.trim() |> String.replace(~r/^.*(load average)/, "\\1")

  defp ints(text), do: text |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)

  @doc false
  def on_job([:atanor, :job, :started], _, _, {events, times}) do
    :counters.add(events, 1, 1)
    :ets.insert_new(times, {:first_start, System.monotonic_time(:millisecond)})
  end

  def on_job([:atanor, :job, :finished], _, _, {events, times}) do
    :counters.add(events, 2, 1)
    :ets.insert(times, {:last_finish, System.monotonic_time(:millisecond)})
  end

  defp run(opts, latency, concurrency, handler_kind, feed) do
    store_config = SeaweedFS.config()
    {proxy, url} = StoreProxy.start(18343, latency)
    dir = Path.join(System.tmp_dir!(), "atanor-bench-trips-#{System.unique_integer([:positive])}")
    cell = {"jobs", "trips"}
    events = :counters.new(2, [])
    times = :ets.new(:times, [:public, :set])
    handler = "job-trips-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:atanor, :job, :started], [:atanor, :job, :finished]],
      &__MODULE__.on_job/4,
      {events, times}
    )

    node =
      Node.start(
        data_dir: dir,
        store: {Alambique.Store.S3, %{store_config | endpoint: url}},
        workers: [Manifests.jobs("jobs")],
        release: [hash_nifs: false],
        diagnostics: [breadcrumbs: :off],
        alarms: [tick_ms: opts.tick_ms],
        alambique: if(feed, do: [feed: feed], else: []),
        jobs: [cell_concurrency: concurrency, worker_concurrency: max(concurrency, 8), concurrency: 64]
      )

    try do
      StoreProxy.reset(proxy)
      {:ok, _} = Cell.query(node.name, cell, "SELECT 1")
      setup = StoreProxy.snapshot(proxy)

      # Due after the enqueue ends: each enqueue costs a few round trips.
      due = Alarms.now(Registry.config(node.name)) + 2_000 + div(opts.jobs, opts.enqueuers) * latency * 8
      StoreProxy.reset(proxy)
      enqueue_started = System.monotonic_time(:millisecond)

      # One entry in the alarm index is enough while later jobs are due after the first: the first
      # job goes alone, and the rest are due one millisecond apart, as jobs of a steady producer are.
      enqueue = fn i ->
        payload = if handler_kind == :none, do: "noop", else: "x#{i}"
        spec = %{kind: "bench", payload: payload, scheduled_at_ms: due + i}
        {:ok, _} = Jobs.enqueue_direct(node.name, "jobs", cell, spec)
      end

      enqueue.(0)

      1..(opts.jobs - 1)
      |> Task.async_stream(enqueue, max_concurrency: opts.enqueuers, timeout: :infinity)
      |> Stream.run()

      enqueue_ms = System.monotonic_time(:millisecond) - enqueue_started
      enqueued = StoreProxy.snapshot(proxy)

      if Alarms.now(Registry.config(node.name)) >= due,
        do: raise("the enqueue outlasted its due time: raise --enqueuers")

      Process.sleep(max(due - Alarms.now(Registry.config(node.name)), 0) + 50)
      StoreProxy.reset(proxy)
      tracer = if opts.trace, do: start_trace()
      deadline = System.monotonic_time(:second) + opts.timeout_s
      await(fn -> :counters.get(events, 2) >= opts.jobs end, deadline)
      drained = StoreProxy.snapshot(proxy)
      # Anything still in flight (alarm removal after the last finish) lands before this read.
      Process.sleep(2 * latency + 200)
      drained = Map.merge(drained, StoreProxy.snapshot(proxy), fn _, a, b -> max(a, b) end)

      [{_, first}] = :ets.lookup(times, :first_start)
      [{_, last}] = :ets.lookup(times, :last_finish)
      drain_ms = last - first
      {:ok, left, _} = Atanor.Store.list(Atanor.Store.handle(node.name), "alarms/", nil, 1_000)
      report(opts, latency, concurrency, handler_kind, enqueue_ms, drain_ms, setup, enqueued, drained)
      IO.puts("  alarm index entries left under alarms/ after the drain: #{length(left)}\n")
      if tracer, do: report_trace(stop_trace(tracer), opts.jobs)
      %{drained: drained, drain_ms: drain_ms}
    after
      :telemetry.detach(handler)
      Node.stop(node)
      StoreProxy.stop(proxy)
    end
  end

  defp report(opts, latency, concurrency, handler_kind, enqueue_ms, drain_ms, setup, enqueued, drained) do
    n = opts.jobs

    IO.puts("== store latency +#{latency} ms, cell_concurrency #{concurrency}, handler: #{handler_name(handler_kind)}")
    IO.puts("  host at the end of the case: #{uptime()}")
    IO.puts("  enqueue: #{n} jobs in #{enqueue_ms} ms (#{rate(n, enqueue_ms)} jobs/s, #{opts.enqueuers} at a time)")

    IO.puts(
      "  drain:   #{n} jobs in #{drain_ms} ms (#{rate(n, drain_ms)} jobs/s in one cell, #{Float.round(drain_ms / n, 1)} ms of cell time per job)"
    )

    for {phase, counts, per} <- [{"setup", setup, 1}, {"enqueue", enqueued, n}, {"drain", drained, n}] do
      IO.puts(
        "  requests, #{phase} (#{total(counts)} in all, #{fmt(total(counts) / per)} per #{if per == 1, do: "phase", else: "job"}):"
      )

      counts
      |> group()
      |> Enum.sort_by(fn {_, c} -> -c end)
      |> Enum.each(fn {kind, c} ->
        IO.puts("    #{String.pad_trailing(kind, 44)} #{String.pad_leading(Integer.to_string(c), 6)}  #{fmt(c / per)}")
      end)

      if opts.raw do
        IO.puts("    raw:")

        counts
        |> Enum.reduce(%{}, fn {{m, t}, c}, acc -> Map.update(acc, "#{m} #{shorten(t)}", c, &(&1 + c)) end)
        |> Enum.map(fn {line, c} -> {c, line} end)
        |> Enum.sort(:desc)
        |> Enum.each(fn {c, line} -> IO.puts("      #{String.pad_leading(Integer.to_string(c), 6)}  #{line}") end)
      end
    end

    IO.puts("")
  end

  defp handler_name(:writes), do: "writes (two rows in two transactions)"
  defp handler_name(:none), do: "none (writes nothing)"

  # The job path is what the jobs cost with a handler that writes nothing. The handler is what the
  # writing handler adds: its own transactions, their segments and their change feed objects. Both
  # come from separate runs of the same case, so the difference carries the noise of two runs.
  defp report_split(n, latency, concurrency, results) do
    writes = results[:writes]
    none = results[:none]
    kinds = Map.keys(group(writes.drained)) ++ Map.keys(group(none.drained))
    w = group(writes.drained)
    j = group(none.drained)

    IO.puts("== split, latency +#{latency} ms, cell_concurrency #{concurrency}: requests per job")

    IO.puts(
      "  #{String.pad_trailing("kind", 44)} #{String.pad_leading("total", 8)} #{String.pad_leading("job path", 9)} #{String.pad_leading("handler", 8)}"
    )

    for kind <- kinds |> Enum.uniq() |> Enum.sort_by(&(-Map.get(w, &1, 0))) do
      t = Map.get(w, kind, 0) / n
      p = Map.get(j, kind, 0) / n

      IO.puts(
        "  #{String.pad_trailing(kind, 44)} #{String.pad_leading(fmt(t), 8)} #{String.pad_leading(fmt(p), 9)} #{String.pad_leading(fmt(t - p), 8)}"
      )
    end

    t = total(writes.drained) / n
    p = total(none.drained) / n

    IO.puts(
      "  #{String.pad_trailing("all", 44)} #{String.pad_leading(fmt(t), 8)} #{String.pad_leading(fmt(p), 9)} #{String.pad_leading(fmt(t - p), 8)}"
    )

    IO.puts(
      "  jobs/s: #{rate(n, writes.drain_ms)} with writes, #{rate(n, none.drain_ms)} with none; host: #{uptime()}\n"
    )
  end

  defp total(counts), do: counts |> Map.values() |> Enum.sum()
  defp rate(n, ms), do: Float.round(n * 1000 / max(ms, 1), 1)
  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)

  defp group(counts) do
    Enum.reduce(counts, %{}, fn {{method, target}, c}, acc ->
      Map.update(acc, kind(method, target), c, &(&1 + c))
    end)
  end

  # `target` is the request target: `/bucket/prefix/key?query`.
  def kind(method, target) do
    [path | query] = String.split(target, "?", parts: 2)
    segments = path |> String.split("/", trim: true) |> tl()

    prefix =
      case query do
        [q] -> URI.decode_query(q)["prefix"]
        [] -> nil
      end

    classify(method, Enum.join(segments, "/"), prefix)
  end

  # `key` is the object key below the bucket; `prefix` is set for a list.
  def classify(method, key, prefix) do
    what = fn k ->
      cond do
        String.ends_with?(k, "/lease") ->
          "lease object"

        String.contains?(k, "/alarms/") or String.starts_with?(k, "alarms/") ->
          "@jobs/alarm index entry"

        String.contains?(k, "/feed/") ->
          "change feed object"

        String.ends_with?(k, ".ltx") ->
          "segment (.ltx)"

        String.contains?(k, "/workers/") ->
          "worker head/manifest"

        true ->
          "other (#{k |> String.split("/") |> Enum.take(2) |> Enum.reject(&(&1 =~ ~r/^t\d+$/)) |> Enum.join("/")})"
      end
    end

    cond do
      prefix -> "GET bucket root, list #{String.replace(prefix, ~r/^t\d+\//, "")}"
      true -> "#{method} #{what.(key)}"
    end
  end

  defp shorten(target), do: String.replace(target, ~r/\b[0-9a-f]{8,}\b|\d{10,}/, "…")

  # --trace: every call of the S3 client during the drain, with the Atanor and Alambique
  # functions on the caller's stack, to say which code issues which request.
  @s3 Alambique.Store.S3

  defp start_trace do
    me = self()
    pid = spawn_link(fn -> collect(me, []) end)
    spec = [{:_, [], [{:message, {:process_dump}}]}]

    for {f, a} <- [put: 5, get: 2, get_range: 4, head: 2, list: 4, delete: 2] do
      :erlang.trace_pattern({@s3, f, a}, spec, [:local])
    end

    :erlang.trace(:all, true, [:call, {:tracer, pid}])
    pid
  end

  defp stop_trace(pid) do
    :erlang.trace(:all, false, [:call])
    :erlang.trace_pattern({@s3, :_, :_}, false, [:local])
    send(pid, :stop)
    receive do: ({:traced, calls} -> calls)
  end

  defp collect(parent, calls) do
    receive do
      {:trace, _pid, :call, {@s3, f, args}, dump} -> collect(parent, [{f, args, dump} | calls])
      :stop -> send(parent, {:traced, calls})
      _ -> collect(parent, calls)
    end
  end

  defp report_trace(calls, jobs) do
    IO.puts("  call chains of the drain (innermost first; Atanor and Alambique frames only):")

    calls
    |> Enum.map(fn {f, args, dump} -> {trace_kind(f, args), chain(dump)} end)
    |> Enum.frequencies()
    |> Enum.group_by(fn {{kind, _}, _} -> kind end)
    |> Enum.sort_by(fn {_, l} -> -(l |> Enum.map(&elem(&1, 1)) |> Enum.sum()) end)
    |> Enum.each(fn {kind, chains} ->
      IO.puts(
        "    #{kind}: #{chains |> Enum.map(&elem(&1, 1)) |> Enum.sum()} (#{fmt(Enum.sum(Enum.map(chains, &elem(&1, 1))) / jobs)} per job)"
      )

      for {{_, chain}, n} <- Enum.sort_by(chains, fn {_, n} -> -n end) |> Enum.take(5) do
        IO.puts("      #{String.pad_leading(Integer.to_string(n), 5)}  #{chain}")
      end
    end)

    IO.puts("")
  end

  defp trace_kind(:list, [_cfg, prefix | _]), do: classify("GET", "", prefix)

  defp trace_kind(f, [_cfg, key | _]) do
    method = %{put: "PUT", get: "GET", get_range: "GET", head: "HEAD", delete: "DELETE"}[f]
    classify(method, key, nil)
  end

  # The stack in `process_dump` has lines such as `Return addr 0x… ('Elixir.Atanor.Jobs':run/3 + 52)`.
  defp chain(dump) do
    ~r/Return addr 0x[0-9a-f]+ \('?Elixir\.((?:Atanor|Alambique)[^':\s]*)'?:('[^']*'|[^\s\/]+)\/(\d+) \+/
    |> Regex.scan(dump)
    |> Enum.map(fn [_, m, f, a] -> {m, "#{m}.#{String.trim(f, "'")}/#{a}"} end)
    |> Enum.reject(fn {m, _} -> m in ["Alambique.Store.S3", "Alambique.Store.Guard", "Atanor.Store"] end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.dedup()
    |> Enum.take(7)
    |> Enum.join(" < ")
  end

  defp await(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:second) > deadline -> raise("bench timed out")
      true -> Process.sleep(50) && await(fun, deadline)
    end
  end
end

Bench.JobTrips.main(System.argv())
