# Load generator, checker and reporter of the cluster lab (docs/how-to-run-the-cluster-lab.md).
#
#   elixir lab/tools/load.exs run    --nodes IP,IP,IP --log FILE [--seconds 30] [--clients 12] [--cells 24] [--think 20] [--timeout 10000]
#   elixir lab/tools/load.exs hot    --nodes IP,IP,IP --log FILE [--seconds 60] [--http 48] [--ws 300] [--ws-think 500] [--timeout 10000]
#                                    [--cursors 0] [--cursor-ms 1000] [--cursor-mode cell|channel]
#                                    [--partitions 0] [--keys 1000] [--read-bound 0]
#   elixir lab/tools/load.exs verify --nodes IP,IP,IP --log FILE [--partitions 0]
#   elixir lab/tools/load.exs report --log FILE [--event NAME=EPOCH_MS]... [--window NAME=FROM_MS,TO_MS]... [--victim IP]
#                                    [--local-only|--forwarded-only]
#
# `run` sends `POST /c/CELL` with a unique number through the HTTP port (4000) of the nodes in turn and
# writes one line per request: start_ms end_ms ingress cell n status handler row_id. `verify` reads every
# cell back and compares it with the acknowledged writes. `report` summarizes a log. `hot` keeps HTTP
# connections and WebSockets open on the three nodes and sends writes and reads to ONE cell; the writes go to
# FILE (same format, so `verify` and `report` work) and the reads to FILE.reads. With `--cursors N`, N of the
# WebSockets also send a cursor frame every `--cursor-ms`, which every WebSocket of the cell receives: through the
# owner and `send_to_cell` (`cell`) or through the ephemeral channel (`channel`). The frame carries the send time,
# so each receiver measures the delivery latency (all clients run in this process, on one clock). With
# `--read-bound MS` the reads are bounded requests (`?count=1&ms=MS`, design §19.3), also those of the WebSockets, which
# read over HTTP through their own node because a frame is always served by the owner.
#
# With `--partitions N` (3, 6 or 12) the cell is partitioned (design §4.2): every HTTP request carries a partition
# key chosen among `--keys` and goes to `/p/N/CELL/KEY`, and each WebSocket has a key of its own. The log names a cell
# `CELL/I`, I being the partition of the key (the same mapping as `Atanor.Partition`: the first 8 bytes of the SHA-256
# of the key, big-endian, modulo N), and `verify --partitions N` reads the N partitions back.

defmodule Lab.Http do
  # One keep-alive connection per (client, node). Returns {outcome, conn}.
  def request(conn, ip, method, path, body, timeout) do
    with {:ok, socket} <- if(conn, do: {:ok, conn}, else: connect(ip)),
         :ok <-
           :gen_tcp.send(socket, [
             method,
             " ",
             path,
             " HTTP/1.1\r\nhost: lab\r\ncontent-length: ",
             Integer.to_string(byte_size(body)),
             "\r\n\r\n",
             body
           ]),
         {:ok, status, headers, response} <- read(socket, timeout) do
      conn =
        if List.keyfind(headers, "connection", 0) == {"connection", "close"},
          do:
            (
              :gen_tcp.close(socket)
              nil
            ),
          else: socket

      {{:ok, status, response}, conn}
    else
      {:error, reason} ->
        if conn, do: :gen_tcp.close(conn)
        {{:error, reason}, nil}
    end
  end

  defp connect(ip) do
    :gen_tcp.connect(String.to_charlist(ip), 4000, [:binary, active: false, packet: :http_bin, nodelay: true], 3000)
  end

  defp read(socket, timeout) do
    with {:ok, {:http_response, _, status, _}} <- :gen_tcp.recv(socket, 0, timeout),
         {:ok, headers} <- headers(socket, timeout, []) do
      length = headers |> List.keyfind("content-length", 0, {nil, "0"}) |> elem(1) |> String.to_integer()
      :ok = :inet.setopts(socket, packet: :raw)

      result =
        if length > 0, do: :gen_tcp.recv(socket, length, timeout), else: {:ok, ""}

      :ok = :inet.setopts(socket, packet: :http_bin)

      case result do
        {:ok, body} -> {:ok, status, headers, body}
        {:error, _} = error -> error
      end
    end
  end

  defp headers(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, timeout, [{name |> to_string() |> String.downcase(), value} | acc])

      {:error, _} = error ->
        error
    end
  end
