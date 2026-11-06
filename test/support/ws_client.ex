defmodule Atanor.Test.WSClient do
  @moduledoc "A small synchronous WebSocket client over Mint.WebSocket for tests."

  defstruct [:conn, :ref, :websocket, buffer: []]

  @doc "Connects and upgrades. `{:error, status, body}` when the server answers without upgrading."
  def connect(port, path, headers \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :active)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)
    {conn, responses} = await_response(conn, ref, [])

    status =
      Enum.find_value(responses, fn
        {:status, ^ref, status} -> status
        _ -> nil
      end)

    resp_headers =
      Enum.find_value(responses, fn
        {:headers, ^ref, h} -> h
        _ -> nil
      end)

    body = for {:data, ^ref, data} <- responses, into: "", do: data

    case Mint.WebSocket.new(conn, ref, status, resp_headers) do
      {:ok, conn, websocket} -> {:ok, %__MODULE__{conn: conn, ref: ref, websocket: websocket}}
      {:error, conn, _} -> Mint.HTTP.close(conn) && {:error, status, body}
    end
  end

  # Only the messages of this connection's socket, so several clients can share a process.
  defp message_for(conn, timeout, fun) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      message when is_tuple(message) and tuple_size(message) >= 2 and elem(message, 1) == socket -> fun.(message)
    after
      timeout -> :timeout
    end
  end

  defp await_response(conn, ref, acc) do
    message_for(conn, 5_000, fn message ->
      {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)
      acc = acc ++ responses
      if Enum.any?(acc, &match?({:done, ^ref}, &1)), do: {conn, acc}, else: await_response(conn, ref, acc)
    end)
    |> case do
      :timeout -> raise "no upgrade response"
      result -> result
    end
  end

  def send_frame(%__MODULE__{} = client, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(client.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    %{client | conn: conn, websocket: websocket}
  end

  @doc "The next frame, `:timeout`, or `:closed` when the connection ended."
  def recv(%__MODULE__{buffer: [frame | rest]} = client, _timeout), do: {frame, %{client | buffer: rest}}

  def recv(%__MODULE__{} = client, timeout) do
    result =
      message_for(client.conn, timeout, fn message ->
        case Mint.WebSocket.stream(client.conn, message) do
          {:ok, conn, responses} ->
            data = for {:data, _, data} <- responses, into: "", do: data
            {:ok, websocket, frames} = Mint.WebSocket.decode(client.websocket, data)
            {:frames, %{client | conn: conn, websocket: websocket, buffer: frames}}

          {:error, conn, %Mint.TransportError{reason: :closed}, _} ->
            {:closed, %{client | conn: conn}}
        end
      end)

    case result do
      :timeout -> {:timeout, client}
      {:frames, client} -> recv(client, timeout)
      {:closed, client} -> {:closed, client}
    end
  end

  def close(%__MODULE__{conn: conn}), do: Mint.HTTP.close(conn)
end
