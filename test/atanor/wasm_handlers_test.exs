defmodule Atanor.WasmHandlersTest do
  @moduledoc "Alarms and WebSockets of WASM workers (design §7.3, §7.4, §14)."
  use ExUnit.Case, async: true

  # Failing handlers are logged on purpose.
  @moduletag :capture_log

  import Atanor.Test.Await
  import Atanor.Test.WasmCase

  alias Atanor.{Cell, Registry, Store}
  alias Atanor.Test.{AlarmWorker, WSClient}
  alias AlambiqueTestkit.ManualClock

  @start 1_000_000_000_000
  @rooms [[1, "CREATE TABLE log (id INTEGER PRIMARY KEY, socket TEXT NOT NULL)"]]

  describe "alarms" do
    defp start_alarms(opts \\ []) do
      world = ManualClock.new(@start)
      alarms = [clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 20]
      limits = Keyword.get(opts, :limits, %{})

      node =
        start([{"wclock", "alarm", alarms: true, cells: %{"clock" => AlarmWorker.migrations()}, limits: limits}],
          alarms: alarms ++ Keyword.get(opts, :alarms, [])
        )

      capture([[:atanor, :alarm, :fired], [:atanor, :alarm, :failed], [:atanor, :wasm, :limit]])
      {node, world}
    end

    defp op(node, op, key, opts \\ []) do
      headers = [{"x-op", op}, {"x-ns", opts[:ns] || "clock"}, {"x-key", key}, {"x-at", to_string(opts[:at])}]
      request(node, "wclock", "", method: :post, body: opts[:payload] || "", headers: headers)
    end

    defp rows(node, key) do
      {:ok, %{rows: rows}} =
        Cell.query(node.name, {"clock", key}, "SELECT at_ms, payload, attempts FROM _atanor_alarms")

      rows
    end

    defp fires(node, key) do
      {:ok, %{rows: rows}} = Cell.query(node.name, {"clock", key}, "SELECT payload FROM fires ORDER BY id")
      List.flatten(rows)
    end

    defp index_empty?(node), do: match?({:ok, [], _}, Store.list(Store.handle(node.name), "alarms/"))

    test "an alarm set by the guest fires into its handler, which writes to the cell" do
      {node, world} = start_alarms()
      assert %{status: 200, body: "ok"} = op(node, "set", "a", at: @start + 60_000, payload: "hello")
      assert [[_, "hello", 0]] = rows(node, "a")

      refute_receive {:telemetry, [:atanor, :alarm, :fired], _, %{worker: "wclock"}}, 100
      ManualClock.advance(world, 60_000)
      assert_receive {:telemetry, [:atanor, :alarm, :fired], _, %{worker: "wclock", cell: "clock.a", attempt: 1}}, 5_000

      assert fires(node, "a") == ["hello"]
      assert until(fn -> rows(node, "a") == [] and index_empty?(node) end)
    end

    test "a cancelled alarm does not fire" do
      {node, world} = start_alarms()
      op(node, "set", "a", at: @start + 1_000, payload: "x")
      assert %{status: 200} = op(node, "cancel", "a")
      assert rows(node, "a") == []
      assert index_empty?(node)

      ManualClock.advance(world, 61_000)
      refute_receive {:telemetry, [:atanor, :alarm, :fired], _, %{worker: "wclock"}}, 200
    end

    test "a handler that returns an error is retried until it succeeds" do
      {node, world} = start_alarms()
      op(node, "set", "a", at: @start + 1_000, payload: "flaky")
      ManualClock.advance(world, 1_000)

      assert_receive {:telemetry, [:atanor, :alarm, :failed], _,
                      %{worker: "wclock", reason: {:guest, "flaky"}, final: false, attempt: 1}},
                     5_000

      assert until(fn -> match?([[at, "flaky", 1]] when at == @start + 2_000, rows(node, "a")) end)

      ManualClock.advance(world, 1_000)
      assert_receive {:telemetry, [:atanor, :alarm, :fired], _, %{worker: "wclock", attempt: 2}}, 5_000
      assert fires(node, "a") == ["flaky-attempt", "flaky-attempt", "flaky"]
      assert until(fn -> rows(node, "a") == [] and index_empty?(node) end)
    end

    test "a handler that spins is stopped by the limits and the alarm is retried" do
      {node, world} = start_alarms(limits: %{"cpu_ms" => 100})
      op(node, "set", "a", at: @start + 1_000, payload: "spin")
      ManualClock.advance(world, 1_000)

      assert_receive {:telemetry, [:atanor, :wasm, :limit], _, %{worker: "wclock", limit: :cpu, call: :alarm}}, 10_000

      assert_receive {:telemetry, [:atanor, :alarm, :failed], _,
                      %{worker: "wclock", reason: {:limit, :cpu}, final: false}},
                     5_000

      assert until(fn -> match?([[at, "spin", 1]] when at == @start + 2_000, rows(node, "a")) end)
      assert %{status: 200} = op(node, "cancel", "a")
    end

    test "the guest can set alarms only on namespaces the manifest grants" do
      {node, _world} = start_alarms()
      assert %{status: 403, body: "not granted: other"} = op(node, "set", "a", ns: "other", at: @start)
    end
  end

  describe "jobs" do
    defp start_jobs do
      world = ManualClock.new(@start)
      alarms = [clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 20]
      fires = [[1, "CREATE TABLE fires (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)"]]
      node = start([{"wjob", "job", jobs: true, cells: %{"jobs" => fires}}], alarms: alarms)
      capture([[:atanor, :job, :finished], [:atanor, :job, :dead]])
      {node, world}
    end

    defp job_op(node, op, key, opts) do
      headers = [
        {"x-op", op},
        {"x-ns", opts[:ns] || "jobs"},
        {"x-key", key},
        {"x-kind", opts[:kind] || "test"},
        {"x-at", to_string(opts[:at] || @start)}
      ]

      request(node, "wjob", "", method: :post, body: opts[:payload] || "", headers: headers)
    end

    defp job_fires(node, key) do
      {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", key}, "SELECT payload FROM fires ORDER BY id")
      List.flatten(rows)
    end

    test "the guest enqueues a job and its exported handler runs it" do
      {node, _world} = start_jobs()
      assert %{status: 200, body: id} = job_op(node, "enqueue", "a", payload: "hello")
      assert is_binary(id)
      assert_receive {:telemetry, [:atanor, :job, :finished], _, %{worker: "wjob", cell: {"jobs", "a"}}}, 10_000
      assert until(fn -> job_fires(node, "a") == ["hello"] end)
    end

    test "enqueue-batch commits the statements and the job together" do
      {node, _world} = start_jobs()
      assert %{status: 200} = job_op(node, "batch", "a", payload: "batch")
      assert until(fn -> job_fires(node, "a") == ["batch", "batch"] end)
    end
  end

  describe "WebSockets" do
    defp start_sockets(opts \\ []) do
      node =
        start([
          {"wchat", "socket", sockets: true, cells: %{"rooms" => @rooms}, limits: Keyword.get(opts, :limits, %{})}
        ])

      capture([[:atanor, :wasm, :limit]])
      node
    end

    defp connect(node, path \\ "/wchat") do
      assert {:ok, client} = WSClient.connect(node.port, path)
      on_exit(fn -> WSClient.close(client) end)
      client
    end

    defp call(client, text) do
      client = WSClient.send_frame(client, {:text, text})
      {{:text, reply}, client} = WSClient.recv(client, 5_000)
      {reply, client}
    end

    test "open, echo, binary and plain HTTP all reach the guest" do
      node = start_sockets()
      assert Req.get!(node.url <> "/wchat", retry: false).body == "plain http"

      client = connect(node)
      assert {"hello", client} = call(client, "echo hello")
      assert {"?nope", client} = call(client, "nope")
      client = WSClient.send_frame(client, {:binary, "abc"})
      assert {{:binary, "cba"}, _} = WSClient.recv(client, 5_000)
    end

    test "on-open can reject the upgrade with a response" do
      node = start_sockets()
      assert {:error, 403, "no sockets for you"} = WSClient.connect(node.port, "/wchat/reject")
    end

    test "sockets attached to one cell all receive what the guest sends to it" do
      node = start_sockets()
      [a, b, c] = for _ <- 1..3, do: connect(node)

      assert {"ok", a} = call(a, "join r1")
      assert {"ok", a} = call(a, "join r1")
      assert {"ok", b} = call(b, "join r1")
      assert {"ok", c} = call(c, "join r2")

      assert {"ok", a} = call(a, "say r1 hi")
      assert {{:text, "cell:hi"}, a} = WSClient.recv(a, 5_000)
      assert {{:text, "cell:hi"}, b} = WSClient.recv(b, 5_000)
      assert {:timeout, _} = WSClient.recv(a, 100)
      assert {:timeout, _} = WSClient.recv(b, 100)
      assert {:timeout, _} = WSClient.recv(c, 100)
    end

    test "a message over wasm max_cell_message_bytes is refused and nobody receives it" do
      node =
        start(
          [{"wchat", "socket", sockets: true, cells: %{"rooms" => @rooms}}],
          wasm: [max_cell_message_bytes: 8]
        )

      client = connect(node, "/wchat")
      assert {"ok", client} = call(client, "join r1")
      assert {"ok", client} = call(client, "say r1 12345678")
      assert {{:text, "cell:12345678"}, client} = WSClient.recv(client, 5_000)
      assert {"failed: message_too_large: " <> _, client} = call(client, "say r1 123456789")
      assert {:timeout, _} = WSClient.recv(client, 100)
    end

    test "the host reaches an attached guest socket, and drops terms that are not bytes" do
      node = start_sockets()
      client = connect(node)
      assert {"ok", client} = call(client, "join r1")

      {:ok, deployment} = Registry.deployment(node.name, "wchat")
      env = Atanor.Env.new(node.name, deployment)
      assert :ok = Atanor.Env.send_to_cell(env, {"rooms", "r1"}, {:not, :bytes})
      assert :ok = Atanor.Env.send_to_cell(env, {"rooms", "r1"}, "from env")
      assert {{:text, "cell:from env"}, client} = WSClient.recv(client, 5_000)
      assert {"still here", _} = call(client, "echo still here")
    end

    test "on-message can close the socket after its frames" do
      node = start_sockets()
      client = WSClient.send_frame(connect(node), {:text, "bye"})
      assert {{:text, "bye"}, client} = WSClient.recv(client, 5_000)
      assert {{:close, 1000, _}, _} = WSClient.recv(client, 5_000)
    end

    test "on-close runs when the socket ends, with the id the guest saw" do
      node = start_sockets()
      client = connect(node)
      assert {id, client} = call(client, "id")
      assert byte_size(id) > 10
      WSClient.send_frame(client, {:close, 1000, ""})

      assert until(fn ->
               {:ok, %{rows: rows}} = Cell.query(node.name, {"rooms", "log"}, "SELECT socket FROM log")
               rows == [[id]]
             end)
    end

    test "each socket has its own id" do
      node = start_sockets()
      assert {a, _} = call(connect(node), "id")
      assert {b, _} = call(connect(node), "id")
      assert a != b
    end

    test "an error from on-message closes the socket with 1011" do
      node = start_sockets()
      client = WSClient.send_frame(connect(node), {:text, "fail"})
      assert {{:close, 1011, ""}, _} = WSClient.recv(client, 5_000)
    end

    test "a handler that spins is stopped by the limits and the socket closes with 1011" do
      node = start_sockets(limits: %{"cpu_ms" => 100})
      client = WSClient.send_frame(connect(node), {:text, "spin"})

      assert {{:close, 1011, ""}, _} = WSClient.recv(client, 10_000)

      assert_receive {:telemetry, [:atanor, :wasm, :limit], _, %{worker: "wchat", limit: :cpu, call: :ws_message}},
                     5_000

      assert {"alive", _} = call(connect(node), "echo alive")
    end

    test "a worker without a socket handler answers an upgrade request as plain HTTP" do
      node = start([{"plain", "hello", []}])
      assert {:error, 200, "hello GET /plain" <> _} = WSClient.connect(node.port, "/plain")
    end
  end
end
