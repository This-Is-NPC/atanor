# What the idle feed cleanup costs per idle cell: store requests, bytes put and TXIDs.
#
#   mise run bench:idle-cleanup                       # 200 cells, both modes
#   mise run bench:idle-cleanup -- 500 idle_or_write 6
#
# Arguments (defaults): CELLS 200, CLEANUP `idle_or_write,in_write` (modes run one after the other; `feed:
# [cleanup:]`), WAIT_S 5 (idle window; the cleanup runs after `cleanup_after_ms`, 2000 here, and
# `idle_timeout_ms` is 60000 so the cells stay awake). TIMEOUT_S bounds the run in scripts/bench-idle-cleanup.
#
# One node per mode over the in-memory store behind a counting wrapper, with no added latency: trips are
# counted, not timed. Each cell gets one row, then `Alambique.position/3` (which uploads what waits, so the
# publication is done before the window). The window starts after that and holds only idle time; requests
# and bytes are counted in it, and each cell's TXID before and after. The `in_write` run is the floor
# (background polls of the node); the cost of the cleanup is the difference.

Code.require_file("load.exs", __DIR__)

defmodule Bench.IdleCleanup.Store do
  @behaviour Alambique.Store

  @kinds [:put, :get, :head, :get_range, :list, :delete]

  def wrap({module, config}), do: {__MODULE__, {module, config, :counters.new(length(@kinds) + 1, [])}}

  def reset({__MODULE__, {_, _, c}}), do: for(i <- 1..(length(@kinds) + 1), do: :counters.put(c, i, 0))

  def counts({__MODULE__, {_, _, c}}) do
    @kinds
    |> Enum.with_index(1)
    |> Map.new(fn {kind, i} -> {kind, :counters.get(c, i)} end)
    |> Map.put(:put_bytes, :counters.get(c, length(@kinds) + 1))
  end

  defp count(c, kind), do: :counters.add(c, Enum.find_index(@kinds, &(&1 == kind)) + 1, 1)

  @impl true
  def put({m, c, n}, key, body, condition, meta) do
    count(n, :put)
    :counters.add(n, length(@kinds) + 1, IO.iodata_length(body))
    m.put(c, key, body, condition, meta)
  end

  @impl true
  def get({m, c, n}, key), do: count(n, :get) && m.get(c, key)
  @impl true
  def head({m, c, n}, key), do: count(n, :head) && m.head(c, key)
  @impl true
  def get_range({m, c, n}, key, offset, length), do: count(n, :get_range) && m.get_range(c, key, offset, length)
  @impl true
  def list({m, c, n}, prefix, start_after, limit), do: count(n, :list) && m.list(c, prefix, start_after, limit)
  @impl true
  def delete({m, c, n}, key), do: count(n, :delete) && m.delete(c, key)
end

defmodule Bench.IdleCleanup do
  alias AlambiqueTestkit.MemoryStore
  alias Atanor.Bench.Load
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node
  alias Bench.IdleCleanup.Store

  @cleanup_after_ms 2_000

  def main(argv) do
    [cells, modes, wait] = argv ++ Enum.drop(["200", "idle_or_write,in_write", "5"], length(argv))
    modes = for m <- String.split(modes, ","), do: Map.fetch!(%{"idle_or_write" => :idle_or_write, "in_write" => :in_write}, m)
    IO.puts("machine: #{Load.machine()}\n")
    results = for mode <- modes, do: run(mode, String.to_integer(cells), String.to_integer(wait))
    IO.puts("RESULT " <> Jason.encode!(results))
  end

  defp run(mode, count, wait_s) do
    server = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, _} = MemoryStore.start_link(name: server)
    store = Store.wrap({MemoryStore, MemoryStore.config(server)})
    dir = Path.join(System.tmp_dir!(), "atanor-bench-idle-cleanup-#{System.unique_integer([:positive])}")

    node =
      Node.start(
        data_dir: dir,
        store: store,
        alambique: [
          idle_timeout_ms: 60_000,
          lease_ttl_ms: 60_000,
          feed: [cleanup: mode, cleanup_after_ms: @cleanup_after_ms]
        ]
      )

    try do
      {:ok, _} = Node.deploy(node, Manifests.counter("counter"))
      Load.run(node.port, 32, {:requests, count}, fn i -> {"POST", "/c/cell-#{i}", [], "#{i}"} end)
      before = txids(node, count)
      Store.reset(store)
      Process.sleep(wait_s * 1000)
      counts = Store.counts(store)
      after_ = txids(node, count)
      awake = Alambique.cells(Module.concat(node.name, Cells), limit: 1).count
      added = Enum.zip(before, after_) |> Enum.map(fn {b, a} -> a - b end)
      per = fn n -> Float.round(n / count, 2) end

      result = %{
        cleanup: mode,
        cells: count,
        window_s: wait_s,
        awake_after: awake,
        per_cell: counts |> Map.new(fn {k, v} -> {k, per.(v)} end) |> Map.put(:txids, per.(Enum.sum(added))),
        total: counts,
        txids_max: Enum.max(added),
        txids_min: Enum.min(added)
      }

      IO.puts("cleanup: #{mode}, #{count} cells, #{wait_s} s idle, #{awake} still awake")
      IO.puts("  per cell: " <> Enum.map_join(result.per_cell, ", ", fn {k, v} -> "#{k} #{v}" end))
      IO.puts("  txids added per cell: min #{result.txids_min}, max #{result.txids_max}\n")
      result
    after
      Node.stop(node)
      GenServer.stop(server)
    end
  end

  # The TXID of every cell's chain; position is a call, so it is taken outside the window.
  defp txids(node, count) do
    0..(count - 1)
    |> Task.async_stream(
      fn i ->
        {:ok, %{txid: txid}} = Atanor.Cell.position(node.name, {"log", "cell-#{i}"})
        txid
      end,
      max_concurrency: 32,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, txid} -> txid end)
  end
end

Bench.IdleCleanup.main(System.argv())
