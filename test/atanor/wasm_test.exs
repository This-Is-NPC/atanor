defmodule Atanor.WasmTest do
  use ExUnit.Case, async: true

  import Atanor.Test.WasmCase

  alias Atanor.Test.{HTTPTarget, Manifests}
  alias AtanorTestkit.Node

  import Bitwise

  @notes Manifests.notes_migrations()

  describe "wasi:http" do
    setup do
      %{node: start([{"hello", "hello", []}])}
    end

    test "the request reaches the guest and the response comes back", %{node: node} do
      resp = request(node, "hello", "/a/b?x=1&y=2", method: :post, body: "payload")
      assert resp.status == 200
      assert resp.body == "hello POST /hello/a/b?x=1&y=2 authority=127.0.0.1:#{node.port} body=payload"
    end

    test "every request gets a fresh instance", %{node: node} do
      bodies = for _ <- 1..3, do: request(node, "hello", "/x").body
      assert length(Enum.uniq(bodies)) == 1
    end

    test "the guest has no environment, arguments, files or sockets", %{node: node} do
      resp = request(node, "hello", "/ambient")
      assert resp.body == "env=0\nargs=0\nread_dir=denied\npasswd=denied\ntcp=denied\nlookup=denied"
    end

    test "a large body goes through both ways", %{node: node} do
      body = String.duplicate("x", 500_000)
      resp = request(node, "hello", "/", method: :post, body: body)
      assert byte_size(resp.body) > 500_000
    end
  end

  describe "cells" do
    setup do
      %{node: start([{"cell", "cell", cells: %{"notes" => @notes}}])}
    end

    defp sql(node, op, sql, opts \\ []) do
      headers =
        [{"x-op", op}, {"x-ns", opts[:ns] || "notes"}, {"x-key", "a"}, {"x-params", opts[:params] || ""}] ++
          (opts[:headers] || [])

      request(node, "cell", "", method: :post, body: sql, headers: headers)
    end

    test "execute, query and batch on a granted namespace", %{node: node} do
      assert %{status: 200} = sql(node, "execute", "INSERT INTO notes (body) VALUES (?)", params: "hi")
      assert %{status: 200, body: "[id,body] 1,hi"} = sql(node, "query", "SELECT id, body FROM notes")

      assert %{status: 200, body: "[] ;[] "} =
               sql(node, "batch", "INSERT INTO notes (body) VALUES ('b')\nINSERT INTO notes (body) VALUES ('c')")

      assert %{body: "[count(*)] 3"} = sql(node, "query", "SELECT count(*) FROM notes")
    end

    test "a batch is one transaction: a failing statement undoes the others", %{node: node} do
      resp = sql(node, "batch", "INSERT INTO notes (body) VALUES ('x')\nINSERT INTO missing VALUES (1)")
      assert resp.status == 500
      assert resp.body =~ "failed"
      assert %{body: "[count(*)] 0"} = sql(node, "query", "SELECT count(*) FROM notes")
    end

    test "a namespace the manifest does not grant is refused at call time", %{node: node} do
      assert %{status: 403, body: "not granted: other"} = sql(node, "query", "SELECT 1", ns: "other")
    end

    test "a read statement cannot write", %{node: node} do
      assert %{status: 500} = sql(node, "query", "INSERT INTO notes (body) VALUES ('x')")
    end

    test "query-bounded reads like query on a cell this node owns, and refuses a zero bound", %{node: node} do
      sql(node, "execute", "INSERT INTO notes (body) VALUES (?)", params: "hi")

      assert %{status: 200, body: "[id,body] 1,hi"} =
               sql(node, "query-bounded", "SELECT id, body FROM notes", headers: [{"x-lag", "500"}])

      assert %{status: 500, body: "failed: invalid option: consistency"} =
               sql(node, "query-bounded", "SELECT 1", headers: [{"x-lag", "0"}])

      assert %{status: 403, body: "not granted: other"} =
               sql(node, "query-bounded", "SELECT 1", ns: "other", headers: [{"x-lag", "500"}])

      assert %{status: 500} =
               sql(node, "query-bounded", "INSERT INTO notes (body) VALUES ('x')", headers: [{"x-lag", "500"}])
    end
  end

  describe "secrets" do
    setup do
      secrets = %{"s" => %{"API_TOKEN" => "t0ken"}}
      %{node: start([{"s", "secret", secrets: ["API_TOKEN", "UNSET"]}], secrets: secrets)}
    end

    defp secret(node, name), do: request(node, "s", "", headers: [{"x-name", name}])

    test "granted names return the operator's value", %{node: node} do
      assert %{status: 200, body: "t0ken"} = secret(node, "API_TOKEN")
    end

    test "a granted name without a value is missing, another name is refused", %{node: node} do
      assert %{status: 404, body: "missing: UNSET"} = secret(node, "UNSET")
      assert %{status: 403, body: "not granted: OTHER"} = secret(node, "OTHER")
    end
  end

  describe "outbound HTTP" do
    setup do
      {_pid, port} = HTTPTarget.start(self())

      node =
        start(
          [
            {"out", "outbound", allow: ["127.0.0.1"]},
            {"short", "outbound", allow: ["127.0.0.1"], limits: %{"timeout_ms" => 500}},
            {"closed", "hello", []}
          ],
          allow_private_hosts: ["127.0.0.1"]
        )

      %{node: node, port: port}
    end

    test "a granted host is reached through the host's checks", %{node: node, port: port} do
      resp = request(node, "out", "", headers: [{"x-url", "http://127.0.0.1:#{port}/ok"}])
      assert resp.body == "200 hello"
      assert_receive {:target_hit, "/ok"}
    end

    test "a response that never completes ends at the call's timeout", %{node: node, port: port} do
      resp = request(node, "short", "", headers: [{"x-url", "http://127.0.0.1:#{port}/hang"}], receive_timeout: 8_000)
      assert resp.status == 504
    end

    test "a response over the node's cap is refused", %{node: node, port: port} do
      resp = request(node, "out", "", headers: [{"x-url", "http://127.0.0.1:#{port}/big?bytes=20000000"}])
      assert resp.status == 502
      assert resp.body =~ "failed"
    end

    test "another host is denied and never contacted", %{node: node, port: port} do
      resp = request(node, "out", "", headers: [{"x-url", "http://localhost:#{port}/ok"}])
      assert resp.status == 502
      assert resp.body =~ "HttpRequestDenied"
      refute_receive {:target_hit, _}, 100
    end

    test "private addresses are refused unless the operator allows them", %{port: port} do
      node = start([{"out", "outbound", allow: ["127.0.0.1"]}])
      resp = request(node, "out", "", headers: [{"x-url", "http://127.0.0.1:#{port}/ok"}])
      assert resp.status == 502
      refute_receive {:target_hit, _}, 100
    end

    test "without the grant the component does not instantiate" do
      node = Node.start()
      on_exit(fn -> Node.stop(node) end)

      assert {:error, error} =
               Atanor.Dev.deploy(node.name, manifest("out", "outbound"), Path.expand("test/fixtures/wasm"))

      assert inspect(error) =~ "wasi:http/outgoing-handler"
    end
  end

  describe "worker calls" do
    setup do
      node =
        start([
          {"hello", "hello", callable_by: ["caller"]},
          {"caller", "caller", workers: ["hello"]}
        ])

      %{node: node}
    end

    test "a granted worker is called with the request record", %{node: node} do
      resp =
        request(node, "caller", "", method: :post, body: "ping", headers: [{"x-worker", "hello"}, {"x-path", "/p"}])

      assert resp.body =~ "200 hello POST /p? authority=hello body=ping"
    end

    test "another worker is refused at call time", %{node: node} do
      resp = request(node, "caller", "", headers: [{"x-worker", "caller"}, {"x-path", "/"}])
      assert %{status: 403, body: "not granted: caller"} = resp
    end
  end

  describe "limits" do
    setup do
      capture([[:atanor, :wasm, :limit], [:atanor, :wasm, :invoke]])

      node =
        start([
          {"spin", "spin", []},
          {"slow", "spin", limits: %{"timeout_ms" => 100}},
          {"hog", "hog", limits: %{"memory_bytes" => 16 * 1024 * 1024}},
          {"hello", "hello", []}
        ])

      %{node: node}
    end

    test "a runaway guest is stopped by the CPU limit", %{node: node} do
      assert %{status: 500, body: %{"error" => "limit_exceeded"}} = request(node, "spin")
      assert_receive {:telemetry, [:atanor, :wasm, :limit], %{count: 1}, %{limit: :cpu, worker: "spin"}}
    end

    test "each worker's cpu_ms sets its own CPU limit, capped by the node's", %{node: node} do
      deploy(node, [
        {"short", "spin", limits: %{"cpu_ms" => 60}},
        {"long", "spin", limits: %{"cpu_ms" => 200}},
        {"capped", "spin", limits: %{"cpu_ms" => 100_000}}
      ])

      cpu = fn worker ->
        request(node, worker)
        assert_receive {:telemetry, [:atanor, :wasm, :invoke], %{cpu: cpu}, %{worker: ^worker}}
        System.convert_time_unit(cpu, :native, :millisecond)
      end

      short = cpu.("short")
      long = cpu.("long")
      capped = cpu.("capped")
      assert short in 60..150
      assert long in 200..300
      assert capped in 300..450
    end

    test "the wall-clock deadline stops a guest before its CPU limit", %{node: node} do
      assert %{status: 504, body: %{"error" => "timeout"}} = request(node, "slow")
      assert_receive {:telemetry, [:atanor, :wasm, :limit], _, %{limit: :timeout, worker: "slow"}}
    end

    test "a guest that allocates past the cap is stopped", %{node: node} do
      assert %{status: 500, body: %{"error" => "limit_exceeded"}} = request(node, "hog")
      assert_receive {:telemetry, [:atanor, :wasm, :limit], _, %{limit: :memory, worker: "hog"}}
    end

    test "a guest under the cap is not", %{node: node} do
      assert %{status: 200, body: "allocated 4 MiB"} = request(node, "hog", "", params: [mib: 4])
    end

    test "the node keeps serving after limits are hit", %{node: node} do
      request(node, "spin")
      assert %{status: 200} = request(node, "hello")
    end

    test "invoke events report instantiation and the result", %{node: node} do
      request(node, "hello")

      assert_receive {:telemetry, [:atanor, :wasm, :invoke], %{duration: d, instantiate: i, memory_bytes: m},
                      %{worker: "hello", result: :ok}}

      assert d > 0 and i > 0 and m > 0
    end
  end

  describe "host resources" do
    setup do
      %{node: start([{"fields", "fieldhog", []}])}
    end

    defp fields(node, n, size), do: request(node, "fields", "", params: [n: n, size: size])

    test "a guest holds the resources its calls need", %{node: node} do
      assert %{status: 200, body: "held 100"} = fields(node, 100, 1000)
    end

    test "a guest cannot hold more resources than the cap", %{node: node} do
      cap = Atanor.Wasm.settings().max_resources
      assert %{status: 500} = fields(node, cap + 1000, 1)
    end

    test "a header value over the field size cap stops the guest", %{node: node} do
      cap = Atanor.Wasm.settings().max_field_bytes
      assert %{status: 200} = fields(node, 1, div(cap, 2))
      assert %{status: 500} = fields(node, 1, cap * 2)
    end
  end

  describe "manifest limits" do
    test "are capped by the node's ceilings" do
      settings = Atanor.Wasm.settings(max_timeout_ms: 5_000, max_memory_bytes: 1 <<< 20, max_fuel: 100)
      manifest = %{limits: %{timeout_ms: 1 <<< 40, memory_bytes: 1 <<< 40, fuel: 1 <<< 60, cpu_ms: 1 <<< 40}}
      limits = Atanor.Wasm.limits(manifest, settings)
      assert %{timeout_ms: 5_000, memory_bytes: 1_048_576, fuel: 100, cpu_ms: 300} = limits

      below = Atanor.Wasm.limits(%{limits: %{timeout_ms: 1_000, memory_bytes: 4096, fuel: 10}}, settings)
      assert %{timeout_ms: 1_000, memory_bytes: 4096, fuel: 10} = below
    end

    test "a timeout beyond what a timer takes does not break the worker" do
      node = start([{"wide", "hello", limits: %{"timeout_ms" => 10_000_000_000}}])
      assert %{status: 200} = request(node, "wide")
    end
  end

  describe "activation" do
    test "a component importing a binding the manifest does not grant is refused" do
      node = Node.start()
      on_exit(fn -> Node.stop(node) end)
      dir = Path.expand("test/fixtures/wasm")

      assert {:error, error} = Atanor.Dev.deploy(node.name, manifest("sneaky", "sneaky"), dir)
      assert inspect(error) =~ "atanor:cell/sql@0.1.0"

      granted =
        manifest("sneaky", "sneaky", cells: %{"n" => []}, secrets: ["S"], workers: ["w"], alarms: true, sockets: true)

      assert {:ok, _} = Atanor.Dev.deploy(node.name, granted, dir)
    end

    test "granting alarms or sockets needs the exported handler" do
      node = Node.start()
      on_exit(fn -> Node.stop(node) end)
      dir = Path.expand("test/fixtures/wasm")

      assert {:error, {:missing_export, "atanor:worker/alarm-handler@0.1.0"}} =
               Atanor.Dev.deploy(node.name, manifest("hello", "hello", alarms: true), dir)

      assert {:error, {:missing_export, "atanor:worker/socket-handler@0.1.0"}} =
               Atanor.Dev.deploy(node.name, manifest("hello", "hello", sockets: true), dir)

      assert {:ok, _} = Atanor.Dev.deploy(node.name, manifest("hello", "hello"), dir)
    end

    test "invalid component bytes are refused" do
      dir = Path.join(System.tmp_dir!(), "atanor-bad-#{System.pid()}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "bad.wasm"), "not wasm")
      node = Node.start()
      on_exit(fn -> Node.stop(node) end)

      assert {:error, error} = Atanor.Dev.deploy(node.name, manifest("bad", "bad"), dir)
      assert inspect(error) =~ "invalid_component"
    end
  end

  describe "compiled code cache" do
    setup do
      dir = Path.join(System.tmp_dir!(), "atanor-cache-#{System.pid()}-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      capture([[:atanor, :wasm, :load]])
      %{dir: dir}
    end

    defp start_and_stop(dir) do
      node = Node.start(data_dir: dir)
      deploy(node, [{"hello", "hello", []}])
      assert %{status: 200} = request(node, "hello")
      Supervisor.stop(node.pid)
    end

    test "the first start compiles, the next loads from disk", %{dir: dir} do
      start_and_stop(dir)
      assert_receive {:telemetry, [:atanor, :wasm, :load], %{duration: compile}, %{source: :compiled}}

      start_and_stop(dir)
      assert_receive {:telemetry, [:atanor, :wasm, :load], %{duration: load}, %{source: :disk}}
      assert load < compile
    end

    test "a damaged cache file is recompiled", %{dir: dir} do
      start_and_stop(dir)
      assert_receive {:telemetry, [:atanor, :wasm, :load], _, %{source: :compiled}}
      [file] = Path.wildcard(Path.join([dir, "wasm", "*.cwasm"]))
      File.write!(file, binary_part(File.read!(file), 0, 1000))

      start_and_stop(dir)
      assert_receive {:telemetry, [:atanor, :wasm, :load], _, %{source: :recompiled}}

      start_and_stop(dir)
      assert_receive {:telemetry, [:atanor, :wasm, :load], _, %{source: :disk}}
    end

    test "native counters are readable" do
      %{compiled_components: before} = Atanor.Wasm.Stats.read()
      start([{"hello", "hello", []}])

      # The counters are VM-wide and only grow, so other tests cannot hide the compile.
      assert %{compiled_components: n, live_instances: _, alloc_bytes: bytes} = Atanor.Wasm.Stats.read()
      assert n > before and bytes > 0
    end
  end

  describe "node settings" do
    test "carry the documented defaults" do
      settings = Atanor.Wasm.settings()
      assert settings.timeout_ms == 30_000
      assert settings.memory_bytes == 64 * 1024 * 1024
      assert settings.grace_ms == 2_000
      assert settings.stderr_bytes == 4_096
      assert settings.table_elements == 100_000
      assert settings.pooling == true
    end

    test "take overrides and reject invalid values" do
      settings =
        Atanor.Wasm.settings(
          timeout_ms: 123,
          memory_bytes: 456,
          grace_ms: 7,
          stderr_bytes: 89,
          table_elements: 101
        )

      assert %{timeout_ms: 123, memory_bytes: 456, grace_ms: 7, stderr_bytes: 89, table_elements: 101} =
               settings

      assert_raise ArgumentError, ~r/:timeout_ms/, fn -> Atanor.Wasm.settings(timeout_ms: 0) end
      assert_raise ArgumentError, ~r/:table_elements/, fn -> Atanor.Wasm.settings(table_elements: 0) end
      assert_raise ArgumentError, ~r/:cpu/, fn -> Atanor.Wasm.settings(cpu: :magic) end
      assert_raise ArgumentError, ~r/:pooling/, fn -> Atanor.Wasm.settings(pooling: :yes) end
    end
  end
end
