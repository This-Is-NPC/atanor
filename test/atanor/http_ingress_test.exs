defmodule Atanor.HTTPIngressTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Atanor.Test.{Await, Manifests, RawHTTP}
  alias AtanorTestkit.Node

  @cells %{"notes" => Manifests.notes_migrations()}

  defp start(opts \\ []) do
    workers = [Manifests.probe("w", cells: @cells, routes: [{"127.0.0.1", "/"}, {"*.deep.test", "/"}])]
    node = Node.start(Keyword.put_new(opts, :workers, workers))
    on_exit(fn -> Node.stop(node) end)
    node
  end

  describe "route matching" do
    # Counted in reductions of this process, so a slow host cannot fail it. The host stays under the
    # 253 bytes of a name, so only max_host_labels stops it; without the bounds the lookup tries every
    # host suffix against every path prefix (about 480,000 table reads).
    test "a long host and a long path are refused at once" do
      node = start()
      host = String.duplicate("a.", 120) <> "test"
      path = String.duplicate("/a", 4_000)
      conn = Plug.Test.conn(:get, "http://#{host}#{path}")

      {:reductions, before} = Process.info(self(), :reductions)
      conn = Atanor.HTTP.call(conn, Atanor.HTTP.init(name: node.name))
      {:reductions, after_} = Process.info(self(), :reductions)

      IO.puts("pathological request answered #{conn.status} in #{after_ - before} reductions")
      assert conn.status == 400
      assert after_ - before < 100_000
    end

    test "the limits are configurable and a deep path within them is served" do
      node = start(http: [max_path_segments: 70, max_host_labels: 8])
      path = String.duplicate("/a", 60)
      assert {200, _, _} = RawHTTP.get(node.port, path, "127.0.0.1")
      assert {400, _, _} = RawHTTP.get(node.port, String.duplicate("/a", 71), "127.0.0.1")
      assert {400, _, _} = RawHTTP.get(node.port, "/", String.duplicate("a.", 9) <> "test")
      assert {200, _, _} = RawHTTP.get(node.port, "/", "x.deep.test")
    end
  end

  describe "connections" do
    defp connections(node),
      do: length(elem(ThousandIsland.connection_pids(Atanor.Registry.http_listener(node.name)), 1))

    # Closed, or answered with an HTTP/1.1 error: never a timeout of the test.
    defp refused?({:error, :closed}), do: true
    defp refused?({:ok, "HTTP/1." <> <<_, " 4", _::binary>>}), do: true
    defp refused?(_), do: false

    defp open(node, n) do
      socks = for _ <- 1..n, do: elem(:gen_tcp.connect(~c"127.0.0.1", node.port, [:binary, active: false]), 1)
      on_exit(fn -> Enum.each(socks, &:gen_tcp.close/1) end)
      socks
    end

    test "the listener serves at most max_connections at a time" do
      node = start(http: [max_connections: 6, acceptors: 2])
      socks = open(node, 20)

      Await.until(fn -> connections(node) == 6 end)
      Process.sleep(300)
      assert connections(node) == 6

      Enum.each(socks, &:gen_tcp.close/1)
      Await.until(fn -> connections(node) == 0 end)
      assert {200, _, _} = RawHTTP.get(node.port, "/x", "127.0.0.1")
    end

    test "the admin listener has its own cap" do
      node = start(admin: [token: "t", port: 0, max_connections: 4, acceptors: 2])
      port = Atanor.admin_port(node.name)
      socks = for _ <- 1..12, do: elem(:gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false]), 1)
      on_exit(fn -> Enum.each(socks, &:gen_tcp.close/1) end)
      listener = Atanor.Admin.listener(node.name)
      Await.until(fn -> length(elem(ThousandIsland.connection_pids(listener), 1)) == 4 end)
      Process.sleep(300)
      assert length(elem(ThousandIsland.connection_pids(listener), 1)) == 4
    end

    test "a client that stops sending its request is dropped after read_timeout_ms" do
      node = start(http: [read_timeout_ms: 300])
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", node.port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\nx-slow: ")

      capture_log(fn -> assert refused?(:gen_tcp.recv(socket, 0, 30_000)) end)
    end

    # Sends one byte to every socket each 100 ms until the task answers, as a client that stays inside
    # read_timeout_ms for ever.
    defp trickle(socks, task) do
      Enum.each(socks, &:gen_tcp.send(&1, "x"))

      case Task.yield(task, 100) do
        nil -> trickle(socks, task)
        {:ok, result} -> result
      end
    end

    test "slow bodies hold no in-flight slot and are cut at body_timeout_ms" do
      node = start(http: [max_in_flight: 4, body_timeout_ms: 500])

      slow =
        for _ <- 1..8 do
          {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", node.port, [:binary, active: false])

          # The 100 Continue comes when the request has been admitted and asks for its body.
          :ok =
            :gen_tcp.send(
              socket,
              "POST /x HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 1000\r\nexpect: 100-continue\r\n\r\n"
            )

          socket
        end

      on_exit(fn -> Enum.each(slow, &:gen_tcp.close/1) end)

      for socket <- slow, do: assert({:ok, "HTTP/1.1 100 " <> _} = :gen_tcp.recv(socket, 0, 10_000))

      # More slow requests than slots, and a normal one is still served.
      assert {200, _, _} = RawHTTP.get(node.port, "/x", "127.0.0.1")

      # They keep sending, a byte inside read_timeout_ms each time, and are cut at the deadline all the same.
      task =
        Task.async(fn ->
          Enum.map(slow, fn socket ->
            Stream.repeatedly(fn -> :gen_tcp.recv(socket, 0, 10_000) end)
            |> Enum.find(&(&1 != {:ok, ""}))
          end)
        end)

      {results, _log} = with_log(fn -> trickle(slow, task) end)
      # A 408, or a reset when the next byte reached the socket the node had already closed.
      cut? = fn
        {:ok, "HTTP/1.1 408 " <> _} -> true
        {:error, reason} -> reason in [:closed, :econnreset]
        _ -> false
      end

      assert Enum.all?(results, cut?)
    end

    test "slow headers on the admin listener are cut and do not lock out a valid token" do
      node = start(admin: [token: "t", port: 0, max_connections: 4, acceptors: 2, header_timeout_ms: 500])
      port = Atanor.admin_port(node.name)
      listener = Atanor.Admin.listener(node.name)

      slow =
        for _ <- 1..4 do
          {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
          :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nhost: x\r\nx-slow: ")
          socket
        end

      on_exit(fn -> Enum.each(slow, &:gen_tcp.close/1) end)
      Await.until(fn -> length(elem(ThousandIsland.connection_pids(listener), 1)) == 4 end)

      # The listener is full: the operator waits for a slot while the others keep sending.
      operator =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

          :ok =
            :gen_tcp.send(
              socket,
              "GET /health HTTP/1.1\r\nhost: x\r\nauthorization: Bearer t\r\nconnection: close\r\n\r\n"
            )

          :gen_tcp.recv(socket, 0, 10_000)
        end)

      assert {:ok, "HTTP/1.1 200 " <> _} = trickle(slow, operator)
    end

    @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

    test "HTTP/2 is served unless it is turned off" do
      node = start()
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", node.port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, @preface)
      # The server's SETTINGS frame (type 4).
      assert {:ok, <<_length::24, 4, _::binary>>} = :gen_tcp.recv(socket, 0, 30_000)

      node = start(http: [http_2: false])
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", node.port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, @preface)
      assert refused?(:gen_tcp.recv(socket, 0, 30_000))
    end
  end

  describe "cell keys" do
    test "a key the placement cannot name is a client error, not unavailability" do
      node = start(workers: [Manifests.probe("k", cells: @cells, routes: [{"127.0.0.1", "/keyed"}])])

      for key <- ["a%20b", String.duplicate("a", 200), "caf%C3%A9", "a%25b"] do
        {status, _, body} = RawHTTP.get(node.port, "/keyed/" <> key, "127.0.0.1")
        assert status == 400, "#{key}: #{status} #{body}"
        assert body =~ "invalid_key"
      end
    end
  end

  describe "crash logs" do
    for module <- [Atanor.Test.CrashWorker, Atanor.Test.CrashPlug] do
      test "do not print the credentials of the request: #{inspect(module)}" do
        node = start(workers: [Manifests.probe("c", module: unquote(module), routes: [{"127.0.0.1", "/crash"}])])

        log =
          capture_log(fn ->
            {500, _, _} =
              RawHTTP.get(node.port, "/crash/x", "127.0.0.1", [
                {"authorization", "Bearer LEAK-123"},
                {"cookie", "sid=LEAK-456"}
              ])
          end)

        assert log =~ "crashed"
        refute log =~ "LEAK-123"
        refute log =~ "LEAK-456"
      end
    end
  end
end
