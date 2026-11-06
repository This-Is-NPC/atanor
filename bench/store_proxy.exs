# A loopback TCP proxy in front of the S3 store that delays every request by a
# fixed time and counts requests by method and path (design §12.10).
#
# The delay is added once per request, before its head is forwarded. Requests
# are told apart on the client side of each connection (head, then a body of
# Content-Length bytes or chunks); responses are copied unparsed.

defmodule Atanor.Bench.StoreProxy do
  @moduledoc false

  use GenServer

  @doc "Starts a proxy to `{host, port}`. Returns `{pid, url}`."
  def start(target_port, delay_ms, target_host \\ ~c"127.0.0.1") do
    {:ok, pid} = GenServer.start(__MODULE__, {target_host, target_port, delay_ms})
    {pid, GenServer.call(pid, :url)}
  end

  def stop(pid), do: GenServer.stop(pid)

  @doc "Requests seen since the last reset, as `%{{method, target} => count}`."
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  def reset(pid), do: GenServer.call(pid, :reset)

  @impl true
  def init({host, port, delay}) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}, backlog: 256])
    {:ok, local} = :inet.port(listener)
    counts = :ets.new(:proxy_counts, [:public, :set, write_concurrency: true])
    state = %{listener: listener, local: local, counts: counts, target: {host, port}, delay: delay}
    parent = self()
    spawn_link(fn -> accept(listener, state, parent) end)
    {:ok, state}
  end

  @impl true
  def handle_call(:url, _from, state), do: {:reply, "http://127.0.0.1:#{state.local}", state}

  def handle_call(:snapshot, _from, state), do: {:reply, Map.new(:ets.tab2list(state.counts)), state}

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.counts)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_, state), do: :gen_tcp.close(state.listener)

  defp accept(listener, state, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        pid = spawn(fn -> serve(client, state) end)
        :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        accept(listener, state, parent)

      {:error, _} ->
        :ok
    end
  end

  defp serve(client, state) do
    receive do
      :go -> :ok
    end

    {host, port} = state.target
    {:ok, upstream} = :gen_tcp.connect(host, port, [:binary, active: false, nodelay: true])
    me = self()

    spawn_link(fn ->
      reply(upstream, client)
      send(me, :done)
    end)

    request(client, upstream, state, "", :head)
    :gen_tcp.close(upstream)
    :gen_tcp.close(client)
  end

  defp reply(from, to) do
    with {:ok, data} <- :gen_tcp.recv(from, 0),
         :ok <- :gen_tcp.send(to, data) do
      reply(from, to)
    end
  end

  # `buffer` holds a partial head; `{:body, left}` skips a body, `:chunked` waits for the last chunk.
  defp request(client, upstream, state, buffer, mode) do
    case :gen_tcp.recv(client, 0) do
      {:ok, data} -> consume(client, upstream, state, buffer <> data, mode)
      {:error, _} -> :ok
    end
  end

  defp consume(client, upstream, state, "", mode), do: request(client, upstream, state, "", mode)

  defp consume(client, upstream, state, buffer, :head) do
    case :binary.split(buffer, "\r\n\r\n") do
      [_] ->
        request(client, upstream, state, buffer, :head)

      [head, rest] ->
        {method, target, mode} = parse(head)
        :ets.update_counter(state.counts, {method, target}, 1, {{method, target}, 0})
        Process.sleep(state.delay)
        :ok = :gen_tcp.send(upstream, [head, "\r\n\r\n"])
        consume(client, upstream, state, rest, mode)
    end
  end

  defp consume(client, upstream, state, buffer, {:body, left}) do
    take = min(left, byte_size(buffer))
    <<body::binary-size(^take), rest::binary>> = buffer
    :ok = :gen_tcp.send(upstream, body)

    if left == take,
      do: consume(client, upstream, state, rest, :head),
      else: request(client, upstream, state, "", {:body, left - take})
  end

  defp consume(client, upstream, state, buffer, :chunked) do
    :ok = :gen_tcp.send(upstream, buffer)

    if String.ends_with?(buffer, "0\r\n\r\n"),
      do: request(client, upstream, state, "", :head),
      else: request(client, upstream, state, "", :chunked)
  end

  defp parse(head) do
    [line | headers] = String.split(head, "\r\n")
    [method, target | _] = String.split(line, " ")

    headers =
      for h <- headers, [k, v] <- [String.split(h, ":", parts: 2)], into: %{}, do: {String.downcase(k), String.trim(v)}

    mode =
      cond do
        headers["transfer-encoding"] == "chunked" -> :chunked
        (n = String.to_integer(headers["content-length"] || "0")) > 0 -> {:body, n}
        true -> :head
      end

    {method, target, mode}
  end
end
