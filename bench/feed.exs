# Time for a change feed subscriber to receive a burst of changes (design §12.14, §16.2).
#
#   mise run bench:feed              # 2 000 writes to 2 000 cells
#   mise run bench:feed -- 5000 50   # writes, then feed.poll_ms
#   mise run bench:feed -- 2000 100 16 50   # then the feed's object_batches and linger_ms (Atanor's defaults, 16 and 250, without them)
#
# One node over the in-memory store with the default `feed.page_size` of 100 objects. Every write is
# one commit and so one feed object. The subscriber starts before the writes; the figures are the
# time from the first write to the first and to the last change received (the first arrives after the
# feed's own settling time, which no tailer setting changes). Then 20 lone writes, 300 ms apart, give
# the delay from a write to its delivery (what `linger_ms` adds to an idle cell).

defmodule Bench.Feed do
  alias Atanor.{Env, Registry}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  # The smallest window Atanor accepts for the grouping: `linger_ms` is at most a tenth of it. Without
  # `--feed` the linger is Atanor's 250 ms, so the window is 2 500 ms.
  defp window_ms(feed) do
    if Keyword.get(feed, :object_batches, 16) == 1,
      do: 1,
      else: max(1, Keyword.get(feed, :linger_ms, 250) * 10)
  end

  def run(count, poll_ms, feed) do
    manifest =
      Manifests.probe("feed",
        module: Atanor.Test.FeedWorker,
        cells: %{"notes" => [[1, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"]]}
      )

    node =
      Node.start(
        data_dir: Path.join(System.tmp_dir!(), "atanor-bench-feed-#{System.unique_integer([:positive])}"),
        workers: [manifest],
        feed: [poll_ms: poll_ms],
        alambique: [feed: Keyword.merge([window_ms: window_ms(feed)], feed)]
      )

    try do
      {:ok, deployment} = Registry.deployment(node.name, "feed")
      env = Env.new(node.name, deployment)
      reads = :counters.new(2, [])

      :telemetry.attach(
        "bench-feed",
        [:atanor, :feed, :read],
        fn _event, m, _meta, _ ->
          :counters.add(reads, 1, 1) &&
            :counters.add(reads, 2, System.convert_time_unit(m.duration, :native, :microsecond))
        end,
        nil
      )

      {:ok, _ref} = Env.subscribe(env, "notes", from: :now)
      IO.puts("load average: #{File.read!("/proc/loadavg") |> String.split() |> Enum.take(3) |> Enum.join(" ")}")
      started = System.monotonic_time(:millisecond)

      1..count
      |> Task.async_stream(
        fn i -> {:ok, _} = Env.execute(env, {"notes", "c#{i}"}, "INSERT INTO notes (body) VALUES (?)", ["x"]) end,
        max_concurrency: 32,
        timeout: :infinity
      )
      |> Stream.run()

      written = System.monotonic_time(:millisecond)
      {received, first} = receive_all(count, started + 300_000)
      done = System.monotonic_time(:millisecond)

      IO.puts(
        "feed: #{received} of #{count} changes, poll_ms #{poll_ms}; writes #{written - started} ms, " <>
          "first change #{first - started} ms, last change #{done - started} ms after the first write, " <>
          "#{done - first} ms between them " <>
          "(#{round(received * 1000 / (done - started))} changes/s); #{:counters.get(reads, 1)} reads, " <>
          "#{div(:counters.get(reads, 2), max(:counters.get(reads, 1), 1))} us each"
      )

      lone_delays(env, 20)
    after
      Node.stop(node)
    end
  end

  # Each row carries the time of its write; the writes do not wait for their delivery (it takes
  # the feed's settling time), so the 20 deliveries overlap.
  defp lone_delays(env, n) do
    flush()

    for i <- 1..n do
      Process.sleep(300)
      body = Integer.to_string(System.monotonic_time(:millisecond))
      {:ok, _} = Env.execute(env, {"notes", "lone#{i}"}, "INSERT INTO notes (body) VALUES (?)", [body])
    end

    delays = n |> collect_delays([]) |> Enum.sort()

    IO.puts(
      "lone writes: delay to delivery median #{Enum.at(delays, div(n, 2))} ms, " <>
        "p90 #{Enum.at(delays, div(n * 9, 10))} ms, max #{List.last(delays)} ms"
    )
  end

  defp collect_delays(0, delays), do: delays

  defp collect_delays(left, delays) do
    receive do
      {:atanor_changes, _ref, changes, _position} ->
        now = System.monotonic_time(:millisecond)
        got = for %{row: %{"body" => body}} <- changes, do: now - String.to_integer(body)
        collect_delays(left - length(got), got ++ delays)
    after
      60_000 -> raise "lone writes were not delivered"
    end
  end

  defp flush do
    receive do
      {:atanor_changes, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp receive_all(count, deadline, received \\ 0, first \\ nil) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:atanor_changes, _ref, changes, _position} ->
        received = received + length(changes)
        first = first || System.monotonic_time(:millisecond)
        if received >= count, do: {received, first}, else: receive_all(count, deadline, received, first)
    after
      wait -> {received, first}
    end
  end
end

args = Enum.map(System.argv(), &String.to_integer/1)
count = Enum.at(args, 0, 2000)
poll_ms = Enum.at(args, 1, 1000)
grouping = Enum.drop(args, 2)

feed =
  case grouping do
    [batches, linger_ms] -> [object_batches: batches, linger_ms: linger_ms]
    _ -> []
  end

Bench.Feed.run(count, poll_ms, feed)
