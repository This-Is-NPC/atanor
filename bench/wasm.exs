# WASM workers on one node (design §12).
#
#   mise run bench:wasm            # 5 seconds per throughput case
#   mise run bench:wasm -- 10      # another duration
#
# Run once per CPU limit mode (epoch, fuel) by scripts/bench-wasm; set
# ATANOR_BENCH_CPU to run one. ATANOR_BENCH_POOLING=off maps memory on demand
# instead of using the pooling allocator. Measures cold compile, loading the compiled
# code from the disk cache, warm instantiation, requests per second (with the CPU
# time and context switches per request) for the
# hello guest over HTTP, and the time of a CPU-bound request.

[seconds | _] = System.argv() ++ ["5"]
seconds = String.to_integer(seconds)
cpu = String.to_atom(System.get_env("ATANOR_BENCH_CPU", "epoch"))

# Limits high enough not to interfere with the CPU-bound case.
pooling = System.get_env("ATANOR_BENCH_POOLING", "on") == "on"
Application.put_env(:atanor, :wasm, cpu: cpu, cpu_ms: 600_000, fuel: 1_000_000_000_000, pooling: pooling)

defmodule Bench do
  import Atanor.Test.WasmCase

  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  def ms(native), do: Float.round(System.convert_time_unit(native, :native, :nanosecond) / 1_000_000, 3)

  def first(event_name) do
    receive do
      {:telemetry, ^event_name, m, meta} -> {m, meta}
    after
      10_000 -> raise "no #{inspect(event_name)}"
    end
  end

  def flush do
    receive do
      {:telemetry, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  def deploy_hello(node) do
    Manifests.deploy_wasm(node, Manifests.wasm("hello", "hello", routes: [{"127.0.0.1", "/hello"}]))
  end

  def run(seconds, cpu) do
    dir = Path.join(System.tmp_dir!(), "atanor-bench-#{System.unique_integer([:positive])}")
    events = [[:atanor, :wasm, :load], [:atanor, :wasm, :invoke]]
    :telemetry.attach_many(:bench, events, &Atanor.Test.WasmCase.forward/4, self())

    {cold_load, cold_first} = start_measure(dir)
    {disk_load, disk_first} = start_measure(dir)

    node = Node.start(data_dir: dir)
    deploy_hello(node)
    flush()

    n = 2_000
    for _ <- 1..n, do: request(node, "hello")
    warm = for _ <- 1..n, do: elem(first([:atanor, :wasm, :invoke]), 0)
    warm_instantiate = ms((Enum.sum(Enum.map(warm, & &1.instantiate)) / n) |> round())
    warm_duration = ms((Enum.sum(Enum.map(warm, & &1.duration)) / n) |> round())
    flush()

    c0 = proc()
    rps = throughput(node, seconds)
    c1 = proc()

    IO.puts(
      "per request (VM and clients): cpu_us #{Float.round((c1.cpu - c0.cpu) * 10_000 / (rps * seconds), 1)} vol_cs #{Float.round((c1.vol - c0.vol) / (rps * seconds), 2)} invol_cs #{Float.round((c1.inv - c0.inv) / (rps * seconds), 2)}"
    )

    flush()

    work = for _ <- 1..5, do: elem(work_request(node), 0)
    vm = vm_memory()
    Node.stop(node)
    File.rm_rf!(dir)

    IO.puts("""
    cpu limit mode: #{cpu}
    machine: #{System.cmd("nproc", []) |> elem(0) |> String.trim()} logical processors, #{cpu_model()}
    guest: hello.wasm (#{File.stat!("test/fixtures/wasm/hello.wasm").size} bytes), threads #{Atanor.Wasm.settings().threads}
    cold compile (no cache):            #{cold_load} ms
    cold start, load from disk cache:   #{disk_load} ms
    first request after cold compile:   instantiate #{cold_first} ms
    first request after disk load:      instantiate #{disk_first} ms
    warm instantiation (mean of #{n}):   #{warm_instantiate} ms; whole request in the NIF path #{warm_duration} ms
    hello over HTTP (32 clients, #{seconds} s):  #{rps} requests/s
    VM address space / resident:        #{vm}
    CPU-bound request (200M iterations): #{Enum.map_join(work, ", ", &"#{Float.round(&1, 1)} ms")}; median #{work |> Enum.sort() |> Enum.at(2) |> Float.round(1)} ms
    """)
  end

  defp proc do
    {:ok, tasks} = File.ls("/proc/self/task")
    base = %{cpu: 0, vol: 0, inv: 0}

    Enum.reduce(tasks, base, fn t, acc ->
      st = File.read!("/proc/self/task/#{t}/status")

      f = fn k ->
        [_, v] = Regex.run(~r/#{k}:\s+(\d+)/, st)
        String.to_integer(v)
      end

      [_ | rest] = String.split(File.read!("/proc/self/task/#{t}/stat"), ") ")
      fields = String.split(hd(rest))
      ticks = String.to_integer(Enum.at(fields, 11)) + String.to_integer(Enum.at(fields, 12))

      %{
        cpu: acc.cpu + ticks,
        vol: acc.vol + f.("voluntary_ctxt_switches"),
        inv: acc.inv + f.("nonvoluntary_ctxt_switches")
      }
    end)
  end

  defp vm_memory do
    status = File.read!("/proc/self/status")
    field = fn name -> Regex.run(~r/#{name}:\s+(\d+) kB/, status) |> List.last() |> String.to_integer() |> div(1024) end
    "#{field.("VmSize")} MiB / #{field.("VmRSS")} MiB"
  end

  # Starts a node on `dir`, deploys hello, makes one request; returns the
  # load time and the instantiation time of that request, in ms.
  defp start_measure(dir) do
    node = Node.start(data_dir: dir)
    deploy_hello(node)
    {%{duration: load}, _} = first([:atanor, :wasm, :load])
    request(node, "hello")
    {%{instantiate: inst}, _} = first([:atanor, :wasm, :invoke])
    Supervisor.stop(node.pid)
    flush()
    {ms(load), ms(inst)}
  end

  defp work_request(node) do
    {us, resp} = :timer.tc(fn -> request(node, "hello", "/work", params: [n: 200]) end)
    200 = resp.status
    {us / 1000, resp}
  end

  defp throughput(node, seconds) do
    url = "#{node.url}/hello/x"
    req = Req.new(retry: false)
    deadline = System.monotonic_time(:millisecond) + seconds * 1000

    count =
      1..32
      |> Task.async_stream(
        fn _ -> loop(req, url, deadline, 0) end,
        max_concurrency: 32,
        timeout: :infinity
      )
      |> Enum.reduce(0, fn {:ok, n}, acc -> acc + n end)

    round(count / seconds)
  end

  defp loop(req, url, deadline, n) do
    if System.monotonic_time(:millisecond) >= deadline do
      n
    else
      %{status: 200} = Req.get!(req, url: url)
      loop(req, url, deadline, n + 1)
    end
  end

  defp cpu_model do
    "/proc/cpuinfo"
    |> File.read!()
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "model name"))
    |> String.split(": ")
    |> List.last()
  end
end

Bench.run(seconds, cpu)
