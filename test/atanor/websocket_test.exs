defmodule Atanor.WebSocketTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Atanor.Test.{Manifests, OIDCProvider, PlugSocketWorker, SocketWorker, WSClient}
  alias AtanorTestkit.Node

  @routes [{"127.0.0.1", "/"}]

  defp manifest(name \\ "chat", opts \\ []) do
    Manifests.probe(
      name,
      Keyword.merge([module: SocketWorker, sockets: true, cells: %{"rooms" => []}, routes: @routes], opts)
    )
  end

  defp start(workers, opts \\ []) do
    node = Node.start([workers: workers] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp connect(node, path \\ "/") do
    assert {:ok, client} = WSClient.connect(node.port, path)
    on_exit(fn -> WSClient.close(client) end)
    client
  end

  defp call(client, text) do
    client = WSClient.send_frame(client, {:text, text})
    {{:text, reply}, client} = WSClient.recv(client, 5_000)
    {reply, client}
  end

  describe "native workers" do
    test "echo text, reverse binary, and still answer plain HTTP" do
      node = start([manifest()])
      assert Req.get!(node.url <> "/", retry: false).body == "plain http"

      client = connect(node)
      assert {"hello", client} = call(client, "echo hello")
      client = WSClient.send_frame(client, {:binary, "abc"})
      assert {{:binary, "cba"}, _} = WSClient.recv(client, 5_000)
    end

    test "stop closes the socket, and a crash closes it without leaking internals" do
      node = start([manifest()])
      client = WSClient.send_frame(connect(node), {:text, "bye"})
      assert {{:close, 1000, _}, _} = WSClient.recv(client, 5_000)

      client = connect(node)

      log =
        capture_log(fn ->
          client = WSClient.send_frame(client, {:text, "crash"})
          assert {{:close, 1011, ""}, _} = WSClient.recv(client, 5_000)
        end)

      assert log =~ "secret internals"
    end

    test "ws_init can reject the upgrade with a response" do
      node = start([manifest()])
      assert {:error, 403, "no sockets for you"} = WSClient.connect(node.port, "/reject")
    end

    test "a routing key binds the socket to a cell; an ungranted one fails the upgrade" do
      id = "ws-#{System.unique_integer()}"
      test = self()

      :telemetry.attach(id, [:atanor, :ws, :connect], &__MODULE__.forward/4, test)
      on_exit(fn -> :telemetry.detach(id) end)

      node = start([manifest()])
      connect(node, "/room/r1")
      assert_receive {:telemetry, %{count: 1}, %{worker: "chat", cell: {"rooms", "r1"}}}

      log = capture_log(fn -> assert {:error, 500, _} = WSClient.connect(node.port, "/ungranted") end)
      assert log =~ "routing key it may not use"
    end

    test "report telemetry when a socket ends" do
      id = "wsd-#{System.unique_integer()}"
      :telemetry.attach(id, [:atanor, :ws, :disconnect], &__MODULE__.forward/4, self())
      on_exit(fn -> :telemetry.detach(id) end)

      # Telemetry is VM-wide: a socket of another node, dropped by its client, reports to this handler too.
      decoy = start([manifest()])
      WSClient.close(connect(decoy))
      assert_receive {:telemetry, _, %{worker: "chat", reason: {:error, :closed}}}, 1_000

      # So the worker name, unique to this test, tells our socket from the others.
      name = "chat-#{System.unique_integer([:positive])}"
      node = start([manifest(name)])
      client = WSClient.send_frame(connect(node), {:text, "bye"})
      WSClient.recv(client, 5_000)
      assert_receive {:telemetry, %{duration: d}, %{worker: ^name, reason: reason}}, 1_000
      assert reason in [:normal, :shutdown]
      assert d > 0
    end

    test "frames above max_frame_bytes close the socket" do
      node = start([manifest()], websocket: [max_frame_bytes: 10])
      client = connect(node)

      capture_log(fn ->
        client = WSClient.send_frame(client, {:text, "echo " <> String.duplicate("x", 100)})
        assert {{:close, 1009, _}, _} = WSClient.recv(client, 5_000)
      end)
    end

    test "a message spread over frames is bound like a frame" do
      node = start([manifest()], websocket: [max_frame_bytes: 100])
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", node.port, [:binary, active: false])

      :ok =
        :gen_tcp.send(
          socket,
          "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" <>
            "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n"
        )

      assert {:ok, "HTTP/1.1 101" <> _} = :gen_tcp.recv(socket, 0, 2_000)

      # Each frame is within the limit; the message of four is not.
      masked = fn first, payload ->
        mask = <<1, 2, 3, 4>>
        key = binary_part(:binary.copy(mask, div(byte_size(payload), 4) + 1), 0, byte_size(payload))
        <<first, 0x80 + byte_size(payload)>> <> mask <> :crypto.exor(payload, key)
      end

      capture_log(fn ->
        :gen_tcp.send(socket, masked.(0x01, "echo " <> String.duplicate("a", 60)))
        for _ <- 1..2, do: :gen_tcp.send(socket, masked.(0x00, String.duplicate("a", 60)))
        :gen_tcp.send(socket, masked.(0x80, String.duplicate("a", 60)))

        assert {:ok, <<0x88, _len, 1009::16, _::binary>>} = :gen_tcp.recv(socket, 0, 2_000)
      end)
    end

    test "a socket over its frame rate is closed with 1008" do
      node = start([manifest()], websocket: [max_frames_per_s: 1, frame_burst: 5])
      client = connect(node)
      client = Enum.reduce(1..100, client, &WSClient.send_frame(&2, {:text, "echo #{&1}"}))
      assert closed_with?(client, 1008)
    end

    test "a socket on a protected route closes with 1008 when its token expires" do
      provider = OIDCProvider.start()
      on_exit(fn -> OIDCProvider.stop(provider) end)
      OIDCProvider.add_key(provider, "k1")
      auth = [[host: "127.0.0.1", path: "/", issuer: provider.issuer, audience: "api"]]
      node = start([manifest()], auth: auth, oidc: [allow_http: true])

      token = OIDCProvider.token(provider, "k1", %{"exp" => System.system_time(:second) + 2})
      assert {:ok, client} = WSClient.connect(node.port, "/", [{"authorization", "Bearer " <> token}])
      on_exit(fn -> WSClient.close(client) end)
      assert {"hello", client} = call(client, "echo hello")

      # Idle time would not end it (60 s); the token does.
      assert {{:close, 1008, _}, _} = WSClient.recv(client, 10_000)
    end

    test "idle sockets are closed after idle_timeout_ms" do
      node = start([manifest()], websocket: [idle_timeout_ms: 100])
      client = connect(node)
      assert {{:close, _, _}, _} = WSClient.recv(client, 5_000)
    end
  end

  # Reads until the server closes the socket; true when the close code is `code`.
  defp closed_with?(client, code) do
    case WSClient.recv(client, 5_000) do
      {{:close, ^code, _}, _} -> true
      {{:text, _}, client} -> closed_with?(client, code)
      _ -> false
    end
  end

  def forward(_event, measurements, meta, test), do: send(test, {:telemetry, measurements, meta})

  describe "sockets attached to cells" do
    test "receive what is sent to the cell, once, and only those attached" do
      node = start([manifest()])
      a = connect(node)
      b = connect(node)
      c = connect(node)

      assert {":ok", a} = call(a, "join r1")
      assert {":ok", a} = call(a, "join r1")
      assert {":ok", b} = call(b, "join r1")
      assert {":ok", c} = call(c, "join r2")

      assert {":ok", a} = call(a, "say r1 hi")
      assert {{:text, "cell:hi"}, a} = WSClient.recv(a, 5_000)
      assert {{:text, "cell:hi"}, b} = WSClient.recv(b, 5_000)
      assert {:timeout, _} = WSClient.recv(a, 100)
      assert {:timeout, _} = WSClient.recv(b, 100)
      assert {:timeout, _} = WSClient.recv(c, 100)
    end

    test "a socket attaches to a bounded number of cells" do
      node = start([manifest()], sockets: [max_attachments: 3])
      client = connect(node)

      client =
        Enum.reduce(1..3, client, fn i, c ->
          assert {":ok", c} = call(c, "join r#{i}")
          c
        end)

      # Attaching again is not a new attachment.
      assert {":ok", client} = call(client, "join r1")
      assert {"{:error, :too_many_attachments}", client} = call(client, "join r4")

      # Its attachments end with it, so another socket starts from zero.
      other = connect(node)
      assert {":ok", _} = call(other, "join r4")
      _ = client
    end

    test "a socket that closed no longer receives" do
      node = start([manifest()])
      a = connect(node)
      assert {":ok", a} = call(a, "join r1")
      a = WSClient.send_frame(a, {:text, "bye"})
      assert {{:close, 1000, _}, _} = WSClient.recv(a, 5_000)
      b = connect(node)
      assert {":ok", b} = call(b, "say r1 x")
      assert {:timeout, _} = WSClient.recv(b, 100)
    end

    test "reach sockets on another node of the same prefix and store" do
      a = start([manifest()])
      b = start([manifest()], store: a.store)
      client = connect(a)
      assert {":ok", client} = call(client, "join r1")

      {:ok, deployment} = Atanor.Registry.deployment(b.name, "chat")
      assert :ok = Atanor.Env.send_to_cell(Atanor.Env.new(b.name, deployment), {"rooms", "r1"}, "from b")
      assert {{:text, "cell:from b"}, _} = WSClient.recv(client, 5_000)
    end

    test "need the sockets grant and a granted namespace" do
      node =
        start([manifest("nosock", sockets: false, routes: [{"127.0.0.1", "/nosock"}]), manifest()],
          namespaces: %{"rooms" => ["nosock", "chat"]}
        )

      client = connect(node, "/nosock")
      assert {"{:error, {:not_granted, :sockets}}", _} = call(client, "join r1")

      node = start([manifest("nocell", cells: %{}, sockets: true)])
      client = connect(node)
      assert {~s({:error, {:not_granted, {:cell, "rooms"}}}), _} = call(client, "join r1")
      assert {~s({:error, {:not_granted, {:cell, "rooms"}}}), _} = call(client, "say r1 x")
    end

    test "attach is for sockets only" do
      node = start([manifest()])
      {:ok, deployment} = Atanor.Registry.deployment(node.name, "chat")
      assert {:error, :not_a_socket} = Atanor.Env.attach(Atanor.Env.new(node.name, deployment), {"rooms", "r1"})
    end
  end

  describe "plug workers" do
    test "upgrade through the Plug, and the ingress passes the socket" do
      node = start([Manifests.probe("live", module: PlugSocketWorker, routes: @routes)])
      assert Req.get!(node.url <> "/x", retry: false).body == "plain"

      client = connect(node, "/ws")
      assert {"live:hi", _} = call(client, "hi")
    end
  end
end
