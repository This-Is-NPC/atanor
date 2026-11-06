# A small HTTP load generator for the benchmarks: keep-alive connections over
# :gen_tcp, so the client costs little next to the node it measures.

defmodule Atanor.Bench.Load do
  @moduledoc false

  @doc """
  Runs `clients` connections to `port` until `limit` ends: `{:seconds, s}` or
  `{:requests, n}`. `request` is `fn i -> {method, path, headers, body} end`
  for the i-th request (counted from 0). Returns the count, errors (any status
  other than 200), requests per second and latency percentiles and maximum in ms.
  """
  def run(port, clients, limit, request) do
    counter = :atomics.new(1, [])
    started = System.monotonic_time(:millisecond)
    deadline = with {:seconds, s} <- limit, do: started + s * 1000

    results =
      1..clients
      |> Task.async_stream(fn _ -> client(port, counter, limit, deadline, request, [], 0) end,
        max_concurrency: clients,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    elapsed = (System.monotonic_time(:millisecond) - started) / 1000
    latencies = results |> Enum.flat_map(&elem(&1, 0)) |> Enum.sort()
    count = length(latencies)
    errors = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    %{
      count: count,
      errors: errors,
      seconds: elapsed,
      rps: round(count / elapsed),
      p50: percentile(latencies, 0.50),
      p95: percentile(latencies, 0.95),
      p99: percentile(latencies, 0.99),
      p999: percentile(latencies, 0.999),
      max: percentile(latencies, 1.0)
    }
  end

  defp percentile([], _), do: nil
  defp percentile(sorted, p), do: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p))) |> Float.round(3)

  defp client(port, counter, limit, deadline, request, latencies, errors) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :http_bin, nodelay: true])
    loop(socket, counter, limit, deadline, request, latencies, errors)
  end

  defp loop(socket, counter, limit, deadline, request, latencies, errors) do
    i = :atomics.add_get(counter, 1, 1) - 1

    if done?(limit, deadline, i) do
      :gen_tcp.close(socket)
      {latencies, errors}
    else
      {method, path, headers, body} = request.(i)
      started = System.monotonic_time(:microsecond)
      status = exchange(socket, method, path, headers, body)
      micros = System.monotonic_time(:microsecond) - started
      errors = if status == 200, do: errors, else: errors + 1
      loop(socket, counter, limit, deadline, request, [micros / 1000 | latencies], errors)
    end
  end

  defp done?({:requests, n}, _deadline, i), do: i >= n
  defp done?({:seconds, _}, deadline, _i), do: System.monotonic_time(:millisecond) >= deadline

  defp exchange(socket, method, path, headers, body) do
    head = Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end)

    :ok =
      :gen_tcp.send(socket, [method, " ", path, " HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: ", Integer.to_string(byte_size(body)), "\r\n", head, "\r\n", body])

    {:ok, {:http_response, _, status, _}} = :gen_tcp.recv(socket, 0, 30_000)
    length = read_headers(socket, 0)
    :ok = :inet.setopts(socket, packet: :raw)
    if length > 0, do: {:ok, _} = :gen_tcp.recv(socket, length, 30_000)
    :ok = :inet.setopts(socket, packet: :http_bin)
    status
  end

  defp read_headers(socket, length) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, :http_eoh} -> length
      {:ok, {:http_header, _, :"Content-Length", _, value}} -> read_headers(socket, String.to_integer(value))
      {:ok, {:http_header, _, _, _, _}} -> read_headers(socket, length)
    end
  end

  def machine do
    cpu = "/proc/cpuinfo" |> File.read!() |> then(&Regex.run(~r/model name\s*:\s*(.+)/, &1)) |> List.last()
    "#{cpu}, #{System.schedulers_online()} schedulers, Erlang/OTP #{:erlang.system_info(:otp_release)}, Elixir #{System.version()}"
  end

  def row(label, r),
    do: "#{String.pad_trailing(label, 34)} #{String.pad_leading(Integer.to_string(r.rps), 8)} req/s  p50 #{r.p50} ms  p95 #{r.p95} ms  p99 #{r.p99} ms  errors #{r.errors}/#{r.count}"
end