end

defmodule Lab.Run do
  def run(opts) do
    nodes = opts |> Keyword.fetch!(:nodes) |> String.split(",")
    deadline = System.monotonic_time(:millisecond) + opts[:seconds] * 1000
    clients = opts[:clients]
    # Fresh cells for every run, so earlier rows cannot be mistaken for this run's.
    opts = Keyword.put(opts, :run, System.os_time(:second))

    lines =
      1..clients
      |> Task.async_stream(fn c -> client(c, nodes, opts, deadline, 0, %{conns: %{}, down: %{}}, []) end,
        max_concurrency: clients,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, lines} -> lines end)

    File.write!(opts[:log], lines |> Enum.sort() |> Enum.map(&format/1))
    IO.puts("#{length(lines)} requests logged in #{opts[:log]}")
  end

  # A client that cannot reach a node leaves it out for 10 s, as a load balancer's health check would.
  defp client(c, nodes, opts, deadline, seq, state, acc) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      Enum.each(state.conns, fn {_, s} -> s && :gen_tcp.close(s) end)
      acc
    else
      up = Enum.reject(nodes, &(Map.get(state.down, &1, 0) > now))
      ip = Enum.random(if up == [], do: nodes, else: up)
      cell = "r#{opts[:run]}-#{:rand.uniform(opts[:cells]) - 1}"
      n = rem(opts[:run], 1000) * 1_000_000_000 + c * 10_000_000 + seq
      started = System.os_time(:millisecond)

      {outcome, conn} =
        Lab.Http.request(state.conns[ip], ip, "POST", "/c/#{cell}", Integer.to_string(n), opts[:timeout])

      finished = System.os_time(:millisecond)
      if opts[:think] > 0, do: Process.sleep(opts[:think])

      down =
        if match?({:error, _}, outcome),
          do: Map.put(state.down, ip, System.monotonic_time(:millisecond) + 10_000),
          else: state.down

      state = %{state | conns: Map.put(state.conns, ip, conn), down: down}
      client(c, nodes, opts, deadline, seq + 1, state, [entry(started, finished, ip, cell, n, outcome) | acc])
    end
  end

  def entry(started, finished, ip, cell, n, {:ok, status, body}) do
    json = if status == 200, do: :json.decode(body), else: %{}
    {started, finished, ip, cell, n, Integer.to_string(status), Map.get(json, "node", "-"), Map.get(json, "id", "-")}
  end

  def entry(started, finished, ip, cell, n, {:error, reason}),
    do: {started, finished, ip, cell, n, "err:#{reason}", "-", "-"}

  def format({a, b, ip, cell, n, status, node, id}), do: "#{a} #{b} #{ip} #{cell} #{n} #{status} #{node} #{id}\n"
end

