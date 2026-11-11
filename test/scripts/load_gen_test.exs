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

  defp accept_forever(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, _socket} -> accept_forever(listen)
      {:error, _} -> :ok
    end
  end
end
