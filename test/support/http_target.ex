defmodule Atanor.Test.HTTPTarget do
  @moduledoc """
  A local Bandit server used as the target of outbound HTTP. It reports every
  request to the test as `{:target_hit, path}` and `{:target_headers, path, headers}`.
  """
  @behaviour Plug

  import Plug.Conn

  @doc "Starts the server on an ephemeral port; returns its pid and port."
  def start(test_pid) do
    {:ok, pid} = Bandit.start_link(plug: {__MODULE__, test_pid}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {pid, port}
  end

  @impl true
  def init(test_pid), do: test_pid

  @impl true
  def call(conn, test_pid) do
    send(test_pid, {:target_hit, conn.request_path})
    send(test_pid, {:target_headers, conn.request_path, conn.req_headers})
    conn = fetch_query_params(conn)

    case conn.request_path do
      "/redirect-to" -> conn |> put_resp_header("location", conn.query_params["to"]) |> send_resp(302, "")
      "/big" -> stream(conn, String.to_integer(conn.query_params["bytes"]))
      "/drip" -> drip(send_chunked(conn, 200))
      "/hang" -> conn |> send_chunked(200) |> hang()
      "/redirect-in" -> conn |> put_resp_header("location", "/ok") |> send_resp(302, "")
      "/redirect-loop" -> conn |> put_resp_header("location", "/redirect-loop") |> send_resp(302, "")
      "/redirect-out" -> conn |> put_resp_header("location", "http://localhost:#{conn.port}/ok") |> send_resp(302, "")
      _ -> send_resp(conn, 200, "hello")
    end
  end

  # Streams `bytes` of zeros in 64 KiB chunks, stopping when the client goes away.
  defp stream(conn, bytes) do
    conn = send_chunked(conn, 200)
    chunk = :binary.copy(<<0>>, 65_536)

    Enum.reduce_while(1..max(div(bytes, 65_536), 1), conn, fn _, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  # One byte every 20 ms until the client goes away.
  defp drip(conn) do
    Process.sleep(20)

    case chunk(conn, "x") do
      {:ok, conn} -> drip(conn)
      {:error, _} -> conn
    end
  end

  # Sends the headers and then nothing, until the test ends.
  defp hang(_conn), do: Process.sleep(:infinity)
end
