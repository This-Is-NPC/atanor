defmodule Atanor.RanchTest do
  use ExUnit.Case, async: false

  import Atanor.Test.Await

  alias Atanor.Test.{Manifests, SmtpClient, SmtpWorker, TLS}
  alias AtanorTestkit.Node

  setup do
    dir = TLS.dir!()
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, cert: TLS.generate!(dir, "one", "one.test")}
  end

  defp manifest(opts \\ []) do
    Manifests.probe(
      "smtp",
      Keyword.merge(
        [module: SmtpWorker, cells: %{"smtp" => SmtpWorker.migrations()}, tcp: [{"smtp", :ranch}]],
        opts
      )
    )
  end

  defp tls(cert, opts \\ []) do
    Keyword.merge(
      [certfile: cert.certfile, keyfile: cert.keyfile, handshake_timeout_ms: 2_000, reload_ms: 60_000],
      opts
    )
  end

  defp start(listener, opts \\ []) do
    node =
      Node.start(Keyword.merge([listeners: %{"smtp" => listener, "submission" => [port: 0, protocol: :ranch]}], opts))

    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp deploy(node, opts \\ []) do
    {:ok, deployment} = Node.deploy(node, manifest(opts))
    deployment
  end

  defp port(node) do
    {:ok, port} = Atanor.TCP.port(node.name, "smtp")
    port
  end

  defp stored(node, key) do
    {:ok, %{rows: rows}} = Atanor.Cell.query(node.name, {"smtp", key}, "SELECT body FROM mail ORDER BY id")
    List.flatten(rows)
  end

  defp send_message(client, recipient, body) do
    assert ["250" <> _] = SmtpClient.command(client, "MAIL FROM:<alice>")
    assert ["250" <> _] = SmtpClient.command(client, "RCPT TO:<#{recipient}>")
    assert ["250 stored"] = SmtpClient.data(client, body)
  end

  test "serves SMTP over a plain Ranch listener and writes each message to its cell" do
    node = start(port: 0, protocol: :ranch)
    deployment = deploy(node)

    {:ok, client} = SmtpClient.connect(port(node), :plain)
    assert SmtpClient.recv(client) =~ "atanor #{deployment.id}"
    assert [first | _] = SmtpClient.command(client, "EHLO client")
    assert first =~ "atanor.test"
    send_message(client, "bob", "Subject: hi\r\n\r\nhello bob")
    assert ["221" <> _] = SmtpClient.quit(client)

    assert stored(node, "bob") == ["Subject: hi\r\n\r\nhello bob"]
  end

  test "tells the protocol which listener accepted the connection" do
    node = start(port: 0, protocol: :ranch)
    {:ok, _} = Node.deploy(node, manifest(tcp: [{"smtp", :ranch}, {"submission", :ranch}]))
    {:ok, other} = Atanor.TCP.port(node.name, "submission")

    {:ok, inbound} = SmtpClient.connect(port(node), :plain)
    {:ok, submission} = SmtpClient.connect(other, :plain)

    assert SmtpClient.recv(inbound) =~ ~r/ smtp\z/
    assert SmtpClient.recv(submission) =~ ~r/ submission\z/
  end

  test "guides gen_smtp's own STARTTLS with the listener's TLS options", %{cert: cert} do
    node = start(port: 0, protocol: :ranch, tls_mode: :starttls, tls: tls(cert))
    deploy(node)

    {:ok, client} = SmtpClient.connect(port(node), :plain)
    assert SmtpClient.recv(client) =~ "atanor "
    assert [first | _] = SmtpClient.command(client, "EHLO client")
    assert first =~ "atanor.test"
    {:ok, secure, ["220 OK"]} = SmtpClient.starttls(client)
    assert {:ok, der} = SmtpClient.peer_cert(secure)

    assert der == cert.der
    assert [_ | _] = SmtpClient.command(secure, "EHLO client")
    send_message(secure, "carol", "hello over tls")
    assert ["221" <> _] = SmtpClient.quit(secure)

    assert stored(node, "carol") == ["hello over tls"]
  end

  test "serves implicit TLS over Ranch", %{cert: cert} do
    node = start(port: 0, protocol: :ranch, tls_mode: :implicit, tls: tls(cert))
    deploy(node)

    {:ok, client} = SmtpClient.connect(port(node), :implicit)
    assert SmtpClient.recv(client) =~ "atanor "
    assert {:ok, der} = SmtpClient.peer_cert(client)
    assert der == cert.der
    assert [_ | _] = SmtpClient.command(client, "EHLO client")
    send_message(client, "dave", "hello over implicit tls")
    assert ["221" <> _] = SmtpClient.quit(client)

    assert stored(node, "dave") == ["hello over implicit tls"]
  end

  test "pins the deployment at accept, and closes the listener when it is retired" do
    node = start(port: 0, protocol: :ranch)
    v1 = deploy(node)

    {:ok, old} = SmtpClient.connect(port(node), :plain)
    assert SmtpClient.recv(old) =~ "atanor #{v1.id}"

    v2 = deploy(node, limits: %{"timeout_ms" => 5})
    assert v1.id != v2.id

    {:ok, new} = SmtpClient.connect(port(node), :plain)
    assert SmtpClient.recv(new) =~ "atanor #{v2.id}"
    assert [_ | _] = SmtpClient.command(old, "EHLO client")
    assert [_ | _] = SmtpClient.command(new, "EHLO client")
    send_message(old, "erin", "still the old version")

    assert {:ok, _} = Node.undeploy(node, "smtp")
    assert :error = Atanor.TCP.port(node.name, "smtp")
    assert SmtpClient.closed?(old)
    assert SmtpClient.closed?(new)
  end

  test "closes Ranch connections when the node stops", %{cert: cert} do
    node = start(port: 0, protocol: :ranch, tls_mode: :implicit, tls: tls(cert))
    deploy(node)

    {:ok, client} = SmtpClient.connect(port(node), :implicit)
    assert SmtpClient.recv(client) =~ "atanor "
    :ok = Node.stop(node)
    assert until(fn -> SmtpClient.closed?(client) end)
  end

  test "a connection is closed, and the reason logged, when the worker gives no usable protocol" do
    node = start(port: 0, protocol: :ranch)

    {:ok, _} =
      Node.deploy(
        node,
        manifest(module: Atanor.Test.ScriptedWorker, cells: %{}, tcp: [{"smtp", :ranch}])
      )

    for {answer, reason} <- [
          {:nope, "{:bad_ranch_protocol, :nope}"},
          {{Atanor.NoSuchProtocol, []}, "{:module_not_loaded, Atanor.NoSuchProtocol}"},
          {{:raise, "boom"}, "{:crashed, "},
          {{Atanor.Test.ScriptedWorker, []}, "{:crashed, "}
        ] do
      Atanor.Test.ScriptedWorker.script(answer)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port(node), [:binary, active: false])
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
        end)

      assert log =~ "ranch listener smtp refused a connection: " <> reason
    end
  end

  test "a ranch route needs ranch_protocol/1, and the listener must speak its protocol" do
    node = start(port: 0, protocol: :ranch)

    assert {:error, {:missing_callback, Atanor.Test.ProbeWorker, {:ranch_protocol, 1}}} =
             Node.deploy(node, Manifests.probe("probe", tcp: [{"smtp", :ranch}]))

    node2 = start(port: 0, protocol: :thousand_island)

    assert {:error, {:listener_protocol_mismatch, "smtp", :ranch, :thousand_island}} =
             Node.deploy(node2, manifest())
  end

  test "a port that cannot be bound refuses a ranch activation" do
    {:ok, taken} = :gen_tcp.listen(0, [])
    on_exit(fn -> :gen_tcp.close(taken) end)
    {:ok, port} = :inet.port(taken)

    node = start(port: port, protocol: :ranch)
    assert {:error, {:listener_failed, "smtp", :eaddrinuse}} = Node.deploy(node, manifest())
  end

  test "reports connects and disconnects per Ranch listener" do
    id = "ranch-#{System.unique_integer()}"
    test = self()

    :telemetry.attach_many(
      id,
      [[:atanor, :tcp, :connect], [:atanor, :tcp, :disconnect]],
      fn event, measurements, meta, _ -> send(test, {:telemetry, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    node = start(port: 0, protocol: :ranch)
    deployment = deploy(node)
    {:ok, client} = SmtpClient.connect(port(node), :plain)
    assert SmtpClient.recv(client) =~ "atanor "

    assert_receive {:telemetry, [:atanor, :tcp, :connect], %{count: 1}, meta}
    assert meta.listener == "smtp" and meta.worker == "smtp"
    assert meta.deployment == deployment.id and meta.cell == nil
    assert ["221" <> _] = SmtpClient.quit(client)
    assert_receive {:telemetry, [:atanor, :tcp, :disconnect], %{duration: duration}, %{listener: "smtp"}}
    assert duration >= 0
  end
end
