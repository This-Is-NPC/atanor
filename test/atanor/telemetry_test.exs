defmodule Atanor.TelemetryTest do
  # Events attach to the whole VM, so the node of each test is told apart by its worker name.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Atanor.Test.WasmCase, only: [capture: 1]

  alias Atanor.Test.{AlarmWorker, LineWorker, Manifests, PlugWorker, WasmCase}
  alias AtanorTestkit.Node

  @events [
    [:atanor, :call],
    [:atanor, :http, :reject],
    [:atanor, :wasm, :invoke],
    [:atanor, :wasm, :limit],
    [:atanor, :alarm, :fired],
    [:atanor, :tcp, :connect]
  ]

  setup do
    capture(@events)
    node = Node.start(alarms: [tick_ms: 50], listeners: %{"smtp" => 0})
    on_exit(fn -> Node.stop(node) end)
    %{node: node}
  end

  defp call_event(worker, kind) do
    assert_receive {:telemetry, [:atanor, :call], measurements, %{worker: ^worker, kind: ^kind} = meta}, 5_000
    {measurements, meta}
  end

  test "a request carries its worker, deployment, cell, latency and status", %{node: node} do
    {:ok, deployment} =
      Node.deploy(
        node,
        Manifests.probe("tw", cells: %{"notes" => Manifests.notes_migrations()}, routes: [{"127.0.0.1", "/keyed"}])
      )

    assert Req.get!(node.url <> "/keyed/alice", retry: false).status == 200

    {measurements, meta} = call_event("tw", :http)
    assert meta.deployment == deployment.id
    assert meta.cell == {"notes", "alice"}
    assert meta.result == :ok
    assert meta.status == 200
    assert meta.node == node()
    assert meta.forwarded == false
    assert measurements.duration > 0
  end

  test "a request that fails reports the error, and one without a route is a rejection", %{node: node} do
    {:ok, _} = Node.deploy(node, Manifests.probe("tx", routes: [{"127.0.0.1", "/x"}]))

    assert capture_log(fn -> assert Req.get!(node.url <> "/x/crash", retry: false).status == 500 end) =~
             "secret internals"

    {_, meta} = call_event("tx", :http)
    assert meta.result == :error
    assert meta.reason == :crashed
    assert meta.cell == nil

    assert Req.get!(node.url <> "/nowhere", retry: false).status == 404

    assert_receive {:telemetry, [:atanor, :http, :reject], %{count: 1},
                    %{reason: :no_route, status: 404, host: "127.0.0.1"}}
  end

  test "a Plug worker reports its requests too", %{node: node} do
    {:ok, deployment} = Node.deploy(node, Manifests.probe("tp", module: PlugWorker, routes: [{"127.0.0.1", "/p"}]))
    assert Req.get!(node.url <> "/p", retry: false).status == 200

    {_, meta} = call_event("tp", :plug)
    assert %{deployment: id, result: :ok, status: 200} = meta
    assert id == deployment.id
  end

  test "a WASM request reports the instantiation time and the limit it hit", %{node: node} do
    WasmCase.deploy(node, [{"tg", "hello", []}, {"tl", "spin", []}])
    assert WasmCase.request(node, "tg", "/x").status == 200

    assert_receive {:telemetry, [:atanor, :wasm, :invoke], %{instantiate: instantiate, duration: _},
                    %{worker: "tg", deployment: _, result: :ok}},
                   5_000

    assert instantiate > 0
    {_, meta} = call_event("tg", :http)
    assert meta.result == :ok

    WasmCase.request(node, "tl", "", retry: false)
    assert_receive {:telemetry, [:atanor, :wasm, :limit], %{count: 1}, %{worker: "tl", limit: limit}}, 10_000
    assert limit in [:cpu, :timeout]
  end

  test "TCP connections and alarms report their callbacks", %{node: node} do
    {:ok, _} =
      Node.deploy(
        node,
        Manifests.probe("tm", module: LineWorker, cells: %{"mail" => LineWorker.migrations()}, tcp: ["smtp"])
      )

    {:ok, port} = Atanor.TCP.port(node.name, "smtp")
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    {:ok, _} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = :gen_tcp.send(socket, "RCPT bob\r\n")
    {:ok, _} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = :gen_tcp.send(socket, "WHO\r\n")
    {:ok, _} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    {_, init} = call_event("tm", :tcp_init)
    assert init.cell == nil
    {_, data} = call_event("tm", :tcp_data)
    {_, bound} = call_event("tm", :tcp_data)
    assert [data.cell, bound.cell] == [nil, {"mail", "bob"}]

    {:ok, _} =
      Node.deploy(
        node,
        Manifests.probe("ta",
          module: AlarmWorker,
          cells: %{"clock" => AlarmWorker.migrations()},
          alarms: true,
          routes: [{"127.0.0.1", "/"}]
        )
      )

    at = System.os_time(:millisecond)
    Req.get!(node.url <> "/set", params: [key: "k", at: at, payload: "p"], retry: false)
    {_, alarm} = call_event("ta", :alarm)
    assert alarm.cell == {"clock", "k"}
    assert alarm.result == :ok
    assert_receive {:telemetry, [:atanor, :alarm, :fired], %{duration: _}, %{worker: "ta", cell: "clock.k"}}, 5_000
  end
end
