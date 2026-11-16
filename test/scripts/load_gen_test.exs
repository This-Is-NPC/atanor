defmodule Atanor.LoadGenTest do
  use ExUnit.Case, async: true

  # A service that accepts connections and never answers: the saturated case of a load step.
  test "a saturated service yields a document with the unanswered requests, not a crash" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    acceptor = spawn_link(fn -> accept_forever(listen) end)

    {out, status} =
      System.cmd(
        Path.expand("scripts/load-gen"),
        ~w(http --host 127.0.0.1 --kind native --rate 20 --duration 2 --conns 2 --timeout 1 --port #{port}),
        stderr_to_stdout: true
      )

    Process.unlink(acceptor)
    Process.exit(acceptor, :kill)
    :gen_tcp.close(listen)

    assert status == 0, out
    document = :json.decode(out)
    assert document["planned"] == 40
    statuses = document["statuses"]
    assert statuses["error: not completed"] > 0
    assert statuses["error: not completed"] + document["completed"] == 40
  end

  test "the plain WASM kind sends the native worker's requests to its own host and path" do
    code = """
    import importlib.machinery, importlib.util, json, sys
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("load_gen", sys.argv[1])
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("load_gen", loader))
    loader.exec_module(module)
    print(json.dumps([module.request_for(kind, "t", 3, write, 7) for kind in ("native", "plain", "wasm") for write in (True, False)]))
    """

    {out, 0} = System.cmd("python3", ["-I", "-c", code, Path.expand("scripts/load-gen")])

    assert :json.decode(out) == [
             ["POST", "/native/t-3", "load.localhost"],
             ["GET", "/native/t-3", "load.localhost"],
             ["POST", "/plain/t-3", "loadwasm.localhost"],
             ["GET", "/plain/t-3", "loadwasm.localhost"],
             ["POST", "/rooms/t-3/scores?id=t-7&player=ada&points=1", "scoreboard.localhost"],
             ["GET", "/rooms/t-3", "scoreboard.localhost"]
           ]
  end

  # Two connections against a service of 0.4 s per answer cannot carry 20 req/s: requests wait for a free connection (lag),
  # but the generator itself releases each on time (release lag), which is how a slow node is told from a stalled generator.
  test "a slow service adds to the lag, not to the release lag" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    acceptor = spawn_link(fn -> accept_slowly(listen) end)

    {out, status} =
      System.cmd(
        Path.expand("scripts/load-gen"),
        ~w(http --host 127.0.0.1 --kind native --rate 20 --duration 2 --conns 2 --timeout 1 --port #{port}),
        stderr_to_stdout: true
      )

    Process.unlink(acceptor)
    Process.exit(acceptor, :kill)
    :gen_tcp.close(listen)

    assert status == 0, out
    document = :json.decode(out)
    assert document["lag_ms"]["p99"] > 300
    assert document["release_lag_ms"]["p99"] < 100
  end

  # The opening of a cells run is recorded apart: its statuses and histogram are the writes that woke each cell, the rest is the hold.
  test "a cells run reports the opening writes apart from the hold" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    acceptor = spawn_link(fn -> accept_answering(listen) end)

    {out, status} =
      System.cmd(
        Path.expand("scripts/load-gen"),
        ~w(cells --host 127.0.0.1 --kind native --cells 5 --period 1 --duration 2 --settle 0 --open-rate 50 --conns 2 --timeout 2 --port #{port}),
        stderr_to_stdout: true
      )

    Process.unlink(acceptor)
    Process.exit(acceptor, :kill)
    :gen_tcp.close(listen)

    assert status == 0, out
    document = :json.decode(out)
    assert document["planned"] == 15
    assert document["opening"]["planned"] == 5
    assert document["opening"]["statuses"] == %{"200" => 5}
    assert document["opening"]["hist"] |> Map.values() |> Enum.sum() == 5
    assert document["statuses"]["200"] == 15
    assert document["hist"] |> Map.values() |> Enum.sum() == 15
  end

  defp accept_answering(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> answer_now(socket) end)
        :gen_tcp.controlling_process(socket, pid)
        accept_answering(listen)

      {:error, _} ->
        :ok
    end
  end

  defp answer_now(socket) do
    with {:ok, _request} <- :gen_tcp.recv(socket, 0) do
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
      answer_now(socket)
    end
  end

  defp accept_slowly(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> answer_slowly(socket) end)
        :gen_tcp.controlling_process(socket, pid)
        accept_slowly(listen)

      {:error, _} ->
        :ok
    end
  end

  defp answer_slowly(socket) do
    with {:ok, _request} <- :gen_tcp.recv(socket, 0) do
      Process.sleep(400)
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
      answer_slowly(socket)
    end
  end

  defp accept_forever(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, _socket} -> accept_forever(listen)
      {:error, _} -> :ok
    end
  end
end
