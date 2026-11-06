defmodule Atanor.Test.RawHTTP do
  @moduledoc "Sends HTTP/1.1 requests byte for byte over a socket, for inputs a client library would normalise."

  @doc """
  Sends `request` (the request line and header lines, without the final blank
  line) and returns `{status, headers, body}`; `headers` is a list of
  `{lowercase_name, value}`. The connection is closed after the answer.
  """
  def request(port, request_line, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    lines = [request_line | Enum.map(headers, fn {name, value} -> "#{name}: #{value}" end)]
    :ok = :gen_tcp.send(socket, Enum.join(lines ++ ["connection: close", "", ""], "\r\n"))
    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    parse(response)
  end

  @doc "A request to `path` on `host`, with the extra `headers`."
  def get(port, path, host, headers \\ []), do: request(port, "GET #{path} HTTP/1.1", [{"host", host} | headers])

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, _} -> acc
    end
  end

  defp parse("HTTP/1.1 " <> <<status::binary-size(3), _::binary>> = response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [_ | lines] = String.split(head, "\r\n")

    headers =
      for line <- lines, [name, value] = String.split(line, ": ", parts: 2), do: {String.downcase(name), value}

    {String.to_integer(status), headers, body}
  end

  defp parse(other), do: {:no_response, [], other}
end
