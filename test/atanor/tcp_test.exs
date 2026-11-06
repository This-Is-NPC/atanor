defmodule Atanor.TCPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Atanor.Test.Await

  alias Atanor.Test.{LineWorker, Manifests}
  alias AtanorTestkit.Node

  defp manifest(opts \\ []) do
    Manifests.probe(
      "mail",
      Keyword.merge([module: LineWorker, cells: %{"mail" => LineWorker.migrations()}, tcp: ["smtp"]], opts)
    )
  end

  defp start(opts \\ []) do
    node = Node.start(Keyword.merge([listeners: %{"smtp" => 0}], opts))
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp started(opts \\ [], manifest_opts \\ []) do
    node = start(opts)
    {:ok, _} = Node.deploy(node, manifest(manifest_opts))
    node
  end

  defp connect(node) do
    {:ok, port} = Atanor.TCP.port(node.name, "smtp")
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp line(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    String.trim_trailing(line)
  end

  defp say(socket, text) do
    :ok = :gen_tcp.send(socket, text <> "\r\n")
    line(socket)
  end

  defp sockname(node, listener) do
    {:ok, {ip, _port}} = ThousandIsland.listener_info(GenServer.call(Module.concat(node.name, TCP), {:pid, listener}))
    ip
  end

  defp closed?(socket), do: :gen_tcp.recv(socket, 0, 5_000) == {:error, :closed}

  defp stored(node, user) do
    {:ok, %{rows: rows}} = Atanor.Cell.query(node.name, {"mail", user}, "SELECT body FROM mail ORDER BY id")
    List.flatten(rows)
  end

  describe "listeners" do
    test "open when a deployment claims them and close when it goes away" do
      node = start()
      assert :error = Atanor.TCP.port(node.name, "smtp")

      {:ok, _} = Node.deploy(node, manifest())
      assert {:ok, port} = Atanor.TCP.port(node.name, "smtp")
      assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: true])

      # Not a reconnect to the port: another node of the VM may bind it as soon as it is free.
      listener = GenServer.call(Module.concat(node.name, TCP), {:pid, "smtp"})
      monitor = Process.monitor(listener)

      {:ok, _} = Node.undeploy(node, "mail")
      assert :error = Atanor.TCP.port(node.name, "smtp")
      assert_receive {:DOWN, ^monitor, :process, ^listener, _}
      assert_receive {:tcp_closed, ^socket}
    end

    test "bind the ingress ip by default, and their own :ip when given" do
      node = start(ip: {127, 0, 0, 2}, listeners: %{"smtp" => 0, "imap" => [port: 0, ip: {127, 0, 0, 3}]})
      {:ok, _} = Node.deploy(node, manifest(tcp: ["smtp", "imap"]))

      assert sockname(node, "smtp") == {127, 0, 0, 2}
      assert sockname(node, "imap") == {127, 0, 0, 3}
    end

    test "accept connections only on the address they bind" do
      # The sentinel holds the same port on 127.0.0.1 for the whole test: a listener bound to
      # 0.0.0.0 or 127.0.0.1 would fail with :eaddrinuse, and no other process can take the port.
      {:ok, sentinel} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(sentinel) end)
      {:ok, port} = :inet.port(sentinel)

      node = start(listeners: %{"smtp" => [port: port, ip: "127.0.0.2"]})
      {:ok, _} = Node.deploy(node, manifest())

      assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 2}, port, [:binary, active: false, packet: :line])
      on_exit(fn -> :gen_tcp.close(socket) end)
      assert line(socket) =~ "220"

      assert {:ok, other} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line])
      on_exit(fn -> :gen_tcp.close(other) end)
      assert {:ok, accepted} = :gen_tcp.accept(sentinel, 2_000)
      on_exit(fn -> :gen_tcp.close(accepted) end)
      assert {:error, :timeout} = :gen_tcp.recv(other, 0, 200)
    end

    test "bind an IPv6 address" do
      node = start(listeners: %{"smtp" => [port: 0, ip: "::1"]})
      {:ok, _} = Node.deploy(node, manifest())
      {:ok, port} = Atanor.TCP.port(node.name, "smtp")

      assert {:ok, socket} = :gen_tcp.connect({0, 0, 0, 0, 0, 0, 0, 1}, port, [:binary, active: false, packet: :line])
      on_exit(fn -> :gen_tcp.close(socket) end)
      assert line(socket) =~ "220"
    end

    test "of a worker already active open when a node starts" do
      a = started()
      b = Node.start(store: a.store, listeners: %{"smtp" => 0})
      on_exit(fn -> Node.stop(b) end)

      assert {:ok, port} = Atanor.TCP.port(b.name, "smtp")
      assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
      on_exit(fn -> :gen_tcp.close(socket) end)
      assert line(socket) =~ "220"
    end

    test "stay open across a version switch, and are not opened for unclaimed names" do
      node = start(listeners: %{"smtp" => 0, "imap" => 0})
      {:ok, _} = Node.deploy(node, manifest())
      {:ok, port} = Atanor.TCP.port(node.name, "smtp")
      {:ok, _} = Node.deploy(node, manifest(limits: %{"timeout_ms" => 5}))
      assert {:ok, ^port} = Atanor.TCP.port(node.name, "smtp")
      assert :error = Atanor.TCP.port(node.name, "imap")
    end

    test "a port that cannot be bound refuses the activation and the previous version keeps serving" do
      {:ok, taken} = :gen_tcp.listen(0, [])
      on_exit(fn -> :gen_tcp.close(taken) end)
      {:ok, port} = :inet.port(taken)
      node = Node.start(listeners: %{"smtp" => 0, "busy" => port})
      on_exit(fn -> Node.stop(node) end)

      {:ok, %{id: v1}} = Node.deploy(node, manifest())
      assert {:error, {:listener_failed, "busy", :eaddrinuse}} = Node.deploy(node, manifest(tcp: ["smtp", "busy"]))
      assert {:ok, %{id: ^v1}} = Atanor.Registry.deployment(node.name, "mail")
      assert {:ok, _} = Atanor.TCP.port(node.name, "smtp")
    end

    test "one worker per listener, and a tcp route needs handle_tcp/3" do
      node = start()

      assert {:error, {:missing_callback, Atanor.Test.ProbeWorker, {:handle_tcp, 3}}} =
               Node.deploy(node, Manifests.probe("probe", tcp: ["smtp"]))

      {:ok, _} = Node.deploy(node, manifest())

      other = Manifests.probe("other", module: LineWorker, tcp: ["smtp"])
      assert {:error, {:listener_taken, "smtp", "mail"}} = Node.deploy(node, other)
    end
  end

  test "a listener can be bound to the workers that may claim it" do
    node = Node.start(listeners: %{"smtp" => [port: 0, workers: ["mail"]]})
    on_exit(fn -> Node.stop(node) end)

    evil = Manifests.probe("aaa-evil", module: LineWorker, tcp: ["smtp"])
    assert {:error, {:listener_not_allowed, "smtp", "aaa-evil"}} = Node.deploy(node, evil)
    assert :error = Atanor.TCP.port(node.name, "smtp")
    assert {:ok, _} = Node.deploy(node, manifest())
    assert {:ok, _} = Atanor.TCP.port(node.name, "smtp")
  end

  test "WASM manifests cannot claim listeners yet" do
    node = start()
    manifest = Manifests.wasm("guest", "hello", routes: [{"127.0.0.1", "/guest"}], tcp: ["smtp"])

    assert {:error, {:unsupported_for_wasm, :tcp}} =
             Atanor.Dev.deploy(node.name, manifest, Path.expand("test/fixtures/wasm"))

    assert :error = Atanor.TCP.port(node.name, "smtp")
  end

  describe "connections" do
    test "run a session and store the message in the recipient's cell" do
      node = started()
      socket = connect(node)

      assert line(socket) == "220 smtp ready"
      assert say(socket, "HELO client") == "250 hello client"
      assert say(socket, "DATA") == "503 need RCPT"
      assert say(socket, "RCPT bob") == "250 ok"
      assert say(socket, "DATA") == "354 go ahead"
      :ok = :gen_tcp.send(socket, "Subject: hi\r\n\r\nhello bob\r\n")
      assert say(socket, ".") == "250 stored"
      assert say(socket, "QUIT") == "221 bye"
      assert closed?(socket)

      assert stored(node, "bob") == ["Subject: hi\n\nhello bob"]
      assert stored(node, "alice") == []
    end

    test "ask the routing key after each answer until it names a cell, then bind for good" do
      Process.register(self(), :line_worker_probe)
      node = started()
      socket = connect(node)

      line(socket)
      assert_receive {:route_key, %{rcpt: nil}}
      say(socket, "HELO x")
      assert_receive {:route_key, %{rcpt: nil}}
      say(socket, "RCPT carol")
      assert_receive {:route_key, %{rcpt: "carol"}}

      say(socket, "HELO again")
      say(socket, "RCPT dave")
      refute_receive {:route_key, _}, 100
    end

    test "split a command across packets and several commands in one packet" do
      node = started()
      socket = connect(node)
      line(socket)

      :ok = :gen_tcp.send(socket, "HE")
      :ok = :gen_tcp.send(socket, "LO a\r\nHELO b\r\n")
      assert line(socket) == "250 hello a"
      assert line(socket) == "250 hello b"
    end

    test "keep the deployment they started on" do
      node = started()
      {:ok, v1} = Atanor.Registry.deployment(node.name, "mail")
      old = connect(node)
      line(old)

      {:ok, v2} = Node.deploy(node, manifest(limits: %{"timeout_ms" => 5}))
      assert v1.id != v2.id

      assert say(old, "WHO") == v1.id
      new = connect(node)
      line(new)
      assert say(new, "WHO") == v2.id
    end

    test "close when the worker crashes, without leaking internals" do
      node = started()
      socket = connect(node)
      line(socket)

      log =
        capture_log(fn ->
          :ok = :gen_tcp.send(socket, "CRASH\r\n")
          assert closed?(socket)
        end)

      assert log =~ "worker mail"
      assert log =~ "secret internals"
    end

    test "close when the routing key names a namespace that is not granted" do
      node = started()
      socket = connect(node)
      line(socket)

      log =
        capture_log(fn ->
          assert say(socket, "BADNS") == "250 ok"
          assert closed?(socket)
        end)

      assert log =~ "routing key it may not use"
    end

    test "close after the idle timeout" do
      node = started(tcp: [idle_timeout_ms: 100])
      socket = connect(node)
      line(socket)
      assert closed?(socket)
    end

    test "hand the worker chunks of at most max_chunk_bytes" do
      Process.register(self(), :line_worker_probe)
      node = started(tcp: [max_chunk_bytes: 16])
      socket = connect(node)
      line(socket)

      :ok = :gen_tcp.send(socket, String.duplicate("x", 200) <> "\r\n")
      assert line(socket) == "500 what"

      sizes =
        for _ <- 1..13,
            do:
              (
                assert_receive {:chunk, size}
                size
              )

      assert Enum.max(sizes) <= 16
      assert Enum.sum(sizes) == 202
    end

    test "close a connection whose worker refuses an overlong line" do
      node = started()
      socket = connect(node)
      line(socket)
      :ok = :gen_tcp.send(socket, String.duplicate("x", 2000))
      assert line(socket) == "500 line too long"
      assert closed?(socket)
    end

    test "report telemetry for connects and disconnects" do
      id = "tcp-#{System.unique_integer()}"
      test = self()

      :telemetry.attach_many(
        id,
        [[:atanor, :tcp, :connect], [:atanor, :tcp, :disconnect]],
        fn event, measurements, meta, _ -> send(test, {:telemetry, event, measurements, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      node = started()
      socket = connect(node)
      line(socket)
      assert_receive {:telemetry, [:atanor, :tcp, :connect], %{count: 1}, %{worker: "mail", listener: "smtp"}}

      say(socket, "RCPT erin")
      say(socket, "QUIT")

      assert_receive {:telemetry, [:atanor, :tcp, :disconnect], %{bytes_in: 17, bytes_out: bytes_out, duration: d},
                      %{reason: :worker, cell: {"mail", "erin"}, listener: "smtp"}}

      assert bytes_out > 0 and d > 0
      refute_receive {:telemetry, [:atanor, :tcp, :disconnect], _, _}, 100

      other = connect(node)
      line(other)
      :gen_tcp.close(other)
      assert_receive {:telemetry, [:atanor, :tcp, :disconnect], _, %{reason: :peer}}
    end

    test "end when the listener closes" do
      node = started()
      socket = connect(node)
      line(socket)
      {:ok, _} = Node.undeploy(node, "mail")
      assert until(fn -> closed?(socket) end)
    end
  end

  describe "a drain" do
    test "closes a connection whose cell is not woken here, with the reason, as TCP has no Retry-After" do
      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        [:atanor, :tcp, :disconnect],
        fn _event, _measures, meta, _ -> send(parent, {:disconnect, meta.reason}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      node = started(stop: [exit: false])
      socket = connect(node)
      assert line(socket) == "220 smtp ready"
      assert say(socket, "RCPT bob") == "250 ok"

      assert {:ok, _} = Atanor.drain(node.name)
      :ok = :gen_tcp.send(socket, "DATA\r\n")
      assert closed?(socket)
      assert_receive {:disconnect, {:unavailable, :draining}}
    end
  end
end
