# A dev node with synthetic data for the dashboard screenshots
# (scripts/dashboard-screenshots runs it). Prints "DASHBOARD <url>" when ready.
# Uses the workers and WASM guests of the test suite: run with MIX_ENV=test.
Application.put_env(:atanor, :wasm, threads: 4, queue: 32, queue_wait_ms: 1500, cpu_ms: 100)

alias Atanor.Test.{AlarmWorker, CounterWorker, JobWorker, LineWorker, Manifests}

wasm_dir = Path.expand("test/fixtures/wasm")
host = "127.0.0.1"

workers = [
  Manifests.counter("counter", routes: [{host, "/c"}]),
  Manifests.probe("clock",
    module: AlarmWorker,
    alarms: true,
    cells: %{"clock" => AlarmWorker.migrations()},
    routes: [{host, "/set"}]
  ),
  Manifests.probe("mail", module: LineWorker, cells: %{"mail" => LineWorker.migrations()}, tcp: ["smtp"]),
  Manifests.jobs("jobs")
]

{:ok, _} =
  Atanor.Dev.start(
    port: 0,
    data_dir: Path.join(System.tmp_dir!(), "atanor-dashboard-demo-#{System.unique_integer([:positive])}"),
    listeners: %{"smtp" => 0},
    dashboard: [port: 0, token: "demo-token"],
    sweeps: [
      poll_ms: 100,
      lease_ttl_ms: 10_000,
      renew_ms: 2_000,
      cell_timeout_ms: 5_000,
      page_size: 20,
      rate_per_s: 500,
      concurrency: 8,
      max_active: 2
    ],
    workers: workers
  )

for {name, guest, opts} <- [{"greeter", "hello", []}, {"spin", "spin", []}] do
  {:ok, _} = Atanor.Dev.deploy(Atanor, Manifests.wasm(name, guest, [routes: [{host, "/#{name}"}]] ++ opts), wasm_dir)
end

# A head the node cannot apply: it asks for a listener this node does not open.
{:error, _} = Atanor.Dev.deploy(Atanor, Manifests.probe("billing", module: LineWorker, tcp: ["nolistener"]))

base = "http://127.0.0.1:#{Atanor.port()}"
{:ok, smtp} = Atanor.TCP.port(Atanor, "smtp")
now = System.os_time(:millisecond)

get = fn path -> Req.get!(base <> path, retry: false, receive_timeout: 10_000) end
set = fn key, at, payload -> get.("/set?" <> URI.encode_query(key: key, at: at, payload: payload)) end

for n <- 1..40, do: Req.post!("#{base}/c/customer-#{n}", body: "1", retry: false)
for n <- 1..12, do: set.("reminder-#{n}", now + n * 3_600_000, "remind")

# A few jobs, including one dead letter, and one bulk operation for the Jobs page.
for n <- 1..6, do: Req.post!("#{base}/enqueue?#{URI.encode_query(key: "job-#{n}", payload: "ok")}", retry: false)
Req.post!("#{base}/enqueue?#{URI.encode_query(key: "job-broken", payload: "fail", max: "1")}", retry: false)

{:ok, _} =
  Atanor.Sweeps.start(Atanor, %{
    "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
    "action" => %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("swept")},
    "rate_per_s" => 20,
    "concurrency" => 2,
    "page_size" => 5
  })

# Traffic for the metrics page.
spawn(fn ->
  Stream.iterate(0, &(&1 + 1))
  |> Enum.each(fn i ->
    Req.post!("#{base}/c/customer-#{rem(i, 40) + 1}", body: "1", retry: false)
    Req.get!("#{base}/greeter", retry: false)
    if rem(i, 3) == 0, do: Req.get!("#{base}/nothing-here", retry: false)
    if rem(i, 5) == 0, do: get.("/spin")
    if rem(i, 4) == 0, do: set.("tick-#{i}", System.os_time(:millisecond) + 500, "ok")
    if rem(i, 9) == 0, do: set.("broken-#{i}", System.os_time(:millisecond) + 500, "fail")

    if rem(i, 3) == 0 do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, smtp, [:binary, active: false])
      :gen_tcp.send(socket, "RCPT customer-#{rem(i, 40) + 1}\r\nQUIT\r\n")
      :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)
    end

    Process.sleep(150)
  end)
end)

IO.puts("DASHBOARD http://127.0.0.1:#{Atanor.Dashboard.port()}")
Process.sleep(:infinity)
