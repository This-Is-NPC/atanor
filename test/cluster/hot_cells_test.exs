defmodule Atanor.Cluster.HotCellsTest do
  @moduledoc """
  The automatic placement of hot cells on three peers (design §8.15): a hot cell on
  a node under CPU pressure moves to a less loaded node, a hot cell of a ruled
  namespace goes to a tagged node, and what is attached to the cell keeps working.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Busy, Manifests, WSClient}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  # Quick enough for a test: a cell is hot after 5 writes per second for 0.6 s.
  @hot [
    enabled: true,
    # The peers share one machine, so the machine's CPU would be the same for all of them.
    os_cpu: false,
    interval_ms: 200,
    sustain_ms: 600,
    write_enter: 5,
    write_exit: 2,
    cpu_enter: 60,
    cpu_exit: 40,
    residence_ms: 3_000,
    node_cooldown_ms: 600,
    stale_ms: 1_500
  ]

  defp start(hot, opts \\ []) do
    chat =
      Manifests.probe("chat",
        module: Atanor.Test.SocketWorker,
        sockets: true,
        cells: %{"rooms" => []},
        routes: [{"127.0.0.1", "/room"}]
      )

    start_cluster([workers: [Manifests.counter("counter"), chat], atanor: [hot_cells: hot]] ++ opts)
  end

  # Writes to the cell through `via` until the stop message, one every 25 ms; returns the numbers acknowledged.
  defp writer(cluster, via, cell, first) do
    parent = self()

    spawn_link(fn ->
      send(parent, {:acked, write_loop(cluster, via, cell, first, [])})
    end)
  end

  defp write_loop(cluster, via, cell, n, acked) do
    receive do
      :stop -> acked
    after
      25 ->
        case write(cluster, via, cell, n) do
          {200, _} -> write_loop(cluster, via, cell, n + 1, [n | acked])
          _ -> write_loop(cluster, via, cell, n + 1, acked)
        end
    end
  end

  defp stored(cluster, via, cell) do
    {:ok, %{status: 200, body: body}} = request(cluster, via, :get, "/c/#{cell}")
    Jason.decode!(body)["rows"]
  end

  defp moves(cluster, cell) do
    events(cluster, [:atanor, :hot_cell, :move], &(&1.cell == {"log", cell}))
  end

  test "a hot cell leaves a node under CPU pressure for a less loaded one" do
    cluster = start(@hot)
    {cell, owner} = owned_cell(cluster, "hot", [:n1, :n2, :n3])
    via = hd(Cluster.names(cluster) -- [owner])
    writer = writer(cluster, via, cell, 1)

    # The writes alone do not move it: the node is idle.
    Process.sleep(2_000)
    assert moves(cluster, cell) == []

    {:ok, :ok} = Cluster.call(cluster, owner, Busy, :spin, [20_000])
    [move | _] = Await.until(fn -> moves(cluster, cell) != [] and moves(cluster, cell) end, 30_000)

    assert move.node == owner
    assert {move.meta.result, move.meta.reason} == {:ok, :load}
    assert move.meta.from == Cluster.node(cluster, owner)
    assert move.measurements.duration > 0
    assert {:ok, move.meta.to} == owner(cluster, via, "log", cell)

    send(writer, :stop)
    assert_receive {:acked, acked}, 10_000
    rows = stored(cluster, via, cell)
    assert acked -- rows == []
    assert rows == Enum.uniq(rows)

    decision = events(cluster, [:atanor, :hot_cell, :decision], &(&1.cell == {"log", cell} and &1.action == :move))
    assert [%{meta: %{reason: :load, target: target}} | _] = decision
    assert target == move.meta.to
  end

  test "a hot cell of a ruled namespace goes to the tagged node although nothing is busy" do
    hot = @hot ++ [affinity: [{"log", "dedicated"}]]

    cluster =
      start(hot,
        peer_atanor: %{n3: [hot_cells: hot ++ [tags: ["dedicated"]]]}
      )

    {cell, owner} = owned_cell(cluster, "ruled", [:n1, :n2])
    via = hd([:n1, :n2] -- [owner])
    writer = writer(cluster, via, cell, 1)

    [move | _] = Await.until(fn -> moves(cluster, cell) != [] and moves(cluster, cell) end, 30_000)
    assert move.meta.reason == :affinity and move.meta.result == :ok
    assert {:ok, Cluster.node(cluster, :n3)} == owner(cluster, via, "log", cell)

    # It stays there however hot it is: the node is the one the rule names.
    Process.sleep(3_000)
    assert length(moves(cluster, cell)) == 1

    send(writer, :stop)
    assert_receive {:acked, acked}, 10_000
    assert acked -- stored(cluster, via, cell) == []
  end

  test "a cell that moved stays for the residence time although its new node is under pressure" do
    residence_ms = 4_000
    cluster = start(Keyword.put(@hot, :residence_ms, residence_ms))
    {cell, owner} = owned_cell(cluster, "stay", [:n1, :n2, :n3])
    via = hd(Cluster.names(cluster) -- [owner])
    writer = writer(cluster, via, cell, 1)

    {:ok, :ok} = Cluster.call(cluster, owner, Busy, :spin, [25_000])
    [first] = Await.until(fn -> moves(cluster, cell) |> then(&(length(&1) == 1 and &1)) end, 30_000)
    arrived = name_of(cluster, first.meta.to)

    # The node it arrived on is busy now too, and a third node is idle.
    {:ok, :ok} = Cluster.call(cluster, arrived, Busy, :spin, [25_000])
    [_, second] = Await.until(fn -> moves(cluster, cell) |> then(&(length(&1) == 2 and &1)) end, 30_000)

    started = second.at - div(second.measurements.duration, 1_000)

    assert started - first.at >= residence_ms * 1_000 - 100_000,
           "moved again #{div(started - first.at, 1_000)} ms later"

    decisions =
      events(cluster, [:atanor, :hot_cell, :decision], &(&1.cell == {"log", cell} and &1.reason == :residence))

    assert decisions != []

    send(writer, :stop)
    assert_receive {:acked, acked}, 10_000
    assert acked -- stored(cluster, via, cell) == []
  end

  test "sockets and channels attached to a cell keep working after it moves" do
    cluster = start(@hot)
    port = fn name -> cluster |> Cluster.url(name) |> URI.parse() |> Map.fetch!(:port) end
    instance = Cluster.instance(cluster)

    # A socket on a node other than the owner's wakes the cell and gives its owner.
    {:ok, {:ok, owner}} = Cluster.call(cluster, :n1, Atanor.Cell, :owner, [instance, {"rooms", "r1"}])
    [a, b] = Cluster.names(cluster) -- [name_of(cluster, owner)]
    target = Cluster.node(cluster, a)

    {:ok, one} = WSClient.connect(port.(a), "/room/r1")
    {:ok, two} = WSClient.connect(port.(b), "/room/r1")

    exchange = fn client, text ->
      client = WSClient.send_frame(client, {:text, text})
      {{:text, reply}, client} = WSClient.recv(client, 5_000)
      {reply, client}
    end

    assert {":ok", one} = exchange.(one, "join r1")
    assert {":ok", two} = exchange.(two, "say r1 before")
    assert {{:text, "cell:before"}, one} = WSClient.recv(one, 5_000)

    assert {:ok, {:ok, ^target}} =
             Cluster.call(cluster, name_of(cluster, owner), Atanor.HotCells, :move, [instance, {"rooms", "r1"}, target])

    assert {:ok, {:ok, ^target}} = Cluster.call(cluster, :n1, Atanor.Cell, :owner, [instance, {"rooms", "r1"}])
    assert {node, one} = exchange.(one, "node")
    assert node == Atom.to_string(target)

    assert {":ok", two} = exchange.(two, "say r1 after")
    assert {{:text, "cell:after"}, one} = WSClient.recv(one, 5_000)
    WSClient.close(one)
    WSClient.close(two)
  end
end
