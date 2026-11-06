defmodule Atanor.Cluster.RoutingTest do
  @moduledoc "Work for a cell runs on the node that owns it (design §8)."
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  setup do
    %{cluster: start_cluster(workers: [Manifests.counter("counter")])}
  end

  defp post(cluster, via, cell, n) do
    {:ok, resp} = request(cluster, via, :post, "/c/#{cell}", body: Integer.to_string(n))
    {resp.status, Jason.decode!(resp.body)}
  end

  test "a request through any node runs on the node that owns the cell", %{cluster: c} do
    assert {200, first} = post(c, :n1, "a", 1)
    {:ok, owner} = owner(c, :n1, "log", "a")
    assert first["node"] == Atom.to_string(owner)

    for via <- Cluster.names(c), n <- 2..3 do
      assert {200, body} = post(c, via, "a", n * 10 + 1)
      assert body["node"] == Atom.to_string(owner)
      assert body["tx_node"] == body["node"]
    end

    forwarded = events(c, [:atanor, :forward], &(&1.cell == {"log", "a"}))
    assert forwarded != []
    assert Enum.all?(forwarded, &(&1.meta.target == owner and &1.meta.result == :ok))

    ran = events(c, [:atanor, :call], &(&1.cell == {"log", "a"}))
    assert Enum.all?(ran, &(&1.meta.node == owner))
    assert Enum.any?(ran, & &1.meta.forwarded)
  end

  test "a cell nobody owns wakes on its preferred node, whatever node got the request", %{cluster: c} do
    nodes =
      for i <- 1..8 do
        {200, body} = post(c, Enum.at(Cluster.names(c), rem(i, 3)), "w#{i}", i)
        body["node"]
      end

    assert length(Enum.uniq(nodes)) > 1
  end

  test "requests carry the deployment of the ingress node (D1)", %{cluster: c} do
    {200, %{"deployment" => id}} = post(c, :n1, "d", 1)
    {200, %{"deployment" => ^id}} = post(c, :n2, "d", 2)
  end

  test "the cell is served by another node after its owner dies", %{cluster: c} do
    {200, _} = post(c, :n1, "k", 1)
    {:ok, owner} = owner(c, :n1, "log", "k")
    dead = name_of(c, owner)
    survivor = Enum.find(Cluster.names(c), &(&1 != dead))
    Cluster.kill(c, dead)

    # The lease has to run out first.
    Await.until(
      fn ->
        {status, _} = post(c, survivor, "k", 2)
        status == 200
      end,
      15_000
    )

    {:ok, resp} = request(c, survivor, :get, "/c/k")
    assert %{"rows" => [1, 2]} = Jason.decode!(resp.body)
    assert {:ok, new_owner} = owner(c, survivor, "log", "k")
    assert new_owner != owner
  end

  describe "when the node that runs a call is lost" do
    setup do
      probe =
        Manifests.probe("probe", cells: %{"notes" => Manifests.notes_migrations()}, routes: [{"127.0.0.1", "/keyed"}])

      # These tests are about the wait for the lease; the takeover (design §8.10) has its own.
      cluster = start_cluster(workers: [probe], atanor: [takeover: [enabled: false]])
      {:ok, owner} = wake(cluster, "gate")
      %{cluster: cluster, owner: name_of(cluster, owner)}
    end

    defp wake(cluster, key) do
      {:ok, result} =
        Cluster.call(cluster, :n1, Atanor.Cell, :owner, [Cluster.instance(cluster), {"notes", key}])

      result
    end

    # Starts a request held in the handler on the owner; returns its task.
    defp held(cluster, ingress, method) do
      pid = Base.encode64(:erlang.term_to_binary(self()))

      task =
        Task.async(fn ->
          request(cluster, ingress, method, "/keyed/gate", headers: [{"x-test-pid", pid}])
        end)

      assert_receive {:in_handler, _handler}, 5_000
      task
    end

    test "a request that may have run is not run again: unknown_outcome", %{cluster: c, owner: owner} do
      ingress = Enum.find(Cluster.names(c), &(&1 != owner))
      task = held(c, ingress, :post)
      Cluster.kill(c, owner)

      assert {:ok, resp} = Task.await(task, 20_000)
      assert resp.status == 503
      assert Jason.decode!(resp.body) == %{"error" => "unknown_outcome", "reason" => "unknown_outcome"}

      assert events(c, [:atanor, :forward], &(&1.cell == {"notes", "gate"}))
             |> Enum.any?(&(&1.meta.result == :unknown_outcome))
    end

    test "a read is retried, and answers unavailable until the lease of the dead owner runs out", %{
      cluster: c,
      owner: owner
    } do
      ingress = Enum.find(Cluster.names(c), &(&1 != owner))
      task = held(c, ingress, :get)
      Cluster.kill(c, owner)

      assert {:ok, resp} = Task.await(task, 20_000)
      assert resp.status == 503
      assert %{"error" => "unavailable", "reason" => reason} = Jason.decode!(resp.body)
      assert reason in ["owner_down", "owner_unreachable"]

      Await.until(fn -> match?({:ok, %{status: 200}}, request(c, ingress, :get, "/keyed/echo2")) end, 15_000)
    end

    test "a write to a cell whose owner is gone is answered 503 until its lease runs out", %{cluster: c} do
      {:ok, echo_owner} = wake(c, "echo")
      owner = name_of(c, echo_owner)
      ingress = Enum.find(Cluster.names(c), &(&1 != owner))
      # The ingress knows the owner, which is gone before the next call starts.
      assert {:ok, %{status: 200}} = request(c, ingress, :post, "/keyed/echo")
      Cluster.kill(c, owner)

      assert {:ok, resp} = request(c, ingress, :post, "/keyed/echo")
      assert resp.status == 503
      assert %{"error" => "unavailable", "reason" => reason} = Jason.decode!(resp.body)
      assert reason in ["owner_down", "owner_unreachable"]

      Await.until(fn -> match?({:ok, %{status: 200}}, request(c, ingress, :post, "/keyed/echo")) end, 15_000)
    end
  end

  describe "a worker that raises its migrations" do
    @v2 [[2, "ALTER TABLE notes ADD COLUMN tag TEXT"]]

    defp probe_with(migrations),
      do: Manifests.probe("probe", cells: %{"notes" => migrations}, routes: [{"127.0.0.1", "/p"}])

    defp sql(cluster, via, op, sql) do
      body = %{op: op, ns: "notes", key: "k", sql: sql}
      {:ok, resp} = request(cluster, via, :post, "/p/cell", json: body)
      Jason.decode!(resp.body)
    end

    test "its cells wake migrated on the node that owns them, not on the node that applied first" do
      # Nodes reload only when told, so a slow machine does not apply the head behind the test's back.
      c = start_cluster(workers: [probe_with(Manifests.notes_migrations())], atanor: [poll_interval_ms: 3_600_000])
      assert %{"ok" => _} = sql(c, :n1, "execute", "INSERT INTO notes (body) VALUES ('old')")
      {:ok, owner} = owner(c, :n1, "notes", "k")
      owner = name_of(c, owner)
      [other | _] = Cluster.names(c) -- [owner]

      {:ok, id} = Cluster.publish(c, probe_with(Manifests.notes_migrations() ++ @v2))
      # Only a node that does not own the cell applies the new version first.
      {:ok, _} = Cluster.activate(c, "probe", id, only: [other])
      assert %{"error" => _} = sql(c, other, "query", "SELECT tag FROM notes")

      {:ok, _} = Cluster.activate(c, "probe", id, only: [owner])

      assert %{"ok" => %{"rows" => [["old", nil]]}} =
               Await.until(
                 fn ->
                   with %{"ok" => _} = reply <- sql(c, other, "query", "SELECT body, tag FROM notes") do
                     reply
                   else
                     _ -> nil
                   end
                 end,
                 10_000
               )

      # Nodes forward their events asynchronously: wait for the first, as under load it may not have arrived.
      migrated =
        await_events(c, [:atanor, :cells, :migrate], &(&1.namespace == "notes" and &1.node == Cluster.node(c, owner)))

      assert Enum.sum(for e <- migrated, do: e.measurements.count) == 1
    end
  end

  describe "a namespace that only some nodes have applied" do
    defp late,
      do: Manifests.probe("late", cells: %{"late" => Manifests.notes_migrations()}, routes: [{"127.0.0.1", "/late"}])

    setup do
      c = start_cluster(workers: [])
      {:ok, id} = Cluster.publish(c, late())
      %{cluster: c, id: id}
    end

    defp touch(c, via, key),
      do: Cluster.call(c, via, Atanor.Cell, :owner, [Cluster.instance(c), {"late", key}])

    test "a node that knows no deployment of it does not create the cell", %{cluster: c} do
      for via <- Cluster.names(c) do
        assert {:ok, {:error, {:bad_migrations, message}}} = touch(c, via, "a")
        assert message =~ "namespace late"
      end
    end

    test "a pinned deployment of it is enough to wake the cell with its tables", %{cluster: c, id: id} do
      for via <- Cluster.names(c),
          do: assert({:ok, {:ok, _}} = Cluster.call(c, via, Atanor.Workers, :pinned, [Cluster.instance(c), "late", id]))

      assert {:ok, {:ok, _}} = touch(c, :n1, "a")

      for via <- Cluster.names(c) do
        assert {:ok, {:ok, %{rows: [[0]]}}} =
                 Cluster.call(c, via, Atanor.Cell, :query, [
                   Cluster.instance(c),
                   {"late", "a"},
                   "SELECT count(*) FROM notes"
                 ])
      end
    end

    test "a request is answered 503 until the node that wakes the cell has applied the worker" do
      c = start_cluster(workers: [], atanor: [poll_interval_ms: 3_600_000])

      keyed =
        Manifests.probe("keyed", cells: %{"notes" => Manifests.notes_migrations()}, routes: [{"127.0.0.1", "/keyed"}])

      {:ok, id} = Cluster.publish(c, keyed)
      {:ok, _} = Cluster.activate(c, "keyed", id, only: [:n1])
      keys = for i <- 1..20, do: "k#{i}"
      status = fn key -> with {:ok, resp} <- request(c, :n1, :get, "/keyed/#{key}"), do: {resp.status, resp.body} end

      replies = Enum.map(keys, status)
      assert Enum.all?(replies, &(match?({200, _}, &1) or match?({503, _}, &1)))
      assert Enum.any?(replies, &match?({503, _}, &1))

      {:ok, _} = Cluster.activate(c, "keyed", id)
      for key <- keys, do: Await.until(fn -> match?({200, _}, status.(key)) end, 10_000)
    end
  end

  describe "sockets and connections stay on the ingress node while the worker runs on the owner" do
    setup do
      mail =
        Manifests.probe("mail",
          module: Atanor.Test.LineWorker,
          cells: %{"mail" => Atanor.Test.LineWorker.migrations()},
          tcp: ["smtp"]
        )

      chat =
        Manifests.probe("chat",
          module: Atanor.Test.SocketWorker,
          sockets: true,
          cells: %{"rooms" => []},
          routes: [{"127.0.0.1", "/room"}]
        )

      %{cluster: start_cluster(workers: [mail, chat], atanor: [listeners: %{"smtp" => 0}])}
    end

    test "a TCP session bound to a cell runs its callbacks on the owner", %{cluster: c} do
      {:ok, port} = Cluster.call(c, :n1, Atanor.TCP, :port, [Cluster.instance(c), "smtp"])
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", elem(port, 1), [:binary, active: false, packet: :line])

      line = fn ->
        {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
        String.trim_trailing(line)
      end

      say = fn text ->
        :ok = :gen_tcp.send(socket, text <> "\r\n")
        line.()
      end

      assert line.() =~ "220"
      assert say.("RCPT bob") == "250 ok"
      node = say.("NODE")
      assert {:ok, owner} = owner(c, :n1, "mail", "bob")
      assert node == Atom.to_string(owner)
      assert say.("DATA") == "354 go ahead"
      :ok = :gen_tcp.send(socket, "hello\r\n")
      assert say.(".") == "250 stored"
      assert say.("QUIT") == "221 bye"
      :gen_tcp.close(socket)

      assert {:ok, {:ok, %{rows: [["hello"]]}}} =
               Cluster.call(c, :n2, Atanor.Cell, :query, [Cluster.instance(c), {"mail", "bob"}, "SELECT body FROM mail"])
    end

    test "a WebSocket attaches on its own node, and a message reaches it from another", %{cluster: c} do
      {:ok, owner} = wake_room(c, "r1")
      [a, b] = Enum.take(Cluster.names(c), 2)

      port = fn name -> c |> Cluster.url(name) |> URI.parse() |> Map.fetch!(:port) end
      {:ok, one} = Atanor.Test.WSClient.connect(port.(a), "/room/r1")
      {:ok, two} = Atanor.Test.WSClient.connect(port.(b), "/room/r1")

      exchange = fn client, text ->
        client = Atanor.Test.WSClient.send_frame(client, {:text, text})
        {{:text, reply}, client} = Atanor.Test.WSClient.recv(client, 5_000)
        {reply, client}
      end

      assert {node, one} = exchange.(one, "node")
      assert node == Atom.to_string(owner)
      assert {":ok", one} = exchange.(one, "join r1")
      assert {":ok", two} = exchange.(two, "say r1 hi")
      assert {{:text, "cell:hi"}, _} = Atanor.Test.WSClient.recv(one, 5_000)
      Atanor.Test.WSClient.close(one)
      Atanor.Test.WSClient.close(two)
    end

    defp wake_room(cluster, key),
      do: Cluster.call(cluster, :n1, Atanor.Cell, :owner, [Cluster.instance(cluster), {"rooms", key}]) |> elem(1)
  end

  describe "expected unavailability" do
    test "an isolated node answers 503 no_quorum with Retry-After, never 500", %{cluster: c} do
      {cell, owner} = owned_cell(c, "iso", [:n2, :n3])
      isolated = Enum.find(Cluster.names(c), &(&1 != owner))
      others = Cluster.names(c) -- [isolated]

      # Let every detector discover its peers before the cut; a node that never
      # knew them has no quorum to lose and cannot report no_quorum.
      for node <- Cluster.names(c) do
        Await.until(
          fn ->
            case Cluster.call(c, node, Atanor.Detector, :peers, [Cluster.instance(c)]) do
              {:ok, peers} -> length(peers) == 2
              _ -> false
            end
          end,
          10_000
        )
      end

      serving = fn node -> Cluster.call(c, node, Atanor.Overview, :serving, [Cluster.instance(c)]) end
      assert {:ok, {200, %{status: "serving"}}} = serving.(isolated)

      for other <- others, do: Cluster.partition_nodes(c, isolated, other)

      # A balancer asking `serving` sees the cut at once after the settle; `ready` stays 200.
      Await.until(fn -> match?({:ok, {503, %{status: "no_quorum"}}}, serving.(isolated)) end, 20_000)

      assert {:ok, {200, %{status: "ready"}}} =
               Cluster.call(c, isolated, Atanor.Overview, :ready, [Cluster.instance(c)])

      for other <- others, do: assert({:ok, {200, %{status: "serving"}}} = serving.(other))

      # The first requests may find the peers in the membership; once the
      # minority verdict settles, every call is no_quorum.
      first =
        Await.until(
          fn ->
            with {:ok, resp} <- request(c, isolated, :post, "/c/#{cell}", body: "2"),
                 %{"reason" => "no_quorum"} <- Jason.decode!(resp.body) do
              resp
            else
              _ -> nil
            end
          end,
          20_000
        )

      assert first.status == 503
      assert first.headers["retry-after"] == ["1"]

      replies =
        for n <- 3..22 do
          {:ok, resp} = request(c, isolated, :post, "/c/#{cell}", body: Integer.to_string(n))
          {resp.status, Jason.decode!(resp.body), resp.headers["retry-after"]}
        end

      assert Enum.all?(replies, fn {status, body, retry} ->
               status == 503 and body["reason"] == "no_quorum" and retry == ["1"]
             end)

      refute Enum.any?(replies, fn {status, _, _} -> status == 500 end)
      Cluster.heal_all(c)
    end
  end

  describe "a node of another store" do
    # The foreign cluster has its own store and prefix, so its identity differs (design §8.4).
    setup %{cluster: c} do
      foreign = start_cluster(names: [:f1], prefix: "foreign", workers: [])
      stranger = Cluster.node(foreign, :f1)

      for name <- Cluster.names(c),
          do: true = :erpc.call(stranger, Node, :connect, [Cluster.node(c, name)])

      %{stranger: stranger}
    end

    test "a stale hint to it is a 500 foreign_store, never retried, logged and counted", %{
      cluster: c,
      stranger: stranger
    } do
      assert {200, _} = write(c, :n1, "fs", 1)
      {:ok, owner} = owner(c, :n1, "log", "fs")
      caller = Enum.find(Cluster.names(c), &(Cluster.node(c, &1) != owner))
      cells = Module.concat(Cluster.instance(c), Cells)
      {:ok, config} = Cluster.call(c, caller, Alambique.Config, :fetch!, [cells])
      {:ok, true} = Cluster.call(c, caller, Alambique.Membership, :put_hint, [config, "log.fs", stranger])

      {:ok, resp} = request(c, caller, :get, "/c/direct/fs")
      assert resp.status == 500
      assert Jason.decode!(resp.body) == %{"error" => "foreign_store", "reason" => "foreign_store"}
      assert resp.headers["retry-after"] == nil

      assert [%{meta: %{node: ^stranger}}] = await_events(c, [:atanor, :foreign_store])
      assert [%{meta: %{kind: :http}}] = await_events(c, [:atanor, :call], &(&1[:reason] == {:foreign_store, stranger}))

      # The hint was dropped: the next request is served.
      {:ok, resp} = request(c, caller, :get, "/c/direct/fs")
      assert resp.status == 200
    end
  end

  describe "remote socket attach" do
    test "a paused peer times out as owner_unreachable" do
      c = start_cluster(workers: [], atanor: [sockets: [attach_timeout_ms: 50]])
      instance = Cluster.instance(c)
      remote = Cluster.node(c, :n1)
      pid = :erpc.call(remote, Process, :whereis, [Module.concat(instance, :Detector)])
      assert is_pid(pid)

      Cluster.pause(c, :n1)
      result = :erpc.call(Cluster.node(c, :n2), Atanor.Sockets, :attach, [instance, pid, {"rooms", "r"}])
      Cluster.resume(c, :n1)

      assert result == {:error, {:unavailable, :owner_unreachable}}
    end
  end
end
