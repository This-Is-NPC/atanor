# Latency tail of one hot cell over a store with latency (design §8.13, §12.14).
#
#   mise run bench:hot-cell-tail            # 8 clients, 20 s, 25 ms per store request
#   mise run bench:hot-cell-tail -- 8 20 25 # clients, seconds, store latency in ms
#
# One node over a wrapper of the in-memory store that sleeps before each request. All clients write to
# one cell, so the node checks its lease about once per `routing.owner_check_ms`. The figures are
# requests per second and the latency tail. ATANOR_BENCH_OWNER_CHECK=off turns the lease check off, the
# upper bound of what a cheaper check can gain.

Code.require_file("load.exs", __DIR__)

defmodule Bench.SlowStore do
  @behaviour Alambique.Store

  def wrap({module, config}, ms), do: {__MODULE__, {module, config, ms}}

  @impl true
  def put({m, c, ms}, key, body, condition, meta), do: (Process.sleep(ms) && m.put(c, key, body, condition, meta))
  @impl true
  def get({m, c, ms}, key), do: (Process.sleep(ms) && m.get(c, key))
  @impl true
  def head({m, c, ms}, key), do: (Process.sleep(ms) && m.head(c, key))
  @impl true
  def get_range({m, c, ms}, key, offset, length), do: (Process.sleep(ms) && m.get_range(c, key, offset, length))
  @impl true
  def list({m, c, ms}, prefix, start_after, limit), do: (Process.sleep(ms) && m.list(c, prefix, start_after, limit))
  @impl true
  def delete({m, c, ms}, key), do: (Process.sleep(ms) && m.delete(c, key))
end

defmodule Bench.HotCellTail do
  alias AlambiqueTestkit.MemoryStore
  alias Atanor.Bench.Load
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  def run(clients, seconds, latency) do
    server = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, _} = MemoryStore.start_link(name: server)
    store = Bench.SlowStore.wrap({MemoryStore, MemoryStore.config(server)}, latency)

    node =
      Node.start(
        data_dir: Path.join(System.tmp_dir!(), "atanor-bench-tail-#{System.unique_integer([:positive])}"),
        store: store,
        release: [hash_nifs: false],
        diagnostics: [breadcrumbs: :off],
        routing: [owner_check: System.get_env("ATANOR_BENCH_OWNER_CHECK", "on") == "on"]
      )

    try do
      {:ok, _} = Node.deploy(node, Manifests.counter("counter"))
      request = fn i -> {"POST", "/c/hot", [], "#{i}"} end
      Load.run(node.port, clients, {:seconds, 2}, request)
      load = File.read!("/proc/loadavg") |> String.split() |> Enum.take(3) |> Enum.join(" ")
      r = Load.run(node.port, clients, {:seconds, seconds}, request)

      IO.puts(
        "hot cell, #{clients} clients, store latency #{latency} ms, load average #{load}: #{r.rps} req/s, " <>
          "p50 #{r.p50} ms, p99 #{r.p99} ms, p99.9 #{r.p999} ms, max #{r.max} ms, errors #{r.errors}/#{r.count}"
      )
    after
      Node.stop(node)
    end
  end
end

[clients, seconds, latency] = (System.argv() ++ ["8", "20", "25"]) |> Enum.take(3) |> Enum.map(&String.to_integer/1)
Bench.HotCellTail.run(clients, seconds, latency)