defmodule Lab.WS do
  # A WebSocket client on a raw socket: text frames only, no extensions.
  import Bitwise

  def connect(ip, path, timeout) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request =
      "GET #{path} HTTP/1.1\r\nhost: lab\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" <>
        "sec-websocket-key: #{key}\r\nsec-websocket-version: 13\r\n\r\n"

    with {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(ip), 4000, [:binary, active: false, packet: :raw, nodelay: true], 3000),
         :ok <- :gen_tcp.send(socket, request),
         {:ok, "HTTP/1.1 101" <> _} <- head(socket, timeout, "") do
      {:ok, socket}
    else
      {:error, _} = error -> error
      other -> {:error, {:handshake, other}}
    end
  end

  # Reads up to the end of the response head (the server sends no frame before the client does).
  defp head(socket, timeout, acc) do
    with {:ok, data} <- :gen_tcp.recv(socket, 0, timeout) do
      acc = acc <> data
      if String.contains?(acc, "\r\n\r\n"), do: {:ok, acc}, else: head(socket, timeout, acc)
    end
  end

  def send_text(socket, text) do
    mask = :crypto.strong_rand_bytes(4)
    size = byte_size(text)
    masked = :crypto.exor(text, binary_part(:binary.copy(mask, div(size, 4) + 1), 0, size))
    true = size < 126
    :gen_tcp.send(socket, [<<0x81, 0x80 ||| size>>, mask, masked])
  end

  def call(socket, text, timeout) do
    with :ok <- send_text(socket, text), do: recv(socket, timeout)
  end

  def recv(socket, timeout), do: reply(socket, timeout)

  defp reply(socket, timeout) do
    with {:ok, <<_fin_rsv_opcode::4, opcode::4, _mask::1, len::7>>} <- :gen_tcp.recv(socket, 2, timeout),
         {:ok, size} <- size(socket, len, timeout),
         {:ok, payload} <- if(size == 0, do: {:ok, ""}, else: :gen_tcp.recv(socket, size, timeout)) do
      case opcode do
        1 -> {:ok, payload}
        op when op in [9, 10] -> reply(socket, timeout)
        _ -> {:error, :closed}
      end
    end
  end

  defp size(socket, 126, timeout) do
    with {:ok, <<size::16>>} <- :gen_tcp.recv(socket, 2, timeout), do: {:ok, size}
  end

  defp size(_socket, len, _timeout), do: {:ok, len}
end

