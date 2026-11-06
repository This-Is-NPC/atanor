# Store requests of an idle node's time-driven polls (design §12.13, §12.14).
#
#   mise run bench:idle-polls             # 300 finished sweep operations, 10 s
#   mise run bench:idle-polls -- 1000 20  # operations, seconds
#
# One node over a counting wrapper of the in-memory store, with `sweeps.poll_ms` 500. The operations
# are finished records, which a sweep manager keeps for `sweeps.retention_ms`. The figure is store
# reads per sweep poll once the node is idle.

defmodule Bench.CountingStore do
  @behaviour Alambique.Store

  def wrap({module, config}), do: {__MODULE__, {module, config, :counters.new(2, [])}}
  def counts({__MODULE__, {_, _, counters}}), do: {:counters.get(counters, 1), :counters.get(counters, 2)}

  @impl true
  def put({m, c, _}, key, body, condition, meta), do: m.put(c, key, body, condition, meta)
  @impl true
  def get({m, c, n}, key), do: (:counters.add(n, 1, 1) && m.get(c, key))
  @impl true
  def head({m, c, _}, key), do: m.head(c, key)
  @impl true
  def get_range({m, c, _}, key, offset, length), do: m.get_range(c, key, offset, length)
  @impl true
  def list({m, c, n}, prefix, start_after, limit), do: (:counters.add(n, 2, 1) && m.list(c, prefix, start_after, limit))
  @impl true
  def delete({m, c, _}, key), do: m.delete(c, key)
end

defmodule Bench.IdlePolls do
  alias AlambiqueTestkit.MemoryStore
  alias AtanorTestkit.Node

  def run(operations, seconds) do
    server = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, _} = MemoryStore.start_link(name: server)
    store = Bench.CountingStore.wrap({MemoryStore, MemoryStore.config(server)})
    now = System.os_time(:millisecond)

    node =
      Node.start(
        data_dir: Path.join(System.tmp_dir!(), "atanor-bench-idle-#{System.unique_integer([:positive])}"),
        store: store,
        sweeps: [poll_ms: 500, max_records: max(operations, 1_000)]
      )

    try do
      for i <- 1..operations do
        id = "op#{String.pad_leading("#{i}", 6, "0")}"
        record = %{"id" => id, "state" => "done", "created_at_ms" => now, "updated_at_ms" => now}
        {:ok, _} = Atanor.Store.put(node.name, "operations/" <> id, Jason.encode!(record))
      end

      Process.sleep(2_000)
      {gets, lists} = Bench.CountingStore.counts(store)
      started = System.monotonic_time(:millisecond)
      Process.sleep(seconds * 1000)
      {gets2, lists2} = Bench.CountingStore.counts(store)
      elapsed = (System.monotonic_time(:millisecond) - started) / 1000
      polls = elapsed * 2

      IO.puts("load average: #{File.read!("/proc/loadavg") |> String.split() |> Enum.take(3) |> Enum.join(" ")}")

      IO.puts(
        "idle polls: #{operations} finished operations, #{Float.round(elapsed, 1)} s: " <>
          "#{round((gets2 - gets) / elapsed)} GET/s and #{Float.round((lists2 - lists) / elapsed, 1)} list/s " <>
          "(#{Float.round((gets2 - gets) / polls, 1)} GET per sweep poll)"
      )
    after
      Node.stop(node)
    end
  end
end

[operations, seconds] = (System.argv() ++ ["300", "10"]) |> Enum.take(2) |> Enum.map(&String.to_integer/1)
Bench.IdlePolls.run(operations, seconds)
