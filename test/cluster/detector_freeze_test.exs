defmodule Atanor.Cluster.DetectorFreezeTest do
  @moduledoc """
  A node that was frozen long enough to be taken over, and then thawed, rejoins: nobody keeps anybody
  `down`, and a cell is not taken back and forth between live nodes (design §8.10).
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 180_000

  @detector [
    interval_ms: 200,
    phi_threshold: 8,
    min_std_ms: 50,
    acceptable_pause_ms: 600,
    indirect: [k: 2, timeout_ms: 500]
  ]
  # The bound for every node to see every other `alive` after a thaw, and the time the cell is then watched.
  @rejoin_ms 10_000
  @watch_ms 10_000

  defp start(detector \\ @detector) do
    cluster =
      start_cluster(
        names: [:n1, :n2, :n3],
        ttl_ms: 2_000,
        skew_margin_ms: 400,
        atanor: [detector: detector],
        workers: [Manifests.counter("counter")]
      )

    for via <- Cluster.names(cluster), do: Await.until(fn -> map_size(views(cluster, via)) == 2 end)
    cluster
  end

  # Freezes `victim` until both survivors confirm it down and one of them has taken `cell`, then thaws it.
  defp freeze(cluster, victim, cell) do
    [one, two] = Cluster.names(cluster) -- [victim]
    Cluster.pause(cluster, victim)
    await_event(cluster, one, :down, victim)
    serve_again(cluster, one, cell, now())
    Cluster.resume(cluster, victim)
    {one, two}
  end

  defp all_alive?(cluster) do
    names = Cluster.names(cluster)
    Enum.all?(for(a <- names, b <- names, a != b, do: state(cluster, a, b) == :alive))
  end

  defp take_overs(cluster),
    do: events(cluster, [:atanor, :cell, :take_over], &(&1.result == :ok and &1.node != nil))

  # Both survivors and the thawed node write the cell in turn, as traffic that touches it on every node.
  defp touch_all(cluster, cell, ms) do
    until = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn -> Enum.each(Cluster.names(cluster), &write(cluster, &1, cell, 1)) end)
    |> Enum.take_while(fn _ -> System.monotonic_time(:millisecond) < until end)
  end

  test "two live nodes that confirmed each other down are alive again within a bound" do
    # No witnesses: a failed ping is a verdict, as in a cluster of two (design §8.8).
    cluster = start(Keyword.put(@detector, :indirect, k: 0, timeout_ms: 500))
    instance = Cluster.instance(cluster)
    one = Cluster.node(cluster, :n1)
    two = Cluster.node(cluster, :n2)

    # A cookie of its own for the peer on each side keeps both from reconnecting, so that each confirms the other down for good reason and
    # neither is reconnected by a probe. Then the cookie is right again and nothing else connects them.
    for {via, peer} <- [n1: two, n2: one] do
      {:ok, true} = Cluster.call(cluster, via, :erlang, :set_cookie, [peer, :"wrong_#{via}"])
      {:ok, _} = Cluster.call(cluster, via, Node, :disconnect, [peer])
      {:ok, :ok} = Cluster.call(cluster, via, Atanor.Detector, :confirmed_down, [instance, peer, :test])
    end

    assert state(cluster, :n1, :n2) == :down and state(cluster, :n2, :n1) == :down
    # Absence has nothing to wait for: leave time for any round still running to end with no answer.
    Process.sleep(2 * @detector[:interval_ms] + 1_000)
    assert state(cluster, :n1, :n2) == :down and state(cluster, :n2, :n1) == :down
    cookie = Cluster.call(cluster, :n3, :erlang, :get_cookie, []) |> elem(1)

    for {via, peer} <- [n1: two, n2: one],
        do: {:ok, true} = Cluster.call(cluster, via, :erlang, :set_cookie, [peer, cookie])

    Await.until(fn -> all_alive?(cluster) end, @rejoin_ms)
  end

  test "a thawed node is alive again at every node within a bound" do
    cluster = start()
    {cell, victim} = owned_cell(cluster, "f")
    freeze(cluster, victim, cell)

    Await.until(fn -> all_alive?(cluster) end, @rejoin_ms)
  end

  test "after a thaw the cell is not taken back and forth between live nodes" do
    cluster = start()
    {cell, victim} = owned_cell(cluster, "g")
    freeze(cluster, victim, cell)

    # Traffic from the first moment after the thaw, when the thawed node still has its peers down.
    before = length(take_overs(cluster))
    touch_all(cluster, cell, @watch_ms)
    taken = length(take_overs(cluster)) - before
    IO.puts("freeze: #{taken} takeovers of a cell between live nodes in #{@watch_ms} ms")
    assert taken == 0
    Await.until(fn -> all_alive?(cluster) end, @rejoin_ms)
  end

  test "two nodes frozen in turn rejoin without trading a cell" do
    cluster = start()
    {cell, first} = owned_cell(cluster, "h")
    freeze(cluster, first, cell)
    Await.until(fn -> all_alive?(cluster) end, @rejoin_ms)

    {:ok, owner} = owner(cluster, :n1, "log", cell)
    second = name_of(cluster, owner)
    freeze(cluster, second, cell)

    touch_all(cluster, cell, 3_000)
    Await.until(fn -> all_alive?(cluster) end, @rejoin_ms)
    before = length(take_overs(cluster))
    touch_all(cluster, cell, @watch_ms)
    assert length(take_overs(cluster)) - before == 0
  end
end
