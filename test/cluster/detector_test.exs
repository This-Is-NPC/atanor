defmodule Atanor.Cluster.DetectorTest do
  @moduledoc """
  Failure detection between real nodes (design §8.6 to §8.10): a process that
  dies is seen at once, a machine that goes silent is found by phi and the
  indirect probes, and a broken link is told apart from a dead node.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 180_000

  @ttl_ms 2_000
  @detector [
    interval_ms: 200,
    phi_threshold: 8,
    min_std_ms: 50,
    acceptable_pause_ms: 600,
    indirect: [k: 2, timeout_ms: 500]
  ]

  defp start(detector \\ @detector) do
    cluster =
      start_cluster(
        names: [:n1, :n2, :n3],
        ttl_ms: @ttl_ms,
        skew_margin_ms: 400,
        atanor: [detector: detector],
        workers: [Manifests.counter("counter")]
      )

    # Every node knows its peers once its detector discovered them.
    for via <- Cluster.names(cluster), do: Await.until(fn -> map_size(views(cluster, via)) == 2 end)
    cluster
  end

  test "a process killed on a live host is seen at once, without phi" do
    cluster = start(Keyword.put(@detector, :phi_threshold, 1_000_000))
    {cell, victim} = owned_cell(cluster, "k")
    [one, two] = Cluster.names(cluster) -- [victim]

    t0 = now()
    Cluster.kill_process(cluster, victim)

    for observer <- [one, two] do
      suspect = await_event(cluster, observer, :suspect, victim)
      assert {:nodedown, _} = suspect.meta.reason
      down = await_event(cluster, observer, :down, victim)
      IO.puts("SIGKILL: #{observer} saw #{victim} down after #{ms_since(t0, down)} ms")
      assert ms_since(t0, down) < 3_000
    end

    IO.puts("SIGKILL: cell served again after #{serve_again(cluster, one, cell, t0)} ms")
  end

  test "a stopped process is found by phi and probes, and its cells serve again", %{} do
    cluster = start()
    {cell, victim} = owned_cell(cluster, "s")
    [one, two] = Cluster.names(cluster) -- [victim]
    {200, _} = write(cluster, one, cell, 1)

    t0 = now()
    Cluster.pause(cluster, victim)

    for observer <- [one, two] do
      assert {:phi, phi} = await_event(cluster, observer, :suspect, victim).meta.reason
      assert phi >= 8
      down = await_event(cluster, observer, :down, victim)
      IO.puts("SIGSTOP: #{observer} saw #{victim} down after #{ms_since(t0, down)} ms")
      assert ms_since(t0, down) < 6_000
      assert state(cluster, observer, victim) == :down
    end

    served = serve_again(cluster, one, cell, t0)
    IO.puts("SIGSTOP: cell served again after #{served} ms (lease ttl #{@ttl_ms} ms)")
    assert served < 12_000

    # The frozen node comes back: both see it alive and the cell has one owner.
    Cluster.resume(cluster, victim)
    for observer <- [one, two], do: await_state(cluster, observer, victim, :alive)
    assert event(cluster, one, :alive, victim)

    numbers = Enum.zip(Cluster.names(cluster), [1_001, 1_002, 1_003])
    for {via, n} <- numbers, do: assert({200, _} = write(cluster, via, cell, n))
    {:ok, resp} = request(cluster, two, :get, "/c/#{cell}")
    rows = Jason.decode!(resp.body)["rows"]
    assert rows == Enum.uniq(rows)
    assert [1_001, 1_002, 1_003] -- rows == []
  end

  test "a cut between two nodes is a broken link, not a dead node" do
    cluster = start()
    # n1 and the owner n2 lose each other; n3 reaches both.
    {cell, owner} = owned_cell(cluster, "p", [:n2])
    {other, witness} = {:n1, :n3}

    Cluster.partition_nodes(cluster, other, owner)

    for {from, to} <- [{other, owner}, {owner, other}] do
      broken = await_event(cluster, from, :link_broken, to)
      assert broken.meta.via == Cluster.node(cluster, witness)
      assert state(cluster, from, to) == :link_broken
    end

    assert state(cluster, witness, owner) == :alive
    assert state(cluster, witness, other) == :alive
    assert events_about(cluster, [:down]) == []

    # Nothing is forwarded over the broken link, so the answer is quick; elsewhere the cell serves.
    t0 = now()
    assert {503, body} = write(cluster, other, cell, 2)
    assert Jason.decode!(body)["error"] == "unavailable"
    assert div(now() - t0, 1_000) < 3_000
    assert {200, _} = write(cluster, witness, cell, 3)

    Cluster.heal_nodes(cluster, other, owner)
    await_state(cluster, other, owner, :alive)
    await_state(cluster, owner, other, :alive)
    assert {200, _} = write(cluster, other, cell, 4)
    assert events_about(cluster, [:down]) == []
  end

  test "the platform hint confirms a node down at once, here and at its peers" do
    cluster = start(Keyword.put(@detector, :phi_threshold, 1_000_000))
    {cell, victim} = owned_cell(cluster, "h")
    [one, two] = Cluster.names(cluster) -- [victim]
    Cluster.pause(cluster, victim)

    url = Cluster.admin_url(cluster, one) <> "/nodes/#{Cluster.node(cluster, victim)}/gone"
    bearer = [{"authorization", "Bearer " <> Cluster.admin_token()}]
    assert Req.post!(url, retry: false).status == 401

    assert Req.post!(Cluster.admin_url(cluster, one) <> "/nodes/nobody@nowhere/gone", headers: bearer, retry: false).status ==
             404

    t0 = now()
    resp = Req.post!(url, headers: bearer, retry: false)
    assert resp.status == 200
    assert resp.body == %{"node" => Atom.to_string(Cluster.node(cluster, victim)), "state" => "down"}

    for observer <- [one, two] do
      down = await_event(cluster, observer, :down, victim)
      assert down.meta.reason == :platform_hint
      IO.puts("hint: #{observer} saw #{victim} down after #{ms_since(t0, down)} ms")
      assert ms_since(t0, down) < 1_000
    end

    assert events_about(cluster, [:suspect]) == []
    IO.puts("hint: cell served again after #{serve_again(cluster, one, cell, t0)} ms")

    Cluster.resume(cluster, victim)
    for observer <- [one, two], do: await_state(cluster, observer, victim, :alive)
  end

  test "a node that stops gracefully is down at once for its peers" do
    cluster = start(Keyword.put(@detector, :phi_threshold, 1_000_000))
    {cell, leaving} = owned_cell(cluster, "g")
    [one, two] = Cluster.names(cluster) -- [leaving]
    supervisor = Module.concat(Cluster.instance(cluster), Supervisor)

    t0 = now()
    assert {:ok, :ok} = Cluster.call(cluster, leaving, Supervisor, :stop, [supervisor])

    for observer <- [one, two] do
      down = await_event(cluster, observer, :down, leaving)
      assert down.meta.reason == :left
      IO.puts("graceful stop: #{observer} saw #{leaving} leave after #{ms_since(t0, down)} ms")
    end

    assert events_about(cluster, [:suspect]) == []
    IO.puts("graceful stop: cell served again after #{serve_again(cluster, one, cell, t0)} ms")
  end

  describe "false positives" do
    test "a pause shorter than the acceptable pause is not a failure" do
      cluster = start()
      Process.sleep(1_000)
      Cluster.pause(cluster, :n2)
      Process.sleep(300)
      Cluster.resume(cluster, :n2)
      Process.sleep(2_500)

      assert events_about(cluster, [:suspect, :down, :link_broken]) == []
      assert Enum.all?(views(cluster, :n1), fn {_, peer} -> peer.state == :alive end)
    end

    test "a node with every scheduler busy is not a failure" do
      cluster = start()
      Process.sleep(1_000)
      {:ok, :ok} = Cluster.call(cluster, :n2, Atanor.Test.Busy, :spin, [4_000])
      Process.sleep(4_500)

      assert events_about(cluster, [:suspect, :down, :link_broken]) == []
    end
  end
end