defmodule Lab.Hot do
  # HTTP clients keep one connection per node; WebSocket clients keep one for the whole run. All of them write
  # to and read from the same cell. The clients connect first, then start together.
  def run(opts) do
    nodes = opts |> Keyword.fetch!(:nodes) |> String.split(",")
    http = opts[:http]
    ws = opts[:ws]
    opts = Keyword.put(opts, :run, System.os_time(:second))
    cell = "hot-#{opts[:run]}"
    start_at = System.monotonic_time(:millisecond) + opts[:warmup] * 1000
    deadline = start_at + opts[:seconds] * 1000
    ctx = %{nodes: nodes, cell: cell, opts: opts, start_at: start_at, deadline: deadline}
    partitions = if opts[:partitions] > 0, do: ", #{opts[:partitions]} partitions", else: ""
    IO.puts("starting cell #{cell}: the load starts in #{opts[:warmup]} s#{partitions}")

    results =
      1..(http + ws)//1
      |> Task.async_stream(
        fn c -> if c <= http, do: http_client(c, ctx), else: ws_client(c, ctx) end,
        max_concurrency: http + ws,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    writes = Enum.flat_map(results, & &1.writes)
    reads = Enum.flat_map(results, & &1.reads)
    connected = Enum.count(results, & &1.connected)
    cursors = Enum.filter(results, &Map.has_key?(&1, :cursors_sent))
    File.write!(opts[:log], writes |> Enum.sort() |> Enum.map(&Lab.Run.format/1))
    File.write!(opts[:log] <> ".reads", reads |> Enum.sort() |> Enum.map(&Lab.Run.format/1))

    IO.puts("cell #{cell}: #{connected} of #{http + ws} clients connected (#{http} HTTP, #{ws} WebSocket)")
    IO.puts("#{length(writes)} writes logged in #{opts[:log]}, #{length(reads)} reads in #{opts[:log]}.reads")
    if opts[:cursors] > 0, do: cursor_report(cursors, opts)
  end

  # The cursor frames: how many were sent, how many arrived (each should reach every connected WebSocket)
  # and how long they took from the sender's clock to the receiver's.
  defp cursor_report(results, opts) do
    connected = Enum.count(results, & &1.connected)
    sent = results |> Enum.map(& &1.cursors_sent) |> Enum.sum()
    received = results |> Enum.map(& &1.cursors_received) |> Enum.sum()
    latencies = results |> Enum.flat_map(& &1.latencies) |> Enum.sort()
    pick = fn p -> Enum.at(latencies, min(trunc(length(latencies) * p), length(latencies) - 1), 0) / 1000 end

    IO.puts(
      "cursors (#{opts[:cursor_mode]}): #{opts[:cursors]} senders every #{opts[:cursor_ms]} ms, #{sent} sent, " <>
        "#{received} delivered (#{Float.round(received / max(sent * connected, 1) * 100, 1)}% of #{sent} x #{connected} sockets), " <>
        "#{round(received / opts[:seconds])} deliveries/s"
    )

    IO.puts(
      "cursor delivery latency p50 / p95 / p99 / max: " <>
        "#{Float.round(pick.(0.5), 1)} / #{Float.round(pick.(0.95), 1)} / #{Float.round(pick.(0.99), 1)} / #{Float.round(pick.(1.0), 1)} ms"
    )
  end

  defp sleep_until(at), do: Process.sleep(max(at - System.monotonic_time(:millisecond), 0))

  # The partition of a key: Atanor.Partition.index/2 (design §4.2).
  def index(key, n) do
    <<hash::unsigned-big-64, _::binary>> = :crypto.hash(:sha256, key)
    rem(hash, n)
  end

  # The request path and the name in the log of the cell that `key` reaches.
  defp target(ctx, key) do
    case ctx.opts[:partitions] do
      0 -> {"/c/#{ctx.cell}", ctx.cell}
      n -> {"/p/#{n}/#{ctx.cell}/#{key}", "#{ctx.cell}/#{index(key, n)}"}
    end
  end

  defp key(ctx), do: "k#{:rand.uniform(ctx.opts[:keys])}"

  # `--read-bound MS` reads in bounded requests (design §19.3), which the node that receives them runs itself.
  defp read_query(ctx), do: if(ctx.opts[:read_bound] > 0, do: "?count=1&ms=#{ctx.opts[:read_bound]}", else: "?count=1")

  defp http_client(c, ctx) do
    ip = Enum.at(ctx.nodes, rem(c, length(ctx.nodes)))
    sleep_until(ctx.start_at)
    http_loop(c, ip, ctx, 0, nil, %{writes: [], reads: [], connected: true})
  end

  defp http_loop(c, ip, ctx, seq, conn, acc) do
    if System.monotonic_time(:millisecond) >= ctx.deadline do
      conn && :gen_tcp.close(conn)
      acc
    else
      write? = :rand.uniform() < ctx.opts[:write_ratio]
      n = n(ctx, c, seq)
      {path, name} = target(ctx, key(ctx))
      started = System.os_time(:millisecond)

      {outcome, conn} =
        if write?,
          do: Lab.Http.request(conn, ip, "POST", path, Integer.to_string(n), ctx.opts[:timeout]),
          else: Lab.Http.request(conn, ip, "GET", path <> read_query(ctx), "", ctx.opts[:timeout])

      finished = System.os_time(:millisecond)
      if match?({:error, _}, outcome), do: Process.sleep(100)
      http_loop(c, ip, ctx, seq + 1, conn, add(acc, write?, entry(started, finished, ip, name, n, outcome, write?)))
    end
  end

  defp ws_client(c, ctx) do
    ip = Enum.at(ctx.nodes, rem(c, length(ctx.nodes)))
    # Spread the handshakes over the warm-up.
    Process.sleep(:rand.uniform(max(ctx.opts[:warmup] * 500, 1)))
    {path, name} = target(ctx, "w#{c}")
    socket = open(ip, ctx, path)
    sleep_until(ctx.start_at)

    acc = %{
      writes: [],
      reads: [],
      connected: socket != nil,
      cursors_sent: 0,
      cursors_received: 0,
      latencies: [],
      http: nil
    }

    now = System.monotonic_time(:millisecond)
    ws_loop(c, ip, ctx, 0, socket, acc, now, now, {path, name})
  end

  # One WebSocket: a write or a read every `ws_think` ms (and its reply), and, for the first `--cursors`
  # clients, a cursor frame every `--cursor-ms`. Between its own frames the client reads what the cell sends
  # it: the cursor frames of everyone.
  defp ws_loop(c, ip, ctx, seq, socket, acc, next_op, next_cursor, target) do
    {path, name} = target
    now = System.monotonic_time(:millisecond)
    cursor? = c - ctx.opts[:http] <= ctx.opts[:cursors]

    cond do
      now >= ctx.deadline ->
        socket && :gen_tcp.close(socket)
        acc.http && :gen_tcp.close(acc.http)
        acc

      now >= next_op ->
        write? = :rand.uniform() < ctx.opts[:ws_write_ratio]
        n = n(ctx, c, seq)
        started = System.os_time(:millisecond)

        {outcome, socket, acc} =
          if write? or ctx.opts[:read_bound] == 0,
            do: ws_call(ip, ctx, socket || open(ip, ctx, path), if(write?, do: "w #{n}", else: "r"), acc),
            else: http_read(ip, path, ctx, socket, acc)

        finished = System.os_time(:millisecond)
        acc = add(acc, write?, entry(started, finished, ip, name, n, outcome, write?))

        ws_loop(
          c,
          ip,
          ctx,
          seq + 1,
          socket,
          acc,
          System.monotonic_time(:millisecond) + ctx.opts[:ws_think],
          next_cursor,
          target
        )

      cursor? and socket != nil and now >= next_cursor ->
        word = if ctx.opts[:cursor_mode] == "channel", do: "cur", else: "cursor"
        frame = "#{word} c|#{System.os_time(:microsecond)}"

        {socket, acc} =
          if Lab.WS.send_text(socket, frame) == :ok,
            do: {socket, %{acc | cursors_sent: acc.cursors_sent + 1}},
            else: {nil, acc}

        ws_loop(c, ip, ctx, seq, socket, acc, next_op, next_cursor + ctx.opts[:cursor_ms], target)

      true ->
        due = Enum.min([next_op, ctx.deadline | if(cursor?, do: [next_cursor], else: [])])

        case socket && Lab.WS.recv(socket, max(due - now, 1)) do
          {:ok, payload} ->
            ws_loop(c, ip, ctx, seq, socket, record(acc, payload), next_op, next_cursor, target)

          {:error, :timeout} ->
            ws_loop(c, ip, ctx, seq, socket, acc, next_op, next_cursor, target)

          nil ->
            Process.sleep(max(due - now, 1))
            ws_loop(c, ip, ctx, seq, nil, acc, next_op, next_cursor, target)

          {:error, _} ->
            :gen_tcp.close(socket)
            ws_loop(c, ip, ctx, seq, nil, acc, next_op, next_cursor, target)
        end
    end
  end

  # A WebSocket frame is served by the owner of the cell, so with `--read-bound` the sockets read through a bounded
  # HTTP request to their own node, on a keep-alive connection of their own.
  defp http_read(ip, path, ctx, socket, acc) do
    {outcome, conn} = Lab.Http.request(acc.http, ip, "GET", path <> read_query(ctx), "", ctx.opts[:timeout])
    {outcome, socket, %{acc | http: conn}}
  end

  # Sends a frame and waits for its reply, recording the cursor frames that come first.
  defp ws_call(_ip, _ctx, nil, _text, acc), do: {{:error, :connect}, nil, acc}

  defp ws_call(ip, ctx, socket, text, acc) do
    case Lab.WS.send_text(socket, text) do
      :ok -> ws_reply(ip, ctx, socket, acc)
      {:error, _} = error -> :gen_tcp.close(socket) && {error, nil, acc}
    end
  end

  defp ws_reply(ip, ctx, socket, acc) do
    case Lab.WS.recv(socket, ctx.opts[:timeout]) do
      {:ok, "c|" <> _ = cursor} ->
        ws_reply(ip, ctx, socket, record(acc, cursor))

      {:ok, text} ->
        {{:ok, 200, text}, socket, acc}

      {:error, _} = error ->
        :gen_tcp.close(socket)
        {error, nil, acc}
    end
  end

  defp record(acc, "c|" <> sent) do
    latency = System.os_time(:microsecond) - String.to_integer(sent)
    %{acc | cursors_received: acc.cursors_received + 1, latencies: [latency | acc.latencies]}
  end

  defp record(acc, _other), do: acc

  # Opens a WebSocket, attaches it to the cell and, in the channel mode, joins its channel.
  defp open(ip, ctx, path) do
    with {:ok, socket} <- Lab.WS.connect(ip, path, 10_000),
         {:ok, ":ok"} <- Lab.WS.call(socket, "join", 10_000),
         {:ok, ":ok"} <- channel(socket, ctx) do
      socket
    else
      _ -> nil
    end
  end

  defp channel(socket, %{opts: opts}) do
    if opts[:cursor_mode] == "channel", do: Lab.WS.call(socket, "jc", 10_000), else: {:ok, ":ok"}
  end

  defp n(ctx, c, seq), do: rem(ctx.opts[:run], 1000) * 1_000_000_000 + c * 10_000_000 + seq

  defp add(acc, true, entry), do: %{acc | writes: [entry | acc.writes]}
  defp add(acc, false, entry), do: %{acc | reads: [entry | acc.reads]}

  # Reads log the count they saw in the id column and 0 as the number.
  defp entry(started, finished, ip, cell, n, {:ok, 200, body}, write?) do
    json = :json.decode(body)

    if Map.has_key?(json, "error"),
      do: {started, finished, ip, cell, if(write?, do: n, else: 0), "err:cell", "-", "-"},
      else: Lab.Run.entry(started, finished, ip, cell, if(write?, do: n, else: 0), {:ok, 200, body})
  end

  defp entry(started, finished, ip, cell, n, outcome, write?),
    do: Lab.Run.entry(started, finished, ip, cell, if(write?, do: n, else: 0), outcome)
end

defmodule Lab.Log do
  def read(path) do
    for line <- path |> File.stream!() |> Enum.map(&String.trim/1), line != "" do
      [a, b, ip, cell, n, status, node, id] = String.split(line, " ")

      %{
        start: String.to_integer(a),
        end: String.to_integer(b),
        ingress: ip,
        cell: cell,
        n: String.to_integer(n),
        status: status,
        node: node,
        id: id
      }
    end
  end
end

defmodule Lab.Verify do
  def run(opts) do
    entries = Lab.Log.read(opts[:log])
    ip = opts |> Keyword.fetch!(:nodes) |> String.split(",") |> hd()
    acked = for %{status: "200"} = e <- entries, do: {e.cell, e.n}
    sent = MapSet.new(for e <- entries, do: {e.cell, e.n})
    acked_set = MapSet.new(acked)

    rows = Map.new(entries |> Enum.map(& &1.cell) |> Enum.uniq(), &{&1, read_cell(ip, path(&1, opts[:partitions]))})

    present = for {cell, rs} <- rows, [_id, n, _node] <- rs, do: {cell, n}
    counts = Enum.frequencies(present)
    present_set = MapSet.new(present)
    lost = Enum.reject(acked, &MapSet.member?(present_set, &1))
    duplicates = for {k, c} <- counts, c > 1, do: k
    unacked_applied = for {k, _} <- counts, k in sent, k not in acked_set, do: k
    unknown = for {k, _} <- counts, k not in sent, do: k

    owners =
      Map.new(rows, fn {cell, rs} ->
        {cell,
         rs
         |> Enum.map(fn [_, _, node] -> node |> String.split("@") |> List.last() end)
         |> Enum.dedup()
         |> Enum.join(">")}
      end)

    IO.puts("acknowledged writes: #{length(acked)}")
    IO.puts("rows in the cells:   #{length(present)}")
    IO.puts("LOST acknowledged:   #{length(lost)} #{inspect(Enum.take(lost, 5))}")
    IO.puts("DUPLICATED rows:     #{length(duplicates)} #{inspect(Enum.take(duplicates, 5))}")
    IO.puts("unacknowledged but applied: #{length(unacked_applied)}")
    IO.puts("rows nobody sent:    #{length(unknown)}")
    IO.puts("owner sequence by cell (node suffix, in row order), cells that changed owner:")

    for {cell, seq} <- Enum.sort(owners), String.contains?(seq, ">"), do: IO.puts("  #{cell}: #{seq}")
  end

  # A partitioned cell is logged as CELL/I, partition I of the logical cell.
  defp path(cell, 0), do: "/c/#{cell}"

  defp path(name, n) do
    [cell, index] = String.split(name, "/")
    "/p/#{n}/#{cell}?index=#{index}"
  end

  defp read_cell(ip, path, tries \\ 90) do
    case Lab.Http.request(nil, ip, "GET", path, "", 10_000) do
      {{:ok, 200, body}, _} ->
        body |> :json.decode() |> Map.fetch!("rows")

      _ when tries > 1 ->
        Process.sleep(1000)
        read_cell(ip, path, tries - 1)

      other ->
        raise "cannot read #{path}: #{inspect(other)}"
    end
  end
end

defmodule Lab.Report do
  def run(opts) do
    entries = Lab.Log.read(opts[:log])

    events =
      Keyword.get_values(opts, :event)
      |> Map.new(fn e ->
        [k, v] = String.split(e, "=", parts: 2)
        {k, String.to_integer(v)}
      end)

    t0 = events |> Map.values() |> Enum.min(fn -> hd(entries).start end)

    ok = Enum.filter(entries, &(&1.status == "200"))
    IO.puts("requests: #{length(entries)}, ok: #{length(ok)}")

    IO.puts(
      "outcomes: #{entries |> Enum.frequencies_by(& &1.status) |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)}"
    )

    span = (List.last(entries).end - hd(entries).start) / 1000
    IO.puts("throughput: #{round(length(ok) / span)} ok/s over #{Float.round(span, 1)} s")
    IO.puts("ok / errors per 10 s from the first request: #{buckets(entries)}")
    for {name, at} <- Enum.sort_by(events, &elem(&1, 1)), do: IO.puts("event #{name} at t0#{signed(at - t0)} ms")

    cond do
      opts[:local_only] ->
        latency("local-owner", Enum.filter(ok, &local?/1))

      opts[:forwarded_only] ->
        latency("forwarded", Enum.reject(ok, &local?/1))

      true ->
        latency("all ok", ok)
        latency("local-owner", Enum.filter(ok, &local?/1))
        latency("forwarded", Enum.reject(ok, &local?/1))
    end

    errors = entries |> Enum.reject(&(&1.status == "200")) |> Enum.sort_by(& &1.end)

    case errors do
      [] ->
        IO.puts("no errors")

      _ ->
        IO.puts("error windows (gap < 2 s merged), relative to t0:")

        for {first, last, count, kinds} <- windows(errors),
            do:
              IO.puts(
                "  #{signed(first - t0)} .. #{signed(last - t0)} ms (#{last - first} ms), #{count} errors #{inspect(kinds)}"
              )
    end

    for spec <- Keyword.get_values(opts, :window), do: window(ok, entries, spec)
    if victim = opts[:victim], do: recovery(entries, victim, events)
  end

  # Throughput and latency of the requests that ended in FROM_MS..TO_MS (epoch ms), for example before and after a move.
  defp window(ok, entries, spec) do
    [name, range] = String.split(spec, "=", parts: 2)
    [from, to] = range |> String.split(",") |> Enum.map(&String.to_integer/1)
    inside = fn es -> Enum.filter(es, &(&1.end >= from and &1.end < to)) end
    seconds = (to - from) / 1000
    good = inside.(ok)
    failed = length(inside.(entries)) - length(good)
    IO.puts("window #{name} (#{Float.round(seconds, 1)} s): #{round(length(good) / seconds)} ok/s, #{failed} errors")
    latency("  window #{name}", good)
  end

  defp buckets(entries) do
    first = hd(entries).start

    entries
    |> Enum.group_by(&div(&1.end - first, 10_000), &(&1.status == "200"))
    |> Enum.sort()
    |> Enum.map_join(" ", fn {i, results} ->
      "#{i * 10}s:#{Enum.count(results, & &1)}/#{Enum.count(results, &(not &1))}"
    end)
  end

  defp local?(e), do: e.node == "atanor@" <> e.ingress

  defp latency(label, []), do: IO.puts("#{label}: no requests")

  defp latency(label, es) do
    sorted = es |> Enum.map(&(&1.end - &1.start)) |> Enum.sort()
    pick = fn p -> Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p))) end

    IO.puts(
      "#{label}: n=#{length(es)} p50=#{pick.(0.5)} ms p95=#{pick.(0.95)} ms p99=#{pick.(0.99)} ms max=#{List.last(sorted)} ms"
    )
  end

  defp windows(errors) do
    errors
    |> Enum.chunk_while(
      nil,
      fn e, acc ->
        case acc do
          nil -> {:cont, {e.end, e.end, 1, [e.status]}}
          {first, last, n, kinds} when e.end - last < 2000 -> {:cont, {first, e.end, n + 1, [e.status | kinds]}}
          done -> {:cont, done, {e.end, e.end, 1, [e.status]}}
        end
      end,
      fn acc -> {:cont, acc, nil} end
    )
    |> Enum.map(fn {a, b, n, kinds} -> {a, b, n, Enum.frequencies(kinds)} end)
  end

  # Cells the victim served last before the first event: how long until another node answers for them.
  defp recovery(entries, victim, events) do
    at = events |> Map.values() |> Enum.min()
    node = "atanor@" <> victim
    failed = Enum.reject(entries, &(&1.status == "200"))
    {via_victim, via_others} = Enum.split_with(failed, &(&1.ingress == victim))

    IO.puts(
      "errors by ingress: victim #{length(via_victim)}, other nodes #{length(via_others)} #{inspect(Enum.frequencies_by(via_others, & &1.status))}"
    )

    ok = Enum.filter(entries, &(&1.status == "200"))

    owned =
      ok
      |> Enum.filter(&(&1.end <= at))
      |> Enum.group_by(& &1.cell)
      |> Enum.filter(fn {_, es} -> List.last(Enum.sort_by(es, & &1.end)).node == node end)
      |> Enum.map(&elem(&1, 0))

    times =
      for cell <- owned do
        first =
          ok
          |> Enum.filter(&(&1.cell == cell and &1.end > at and &1.node != node))
          |> Enum.min_by(& &1.end, fn -> nil end)

        if first, do: first.end - at
      end

    served = Enum.reject(times, &is_nil/1) |> Enum.sort()
    IO.puts("cells of #{victim} before the event: #{length(owned)}; served again by another node: #{length(served)}")

    if served != [] do
      IO.puts(
        "time to serve again after the event: min #{hd(served)} ms, median #{Enum.at(served, div(length(served), 2))} ms, max #{List.last(served)} ms"
      )
    end
  end

  defp signed(ms) when ms >= 0, do: "+#{ms}"
  defp signed(ms), do: "#{ms}"
