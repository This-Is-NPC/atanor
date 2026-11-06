defmodule Atanor.Cluster.ChannelsTest do
  @moduledoc """
  Ephemeral channels on three peers (design §7.6).

  **E1.** Sockets are spread over the nodes and join the channel of a cell.
  Messages are published from random nodes, as cursor frames of a client
  (shaped by `handle_ws_local/3` on the socket's own node) and by `Env.publish/3`
  from worker processes, and sockets leave at random points. Then:

    * every socket receives every message published while it was in the channel,
      once, and none published after it left;
    * the messages of one publisher (a client's socket, or one call of a worker
      process) reach each socket in the order they were published;
    * no transaction ran: the cell's position is the one it had before, and
      no callback reached the owner for a publication (the owner ran one
      `handle_ws/3` per join and per leave, and nothing else);
    * a publication is one message to each node that has members, however
      many sockets they have.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, ChannelWorker, Manifests, WSClient}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 300_000

  @names [:n1, :n2, :n3]
  @worker "chan"

  setup do
    chan =
      Manifests.probe(@worker,
        module: ChannelWorker,
        sockets: true,
        cells: %{"rooms" => []},
        routes: [{"127.0.0.1", "/room"}]
      )

    %{cluster: start_cluster(workers: [chan])}
  end

  defp port(cluster, name), do: cluster |> Cluster.url(name) |> URI.parse() |> Map.fetch!(:port)

  defp connect(cluster, name, room) do
    {:ok, client} = WSClient.connect(port(cluster, name), "/room/#{room}")
    client
  end

  defp call(client, text) do
    client = WSClient.send_frame(client, {:text, text})
    {{:text, reply}, client} = WSClient.recv(client, 10_000)
    {reply, client}
  end

  defp position(cluster, room) do
    {:ok, {:ok, position}} =
      Cluster.call(cluster, :n1, Atanor.Cell, :position, [Cluster.instance(cluster), {"rooms", room}])

    Map.take(position, [:txid, :data])
  end

  defp owner_frames(cluster, room),
    do: length(events(cluster, [:atanor, :call], &(&1.cell == {"rooms", room} and &1.kind == :ws_in)))

  # Receives `count` text frames, in the order they arrive.
  defp receive_frames(client, 0, acc), do: {Enum.reverse(acc), client}

  defp receive_frames(client, count, acc) do
    {{:text, body}, client} = WSClient.recv(client, 10_000)
    receive_frames(client, count - 1, [body | acc])
  end

  # The publisher and sequence number of a received body, without the stamp of the socket's node.
  defp parse(body) do
    [publisher, seq] = body |> String.split("|") |> List.last() |> String.split(":")
    {publisher, String.to_integer(seq)}
  end

  defp operation do
    one_of([
      tuple({constant(:cursor), member_of(@names), integer(1..3)}),
      tuple({constant(:publish), member_of(@names), integer(1..3)}),
      tuple({constant(:leave), integer(0..5)})
    ])
  end

  property "the channel delivers to every subscribed node and never touches the cell", %{cluster: c} do
    check all(
            sockets <- list_of(member_of(@names), min_length: 1, max_length: 6),
            operations <- list_of(operation(), min_length: 1, max_length: 8),
            max_runs: 12
          ) do
      room = "p#{System.unique_integer([:positive])}"

      subscribers =
        for {name, index} <- Enum.with_index(sockets) do
          {":ok", client} = c |> connect(name, room) |> call("join #{room} s#{index}")
          %{index: index, active: true, client: client, expected: [], received: []}
        end

      publishers = Map.new(@names, &{&1, connect(c, &1, room)})
      joins = length(subscribers)
      Await.until(fn -> owner_frames(c, room) == joins end)
      before = position(c, room)

      state = %{subscribers: subscribers, publishers: publishers, leaves: 0, cursors: %{}}

      state =
        operations
        |> Enum.with_index(1)
        |> Enum.reduce(state, fn {operation, n}, state -> run(c, room, operation, n, state) end)

      # Every socket that was in the channel gets what was published meanwhile, in order.
      for sub <- state.subscribers do
        {frames, client} = receive_frames(sub.client, length(sub.expected) - length(sub.received), [])
        got = Enum.map(sub.received ++ frames, &parse/1)
        assert Enum.sort(got) == Enum.sort(sub.expected), "socket #{sub.index}"

        for {publisher, seqs} <- Enum.group_by(got, &elem(&1, 0), &elem(&1, 1)),
            do: assert(seqs == Enum.sort(seqs), "order of #{publisher} at socket #{sub.index}")

        assert {:timeout, _} = WSClient.recv(client, 50)
        WSClient.close(client)
      end

      # No transaction ran, and the owner ran a callback only for each join and leave.
      assert position(c, room) == before
      Await.until(fn -> owner_frames(c, room) >= joins + state.leaves end)
      assert owner_frames(c, room) == joins + state.leaves

      # A publication is one message to each node that has members.
      published = events(c, [:atanor, :channel, :publish], &(&1.cell == {"rooms", room}))
      assert Enum.all?(published, &(&1.measurements.nodes <= length(Enum.uniq(sockets))))
      assert Enum.all?(published, &(&1.measurements.subscribers <= joins))

      for {_, client} <- state.publishers, do: WSClient.close(client)
    end
  end

  # Cursor frames of a client at `name`: shaped on its node, published, dropped.
  defp run(_c, room, {:cursor, name, count}, _n, state) do
    first = Map.get(state.cursors, name, 0) + 1
    seqs = Enum.to_list(first..(first + count - 1))
    client = Enum.reduce(seqs, state.publishers[name], &WSClient.send_frame(&2, {:text, "cur #{room} f#{name}:#{&1}"}))

    %{
      state
      | publishers: %{state.publishers | name => client},
        cursors: Map.put(state.cursors, name, List.last(seqs)),
        subscribers: deliver(state.subscribers, for(seq <- seqs, do: {"f#{name}", seq}))
    }
  end

  # One call of a worker process on `name`.
  defp run(c, room, {:publish, name, count}, n, state) do
    bodies = for seq <- 1..count, do: "e#{n}:#{seq}"
    {:ok, :ok} = Cluster.call(c, name, ChannelWorker, :publish_all, [Cluster.instance(c), @worker, room, bodies])
    %{state | subscribers: deliver(state.subscribers, for(seq <- 1..count, do: {"e#{n}", seq}))}
  end

  # A socket leaves once it has what was published so far.
  defp run(_c, room, {:leave, index}, _n, state) do
    sub = Enum.at(state.subscribers, rem(index, length(state.subscribers)))

    if sub.active do
      {frames, client} = receive_frames(sub.client, length(sub.expected) - length(sub.received), [])
      {":ok", client} = call(client, "leave #{room}")
      sub = %{sub | client: client, active: false, received: sub.received ++ frames}
      %{state | subscribers: List.replace_at(state.subscribers, sub.index, sub), leaves: state.leaves + 1}
    else
      state
    end
  end

  defp deliver(subscribers, expected),
    do: for(sub <- subscribers, do: if(sub.active, do: %{sub | expected: sub.expected ++ expected}, else: sub))
end
