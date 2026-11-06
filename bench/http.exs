# HTTP requests per second and latency on one node (design §12.2).
#
#   mise run bench:http            # 5 seconds per case
#   mise run bench:http -- 10      # another duration
#
# A native worker and a WASM worker, each without and with a write to a cell
# (64 cells, so the writes are not serialized on one). One node over the
# in-memory store, 32 keep-alive clients on the same machine.

Code.require_file("load.exs", __DIR__)

# ATANOR_BENCH_POOLING=off maps WASM memory on demand instead of using the pooling allocator.
if System.get_env("ATANOR_BENCH_POOLING", "on") == "off", do: Application.put_env(:atanor, :wasm, pooling: false)

defmodule Bench do
  alias Atanor.Bench.Load
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @clients 32
  @cells 64

  def run(seconds) do
    diagnostics =
      case System.get_env("ATANOR_BENCH_BREADCRUMBS", "off") do
        "off" -> [breadcrumbs: :off]
        "durable" -> [breadcrumbs: :durable, settle_ms: 0]
        "all" -> [breadcrumbs: :all, settle_ms: 0]
      end

    node =
      Node.start(
        data_dir: Path.join(System.tmp_dir!(), "atanor-bench-http-#{System.unique_integer([:positive])}"),
        release: [hash_nifs: false],
        diagnostics: diagnostics
      )

    try do
      deploy(node)

      IO.puts(
        "machine: #{Load.machine()}\nclients: #{@clients}, #{seconds} s per case, cells per write case: #{@cells}\n"
      )

      cases = [
        {"native, no cell", fn _ -> {"GET", "/native/echo", [], ""} end},
        {"native, cell write", fn i -> {"POST", "/c/cell#{rem(i, @cells)}", [], "#{i}"} end},
        {"wasm, no cell", fn _ -> {"GET", "/hello/x", [], ""} end},
        {"wasm, cell write", &wasm_write/1}
      ]

      for {label, request} <- cases do
        Load.run(node.port, @clients, {:seconds, 1}, request)
        IO.puts(Load.row(label, Load.run(node.port, @clients, {:seconds, seconds}, request)))
      end
    after
      Node.stop(node)
    end
  end

  defp wasm_write(i) do
    headers = [{"x-op", "execute"}, {"x-ns", "notes"}, {"x-key", "cell#{rem(i, @cells)}"}, {"x-params", "#{i}"}]
    {"POST", "/wasmcell", headers, "INSERT INTO notes (body) VALUES (?)"}
  end

  defp deploy(node) do
    {:ok, _} = Node.deploy(node, Manifests.counter("counter"))

    {:ok, _} =
      Node.deploy(node, Manifests.probe("native", routes: [{"127.0.0.1", "/native"}]))

    Manifests.deploy_wasm(node, [
      Manifests.wasm("hello", "hello", routes: [{"127.0.0.1", "/hello"}]),
      Manifests.wasm("wasmcell", "cell",
        cells: %{"notes" => Manifests.notes_migrations()},
        routes: [{"127.0.0.1", "/wasmcell"}]
      )
    ])
  end
end

[seconds | _] = System.argv() ++ ["5"]
Bench.run(String.to_integer(seconds))