end

{opts, [command]} =
  OptionParser.parse!(System.argv(),
    strict: [
      nodes: :string,
      log: :string,
      seconds: :integer,
      clients: :integer,
      cells: :integer,
      think: :integer,
      timeout: :integer,
      http: :integer,
      ws: :integer,
      ws_think: :integer,
      cursors: :integer,
      cursor_ms: :integer,
      cursor_mode: :string,
      ws_write_ratio: :float,
      write_ratio: :float,
      warmup: :integer,
      partitions: :integer,
      keys: :integer,
      read_bound: :integer,
      event: :keep,
      window: :keep,
      victim: :string,
      local_only: :boolean,
      forwarded_only: :boolean
    ]
  )

opts =
  Keyword.merge(
    [
      seconds: 30,
      clients: 12,
      cells: 24,
      think: 20,
      timeout: 10_000,
      http: 48,
      ws: 300,
      ws_think: 500,
      cursors: 0,
      cursor_ms: 1000,
      cursor_mode: "cell",
      write_ratio: 0.5,
      ws_write_ratio: 0.1,
      warmup: 15,
      partitions: 0,
      keys: 1000,
      read_bound: 0
    ],
    opts
  )

case command do
  "run" -> Lab.Run.run(opts)
  "hot" -> Lab.Hot.run(opts)
  "verify" -> Lab.Verify.run(opts)
  "report" -> Lab.Report.run(opts)
end
