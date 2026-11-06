defmodule Atanor.TLSTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Atanor.Test.Await

  alias Atanor.Test.{LineWorker, Manifests, TLS}
  alias AtanorTestkit.Node

  @token "tls-admin-token"

  setup do
    dir = TLS.dir!()
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, cert: TLS.generate!(dir, "one", "one.test")}
  end

  defp manifest(opts \\ []) do
    Manifests.probe(
      "mail",
      Keyword.merge([module: LineWorker, cells: %{"mail" => LineWorker.migrations()}, tcp: ["smtp"]], opts)
    )
  end

  defp tls(cert, opts \\ []) do
    Keyword.merge(
      [certfile: cert.certfile, keyfile: cert.keyfile, reload_ms: 50, handshake_timeout_ms: 2_000],
      opts
    )
  end

  defp start(cert, mode, opts \\ [], tls_opts \\ []) do
    listeners = %{"smtp" => [port: 0, tls_mode: mode, tls: tls(cert, tls_opts)]}
    node = Node.start(Keyword.merge([listeners: listeners], opts))
    on_exit(fn -> Node.stop(node) end)
    {:ok, _} = Node.deploy(node, manifest())
    node
  end

  defp port(node) do
    {:ok, port} = Atanor.TCP.port(node.name, "smtp")
    port
  end

  defp connect(node) do
    {:ok, socket} = connect_with(node, [])
    socket
  end

  defp connect_with(node, opts) do
    :ssl.connect(
      ~c"127.0.0.1",
      port(node),
      [verify: :verify_none, active: false, mode: :binary, packet: :line] ++ opts,
      5_000
    )
  end

  defp connect_tcp(node) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port(node), [:binary, active: false, packet: :line])
    socket
  end

  defp peer_der(socket) do
    {:ok, der} = :ssl.peercert(socket)
    der
  end

  defp line(:tcp, socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    String.trim_trailing(line)
  end

  defp line(:ssl, socket) do
    {:ok, line} = :ssl.recv(socket, 0, 5_000)
    String.trim_trailing(line)
  end

  defp say(:tcp, socket, text) do
    :ok = :gen_tcp.send(socket, text <> "\r\n")
    line(:tcp, socket)
  end

  defp say(:ssl, socket, text) do
    :ok = :ssl.send(socket, text <> "\r\n")
    line(:ssl, socket)
  end

  defp closed?(socket), do: match?({:error, _}, :gen_tcp.recv(socket, 0, 5_000))

  describe "listener options" do
    defp build(tls, mode \\ :implicit, listeners \\ nil) do
      listeners = listeners || %{"smtp" => [port: 0, tls_mode: mode, tls: tls]}

      Atanor.Config.build(data_dir: "/tmp/atanor-config", store: {Mod, nil}, listeners: listeners)
    end

    test "validates the files, the key and the TLS options", %{dir: dir, cert: cert} do
      other = TLS.generate!(dir, "other", "other.test")
      ca = TLS.generate_ca!(dir)

      for {opts, message} <- [
            {[certfile: cert.certfile, keyfile: cert.keyfile, nope: 1], ~r/unknown options/},
            {[certfile: cert.certfile], ~r/:keyfile is required/},
            {[certfile: "/nonexistent", keyfile: cert.keyfile], ~r/cannot read/},
            {[certfile: cert.certfile, keyfile: other.keyfile], ~r/does not belong/},
            {[certfile: cert.certfile, keyfile: cert.keyfile, versions: [:tlsv1]], ~r/:versions/},
            {[certfile: cert.certfile, keyfile: cert.keyfile, verify: :verify_peer], ~r/needs :cacertfile/},
            {[certfile: cert.certfile, keyfile: cert.keyfile, fail_if_no_peer_cert: true],
             ~r/only valid with :verify_peer/},
            {[certfile: cert.certfile, keyfile: cert.keyfile, fail_if_no_peer_cert: false],
             ~r/only valid with :verify_peer/},
            {[
               certfile: cert.certfile,
               keyfile: cert.keyfile,
               cacertfile: ca.certfile,
               verify: :verify_peer,
               fail_if_no_peer_cert: :yes
             ], ~r/:fail_if_no_peer_cert/},
            {[certfile: cert.certfile, keyfile: cert.keyfile, handshake_timeout_ms: 0], ~r/handshake_timeout_ms/},
            {[certfile: cert.certfile, keyfile: cert.keyfile, reload_ms: -1], ~r/reload_ms/}
          ] do
        assert_raise ArgumentError, message, fn -> build(opts) end
      end

      assert_raise ArgumentError, ~r/:tls_mode needs :tls/, fn ->
        build(nil, :implicit, %{"smtp" => [port: 0, tls_mode: :implicit]})
      end

      assert_raise ArgumentError, ~r/:tls needs :tls_mode/, fn ->
        build([certfile: cert.certfile, keyfile: cert.keyfile], nil, %{
          "smtp" => [port: 0, tls: [certfile: cert.certfile, keyfile: cert.keyfile]]
        })
      end

      assert_raise ArgumentError, ~r/:protocol/, fn ->
        build([certfile: cert.certfile, keyfile: cert.keyfile], :implicit, %{
          "smtp" => [
            port: 0,
            protocol: :udp,
            tls_mode: :implicit,
            tls: [certfile: cert.certfile, keyfile: cert.keyfile]
          ]
        })
      end

      assert %Atanor.Config{} =
               config =
               build(
                 certfile: cert.certfile,
                 keyfile: cert.keyfile,
                 cacertfile: ca.certfile,
                 verify: :verify_peer,
                 fail_if_no_peer_cert: true
               )

      assert config.listeners["smtp"].tls.fail_if_no_peer_cert

      assert_raise ArgumentError, ~r/:acceptors/, fn ->
        build([certfile: cert.certfile, keyfile: cert.keyfile], :implicit, %{
          "smtp" => [
            port: 0,
            acceptors: 10,
            max_connections: 5,
            tls_mode: :implicit,
            tls: [certfile: cert.certfile, keyfile: cert.keyfile]
          ]
        })
      end
    end

    test "names what is wrong with a certificate or key file", %{dir: dir, cert: cert} do
      openssl = fn args -> {_, 0} = System.cmd("openssl", args, stderr_to_stdout: true) end
      empty = Path.join(dir, "empty.pem")
      File.write!(empty, "nothing here\n")
      encrypted = Path.join(dir, "encrypted-key.pem")
      openssl.(["pkey", "-in", cert.keyfile, "-aes256", "-passout", "pass:secret", "-out", encrypted])
      two_keys = Path.join(dir, "two-keys.pem")
      File.write!(two_keys, File.read!(cert.keyfile) <> File.read!(cert.keyfile))
      k1 = Path.join(dir, "k1-key.pem")
      k1_cert = Path.join(dir, "k1-cert.pem")
      openssl.(["ecparam", "-name", "secp256k1", "-genkey", "-noout", "-out", k1])
      openssl.(["req", "-x509", "-key", k1, "-out", k1_cert, "-days", "1", "-subj", "/CN=k1"])
      k1_bare = Path.join(dir, "k1-bare-key.pem")
      openssl.(["ec", "-in", k1, "-no_public", "-out", k1_bare])
      bad_cert = Path.join(dir, "bad-cert.pem")
      File.write!(bad_cert, "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")

      for {opts, message} <- [
            {[certfile: empty, keyfile: cert.keyfile], "#{empty} has no certificate"},
            {[certfile: cert.certfile, keyfile: empty], "#{empty} has no private key"},
            {[certfile: cert.certfile, keyfile: encrypted], "#{encrypted} holds an encrypted private key"},
            {[certfile: cert.certfile, keyfile: two_keys], "unsupported private key type :multiple"},
            {[certfile: bad_cert, keyfile: cert.keyfile], "the certificate cannot be parsed: "},
            {[certfile: k1_cert, keyfile: k1_bare], "unsupported private key type {:namedCurve, {1, 3, 132, 0, 10}}"}
          ] do
        error =
          try do
            build(opts)
            flunk("no error for #{message}")
          rescue
            e in ArgumentError -> e
          end

        assert error.message =~ ":listeners entry \"smtp\" tls: " <> message
      end
    end

    test "formats a configuration error for logs and the admin API" do
      format = &Atanor.TCP.TLS.format_error/1
      assert format.({:pem, "/p"}) == "/p is not a valid PEM file"
      assert format.({:no_key, "/p"}) == "/p has no private key"
      assert format.({:unsupported_key, :dsa}) == "unsupported private key type :dsa"
      assert format.(:key_mismatch) == "the private key does not belong to the certificate"
      assert format.({:file, "/p", :enoent}) == "cannot read /p: no such file or directory"
      assert format.(:other) == ":other"
    end

    test "accepts EC and Ed25519 keys that belong to their certificate", %{dir: dir} do
      for type <- [:ec, :ed25519] do
        cert = TLS.generate!(dir, "#{type}", "#{type}.test", type)

        assert %Atanor.Config{} = config = build(certfile: cert.certfile, keyfile: cert.keyfile)
        assert config.listeners["smtp"].tls.certfile == cert.certfile
      end
    end
  end

  test "requires a client certificate when fail_if_no_peer_cert is true", %{dir: dir, cert: cert} do
    ca = TLS.generate_ca!(dir)
    client = TLS.generate_client!(dir, "client", ca)

    node =
      start(cert, :implicit, [],
        cacertfile: ca.certfile,
        verify: :verify_peer,
        fail_if_no_peer_cert: true
      )

    {:ok, refused} = connect_with(node, [])

    assert {:error, {:tls_alert, {:certificate_required, _}}} = :ssl.recv(refused, 0, 5_000)

    {:ok, socket} = connect_with(node, certfile: client.certfile, keyfile: client.keyfile)

    assert line(:ssl, socket) == "220 smtp ready"
    assert say(:ssl, socket, "HELO client") == "250 hello client"
  end

  test "a client certificate is required by default with verify_peer", %{dir: dir, cert: cert} do
    ca = TLS.generate_ca!(dir)
    node = start(cert, :implicit, [], cacertfile: ca.certfile, verify: :verify_peer)
    {:ok, refused} = connect_with(node, [])
    assert {:error, {:tls_alert, {:certificate_required, _}}} = :ssl.recv(refused, 0, 5_000)

    # Accepting clients without a certificate is explicit.
    node = start(cert, :implicit, [], cacertfile: ca.certfile, verify: :verify_peer, fail_if_no_peer_cert: false)
    assert line(:ssl, connect(node)) == "220 smtp ready"
  end

  test "clients cannot renegotiate", %{cert: cert} do
    node = start(cert, :implicit, [], versions: [:"tlsv1.2"])
    {:ok, ssl} = Atanor.TCP.TLS.options(node.name, "smtp")
    assert ssl[:client_renegotiation] == false
  end

  test "the certificate cache keeps the private key out of its process state", %{cert: cert} do
    node = start(cert, :implicit)
    {:ok, ssl} = Atanor.TCP.TLS.options(node.name, "smtp")
    {_type, der} = ssl[:key]

    state = :sys.get_state(Module.concat([node.name, :TLS]))
    assert :binary.match(:erlang.term_to_binary(state), der) == :nomatch

    # The handshakes still read it.
    assert line(:ssl, connect(node)) == "220 smtp ready"
  end

  test "stopping the node erases its certificate cache", %{cert: cert} do
    node = start(cert, :implicit)
    assert {:ok, _} = Atanor.TCP.TLS.options(node.name, "smtp")

    Node.stop(node)
    assert :persistent_term.get({Atanor.TCP.TLS, node.name}, :erased) == :erased
  end

  test "serves implicit TLS with the configured certificate", %{cert: cert} do
    node = start(cert, :implicit)
    socket = connect(node)

    assert line(:ssl, socket) == "220 smtp ready"
    assert peer_der(socket) == cert.der
    assert say(:ssl, socket, "HELO client") == "250 hello client"
    assert say(:ssl, socket, "RCPT bob") == "250 ok"
    assert say(:ssl, socket, "DATA") == "354 go ahead"
    :ok = :ssl.send(socket, "Subject: hi\r\n\r\nhello over tls\r\n")
    assert say(:ssl, socket, ".") == "250 stored"

    {:ok, %{rows: rows}} = Atanor.Cell.query(node.name, {"mail", "bob"}, "SELECT body FROM mail")
    assert List.flatten(rows) == ["Subject: hi\n\nhello over tls"]
  end

  test "upgrades a native handle_tcp worker with STARTTLS", %{cert: cert} do
    node = start(cert, :starttls)
    tcp = connect_tcp(node)

    assert line(:tcp, tcp) == "220 smtp ready"
    assert say(:tcp, tcp, "HELO client") == "250 hello client"
    assert say(:tcp, tcp, "STARTTLS") == "220 Ready to start TLS"

    {:ok, socket} = :ssl.connect(tcp, [verify: :verify_none, active: false, mode: :binary], 5_000)
    :ok = :ssl.setopts(socket, packet: :line)
    assert peer_der(socket) == cert.der

    assert say(:ssl, socket, "RCPT carol") == "250 ok"
    assert say(:ssl, socket, "DATA") == "354 go ahead"
    :ok = :ssl.send(socket, "hello carol\r\n")
    assert say(:ssl, socket, ".") == "250 stored"

    {:ok, %{rows: rows}} = Atanor.Cell.query(node.name, {"mail", "carol"}, "SELECT body FROM mail")
    assert List.flatten(rows) == ["hello carol"]
  end

  test "refuses STARTTLS from a plain listener and closes the connection" do
    node = Node.start(listeners: %{"smtp" => 0})
    on_exit(fn -> Node.stop(node) end)
    {:ok, _} = Node.deploy(node, manifest())
    tcp = connect_tcp(node)

    log =
      capture_log(fn ->
        assert line(:tcp, tcp) == "220 smtp ready"
        assert say(:tcp, tcp, "STARTTLS") == "220 Ready to start TLS"
        assert closed?(tcp)
      end)

    assert log =~ "refuses STARTTLS"
  end

  test "new STARTTLS upgrades use a reloaded certificate", %{dir: dir, cert: cert} do
    node = start(cert, :starttls)
    old = connect_tcp(node)
    assert line(:tcp, old) == "220 smtp ready"
    assert say(:tcp, old, "STARTTLS") == "220 Ready to start TLS"
    {:ok, old_tls} = :ssl.connect(old, [verify: :verify_none, active: false, mode: :binary], 5_000)
    assert peer_der(old_tls) == cert.der

    second = TLS.generate!(dir, "two", "two.test")
    TLS.install!(second, cert)

    assert until(fn ->
             tcp = connect_tcp(node)
             line(:tcp, tcp) == "220 smtp ready"
             "220 Ready to start TLS" = say(:tcp, tcp, "STARTTLS")
             {:ok, tls} = :ssl.connect(tcp, [verify: :verify_none, active: false, mode: :binary], 5_000)
             der = peer_der(tls)
             :ssl.close(tls)
             der == second.der
           end)

    :ok = :ssl.setopts(old_tls, packet: :line)
    assert say(:ssl, old_tls, "HELO still") == "250 hello still"
  end

  test "reloads a changed certificate without dropping open connections", %{dir: dir, cert: cert} do
    instance = self()

    :telemetry.attach(
      "tls-reload",
      [:atanor, :tls, :reload],
      fn event, measurements, meta, _ -> send(instance, {:telemetry, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("tls-reload") end)

    node = start(cert, :implicit)
    old = connect(node)
    assert line(:ssl, old) == "220 smtp ready"
    assert peer_der(old) == cert.der

    second = TLS.generate!(dir, "two", "two.test")
    TLS.install!(second, cert)

    assert until(fn ->
             socket = connect(node)
             line(:ssl, socket) == "220 smtp ready"
             peer_der(socket) == second.der
           end)

    assert_receive {:telemetry, [:atanor, :tls, :reload], %{count: 1}, %{listener: "smtp", cause: :poll, result: :ok}}

    # The connection that negotiated the old certificate keeps its session.
    assert say(:ssl, old, "HELO still") == "250 hello still"

    # A broken new certificate keeps the old one, and says so.
    TLS.break!(cert.certfile)

    assert_receive {:telemetry, [:atanor, :tls, :reload], %{count: 1}, %{listener: "smtp", result: {:error, _}}},
                   2_000

    socket = connect(node)
    assert line(:ssl, socket) == "220 smtp ready"
    assert peer_der(socket) == second.der
  end

  test "reloads one listener from the admin API", %{dir: dir, cert: cert} do
    node =
      start(cert, :implicit, [admin: [token: @token, port: 0]], reload_ms: 60_000)

    post = fn listener ->
      url = "http://127.0.0.1:#{Atanor.admin_port(node.name)}/listeners/#{listener}/reload-tls"

      Req.post!(url,
        headers: [{"authorization", "Bearer " <> @token}],
        retry: false,
        decode_body: false
      )
    end

    response = post.("smtp")
    assert response.status == 200
    assert Jason.decode!(response.body) == %{"listener" => "smtp", "reloaded" => true}

    second = TLS.generate!(dir, "two", "two.test")
    TLS.install!(second, cert)

    assert %{status: 200} = post.("smtp")
    socket = connect(node)
    assert line(:ssl, socket) == "220 smtp ready"
    assert peer_der(socket) == second.der

    TLS.break!(cert.certfile)
    assert %{status: 422} = failed = post.("smtp")
    assert Jason.decode!(failed.body)["error"] == "reload_failed"

    # The previous certificate still serves new connections.
    socket = connect(node)
    assert line(:ssl, socket) == "220 smtp ready"
    assert peer_der(socket) == second.der

    assert %{status: 404} = post.("nope")
  end

  test "a reload of a listener without TLS is refused", %{cert: cert} do
    node =
      Node.start(
        listeners: %{
          "smtp" => [port: 0, tls_mode: :implicit, tls: tls(cert)],
          "imap" => 0
        },
        admin: [token: @token, port: 0]
      )

    on_exit(fn -> Node.stop(node) end)

    url = "http://127.0.0.1:#{Atanor.admin_port(node.name)}/listeners/imap/reload-tls"
    response = Req.post!(url, headers: [{"authorization", "Bearer " <> @token}], retry: false, decode_body: false)
    assert response.status == 409
    assert Jason.decode!(response.body) == %{"error" => "no_tls"}
  end

  test "reports implicit and STARTTLS handshakes", %{cert: cert} do
    instance = self()

    :telemetry.attach_many(
      "tls-handshakes",
      [[:atanor, :tls, :handshake], [:atanor, :tls, :starttls]],
      fn event, measurements, meta, _ -> send(instance, {:telemetry, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("tls-handshakes") end)

    implicit = start(cert, :implicit)
    implicit_name = implicit.name
    socket = connect(implicit)
    assert line(:ssl, socket) == "220 smtp ready"

    assert_receive {:telemetry, [:atanor, :tls, :handshake], %{duration: duration},
                    %{instance: ^implicit_name, listener: "smtp", mode: :implicit, result: :ok}}

    assert duration >= 0

    starttls = start(cert, :starttls)
    starttls_name = starttls.name
    tcp = connect_tcp(starttls)
    assert line(:tcp, tcp) == "220 smtp ready"
    assert say(:tcp, tcp, "STARTTLS") == "220 Ready to start TLS"
    {:ok, _socket} = :ssl.connect(tcp, [verify: :verify_none, active: false, mode: :binary], 5_000)

    assert_receive {:telemetry, [:atanor, :tls, :handshake], %{duration: _},
                    %{instance: ^starttls_name, listener: "smtp", mode: :starttls, result: :ok}}

    assert_receive {:telemetry, [:atanor, :tls, :starttls], %{count: 1},
                    %{instance: ^starttls_name, listener: "smtp", result: :ok}}
  end
end
