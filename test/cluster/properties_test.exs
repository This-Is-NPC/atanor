defmodule Atanor.Cluster.PropertiesTest do
  @moduledoc """
  Properties on a cluster of peer nodes (design §11).

  **C1.** Random requests through random ingress nodes, interleaved with node
  kills and restarts, store faults and partitions of the store and of the
  distribution. After the cluster is healed:

    * every acknowledged request ran its handler on the node that committed its
      transaction, which holds the lease;
    * acknowledged requests for one cell never overlap in time across nodes,
      and acknowledged batches never overlap in epochs;
    * a counter cell has every acknowledged increment once, and no increment
      twice. Requests that did not get an answer may or may not be in the cell;
      they are counted.

  The run includes takeovers (design §8.10): `lose` freezes a node until a survivor
  confirms it down, serves its cells through the survivors (which takes them over)
  and thaws it as a false positive, and `steal` takes a cell from a healthy owner.
  The old owner is fenced, so the data properties must hold. For a cell that was
  taken, the two placement checks (the handler ran where the batch committed, no
  overlap in time) are skipped: a callback that started before the takeover ends
  its write through the new owner.

  **D1 across nodes.** A request forwarded to another node runs entirely on the
  deployment the ingress pinned, also while nodes switch at different times.

  **Alarms.** Alarms set through random nodes fire at least once although nodes
  die and return; duplicates are counted and bounded.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{C1, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 900_000

  @names [:n1, :n2, :n3]
  @ttl_ms 2_000
  @skew_ms 400
  # Lease expiry plus margin, a wake and slack for a loaded machine.
  @available_within_ms @ttl_ms + @skew_ms + 10_000
  # A node that was not told it lost a cell starts no handler for it later than this after the takeover:
  # `routing.owner_check_ms` plus a lease read, with room for a loaded machine.
  @owner_check_ms 500
  @window_ms @owner_check_ms + 1_000
  # Fast enough that a frozen node is confirmed down within the run.
  @detector [
    interval_ms: 200,
    phi_threshold: 8,
    min_std_ms: 50,
    acceptable_pause_ms: 600,
    indirect: [k: 2, timeout_ms: 500]
  ]

  describe "C1" do
    @cells ["c0", "c1", "c2"]

    defp c1_op do
      node = member_of(@names)
      pair = member_of([{:n1, :n2}, {:n1, :n3}, {:n2, :n3}])

      frequency([
        {12, tuple({constant(:request), node, member_of(@cells)})},
        {3, tuple({constant(:burst), node, member_of(@cells)})},
        {3, tuple({constant(:kill), node})},
        {3, tuple({constant(:restart), node})},
        {2, tuple({constant(:pause), node})},
        {2, tuple({constant(:lose), node})},
        {2, tuple({constant(:steal), node, member_of(@cells)})},
        {2, tuple({constant(:resume), node})},
        {2, tuple({constant(:store_fault), node, member_of([:error, :timeout, :lost_ack]), integer(1..4)})},
        {1, tuple({constant(:partition_store), node})},
        {1, tuple({constant(:heal_store), node})},
        {1, tuple({constant(:partition_nodes), pair})},
        {1, tuple({constant(:heal_nodes), pair})},
        {4, tuple({constant(:pass), integer(100..1500)})}
      ])
    end

    property "requests are served by the single owner of their cell, across failures" do
      check all(
              ops <- resize(list_of(c1_op(), min_length: 20, max_length: 40), 40),
              max_runs: 12,
              max_shrinking_steps: 0
            ) do
        cluster =
          start_cluster(
            names: @names,
            ttl_ms: @ttl_ms,
            skew_margin_ms: @skew_ms,
            atanor: [detector: @detector, routing: [owner_check_ms: @owner_check_ms]],
            workers: [Manifests.counter("counter")]
          )

        try do
          run = Enum.reduce(ops, new_run(), &step(cluster, &1, &2))
          settle(cluster, run)
          verify(cluster, run)
        after
          Process.unlink(cluster)
          Cluster.stop(cluster)
        end
      end
    end

    defp new_run, do: %{seq: 0, requests: [], dead: MapSet.new(), paused: MapSet.new()}

    # A frozen node answers nobody, so clients would only wait for their timeout.
    defp step(cluster, {kind, node, _cell} = op, run) when kind in [:request, :burst] do
      if node in run.paused, do: run, else: send_requests(cluster, op, run)
    end

    defp step(cluster, {:kill, node}, run) do
      step(cluster, {:resume, node}, run)
      unless node in run.dead, do: Cluster.kill(cluster, node)
      %{run | dead: MapSet.put(run.dead, node)}
    end

    defp step(cluster, {:pause, node}, run) do
      if node in run.dead or node in run.paused, do: run, else: pause(cluster, node, run)
    end

    defp step(cluster, {:resume, node}, run) do
      if node in run.paused, do: Cluster.resume(cluster, node)
      %{run | paused: MapSet.delete(run.paused, node)}
    end

    # The node is frozen until a survivor has it down; requests through the
    # survivors take its cells over; then it wakes up as a false positive.
    defp step(cluster, {:lose, node}, run) do
      survivors = @names -- [node | MapSet.to_list(MapSet.union(run.dead, run.paused))]

      if node in run.dead or node in run.paused or survivors == [] do
        run
      else
        Cluster.pause(cluster, node)
        await_down(cluster, survivors, node)

        run =
          Enum.reduce(@cells, run, fn cell, run ->
            {request, run} = issue(cluster, hd(survivors), cell, run)
            %{run | requests: [request | run.requests]}
          end)

        Cluster.resume(cluster, node)
        run
      end
    end

    # A healthy owner loses a cell to another node: it must be fenced.
    defp step(cluster, {:steal, node, cell}, run) do
      unless node in run.dead or node in run.paused do
        cells = Module.concat(Cluster.instance(cluster), Cells)
        Cluster.call(cluster, node, Alambique, :take_over, [cells, "log." <> cell, :test])
      end

      run
    end

    defp step(cluster, {:restart, node}, run) do
      # A node that cannot read the store does not start (design §2.1), so its partition ends first.
      if node in run.dead do
        Cluster.heal_store(cluster, node)
        Cluster.restart(cluster, node)
      end

      %{run | dead: MapSet.delete(run.dead, node)}
    end

    defp step(cluster, {:store_fault, node, kind, times}, run) do
      Cluster.inject(cluster, node, kind: kind, times: times, ms: 700, ops: [:put, :get, :list])
      run
    end

    defp step(cluster, {:partition_store, node}, run), do: tap(run, fn _ -> Cluster.partition_store(cluster, node) end)
    defp step(cluster, {:heal_store, node}, run), do: tap(run, fn _ -> Cluster.heal_store(cluster, node) end)

    defp step(cluster, {:partition_nodes, {a, b}}, run),
      do: tap(run, fn _ -> if both_reachable?(run, a, b), do: Cluster.partition_nodes(cluster, a, b) end)

    defp step(cluster, {:heal_nodes, {a, b}}, run),
      do: tap(run, fn _ -> if both_reachable?(run, a, b), do: Cluster.heal_nodes(cluster, a, b) end)

    defp step(_cluster, {:pass, ms}, run), do: tap(run, fn _ -> Process.sleep(ms) end)

    defp await_down(cluster, survivors, node) do
      target = Cluster.node(cluster, node)

      Enum.any?(1..100, fn _ ->
        Process.sleep(100)
        Enum.any?(survivors, &down?(cluster, &1, target))
      end)
    end

    defp down?(cluster, via, target) do
      case Cluster.call(cluster, via, Atanor.Detector, :peers, [Cluster.instance(cluster)]) do
        {:ok, peers} -> Enum.any?(peers, &(&1.node == target and &1.state == :down))
        _ -> false
      end
    end

    defp pause(cluster, node, run) do
      Cluster.pause(cluster, node)
      %{run | paused: MapSet.put(run.paused, node)}
    end

    defp send_requests(cluster, {:request, node, cell}, run) do
      {request, run} = issue(cluster, node, cell, run)
      %{run | requests: [request | run.requests]}
    end

    defp send_requests(cluster, {:burst, node, cell}, run) do
      {numbers, run} = Enum.map_reduce(1..3, run, fn _, run -> {run.seq + 1, %{run | seq: run.seq + 1}} end)

      requests =
        numbers
        |> Task.async_stream(&send_request(cluster, node, cell, &1), max_concurrency: 3, timeout: :infinity)
        |> Enum.map(fn {:ok, request} -> request end)

      %{run | requests: requests ++ run.requests}
    end

    defp both_reachable?(run, a, b), do: Enum.all?([a, b], &(&1 not in run.dead and &1 not in run.paused))

    defp issue(cluster, node, cell, run) do
      n = run.seq + 1
      {send_request(cluster, node, cell, n), %{run | seq: n}}
    end

    # The outcome of one increment: `:acked` with the handler's report, or `:unknown`.
    defp send_request(cluster, node, cell, n) do
      outcome =
        case request(cluster, node, :post, "/c/#{cell}", body: Integer.to_string(n)) do
          {:ok, %{status: 200, body: body}} -> {:acked, Jason.decode!(body)}
          _ -> :unknown
        end

      %{n: n, cell: cell, outcome: outcome}
    end

    defp settle(cluster, run) do
      for node <- run.paused, do: Cluster.resume(cluster, node)
      Cluster.heal_all(cluster)
      for node <- run.dead, do: Cluster.restart(cluster, node)
    end

    defp verify(cluster, run) do
      requests = Enum.reverse(run.requests)
      started = System.monotonic_time(:millisecond)

      rows =
        for cell <- @cells, into: %{}, do: {cell, C1.read_when_available(cluster, @names, cell, @available_within_ms)}

      waited = System.monotonic_time(:millisecond) - started
      assert waited <= @available_within_ms, "cells took #{waited} ms to come back"

      for cell <- @cells do
        mine = Enum.filter(requests, &(&1.cell == cell))
        attempted = Enum.map(mine, & &1.n)
        acked = for %{outcome: {:acked, _}, n: n} <- mine, do: n
        stored = rows[cell]

        assert stored == Enum.uniq(stored), "cell #{cell} applied an increment twice: #{inspect(stored)}"
        assert stored -- attempted == [], "cell #{cell} has increments nobody sent"
        assert acked -- stored == [], "cell #{cell} lost acknowledged increments #{inspect(acked -- stored)}"

        check_placement(cluster, cell, mine)
      end

      C1.check_epochs(Cluster.events(cluster))

      unknown = Enum.count(requests, &(&1.outcome == :unknown))

      windows = drain_windows()

      IO.puts(
        "C1: #{length(requests)} requests, #{length(requests) - unknown} acknowledged, #{unknown} without an answer" <>
          if(windows == [],
            do: "",
            else: ", #{length(windows)} started on an old owner, latest #{Enum.max(windows)} ms after the takeover"
          )
      )
    end

    defp drain_windows do
      receive do
        {:window, ms} -> [ms | drain_windows()]
      after
        0 -> []
      end
    end

    # The handler ran on the node whose cell process committed the transaction, and acknowledged requests
    # for one cell do not overlap in time across nodes, except for the window of a takeover (design §8.13):
    # a handler that started on the owner before the takeover ends its write through the new owner, and a
    # node that was not told it lost the cell starts no handler more than `routing.owner_check_ms` after
    # the takeover. The data properties are not relaxed for any cell.
    defp check_placement(cluster, cell, requests) do
      takeovers =
        for %{event: [:alambique, :lease, :take_over], meta: %{result: :ok, cell: "log." <> ^cell}} = e <-
              Cluster.events(cluster),
            do: %{at: e.at, taker: Atom.to_string(Cluster.node(cluster, e.node))}

      C1.check_placement(cluster, cell, requests, &explained!(cell, &1, &2, takeovers))
    end

    # A handler on another node than the commit is explained by a takeover: it started before one finished
    # and before the batch committed, or it started on the old owner at most `@window_ms` after the last one.
    defp explained!(cell, n, body, takeovers) do
      from = body["from"]
      before = Enum.filter(takeovers, &(&1.at <= from))

      cond do
        Enum.any?(takeovers, &(&1.at > from and &1.at <= body["to"])) ->
          :ok

        before != [] ->
          last = Enum.max_by(before, & &1.at)
          window = div(from - last.at, 1_000)

          assert last.taker != body["node"],
                 "increment #{n} of #{cell} ran on #{body["node"]}, the node that took the cell"

          assert window <= @window_ms,
                 "increment #{n} of #{cell} started on #{body["node"]} #{window} ms after the takeover (bound #{@window_ms})"

          send(self(), {:window, window})

        true ->
          flunk(
            "increment #{n} of #{cell} ran on #{body["node"]} and committed on #{body["tx_node"]}, with no takeover"
          )
      end
    end
  end

  describe "D1 across nodes" do
    @versions 4

    defp manifest(n),
      do: Manifests.probe("w", cells: %{"notes" => []}, routes: [{"span.test", "/keyed"}], limits: %{"timeout_ms" => n})

    # `where` says which nodes switch: the ingress, the owner or both.
    defp d1_op,
      do:
        one_of([
          tuple({constant(:activate), integer(1..@versions), member_of([:all, :ingress, :owner])}),
          tuple({constant(:rollback), member_of([:all, :ingress, :owner])}),
          constant(:request),
          constant(:release)
        ])

    property "a forwarded request runs entirely on the deployment pinned at ingress" do
      check all(
              ops <- resize(list_of(d1_op(), min_length: 12, max_length: 25), 25),
              max_runs: 8,
              max_shrinking_steps: 0
            ) do
        # Nodes reload only when told, so they can run different versions.
        cluster =
          start_cluster(
            names: [:n1, :n2],
            ttl_ms: @ttl_ms,
            skew_margin_ms: @skew_ms,
            atanor: [poll_interval_ms: 3_600_000]
          )

        try do
          ids = for n <- 1..@versions, into: %{}, do: {n, elem(Cluster.publish(cluster, manifest(n)), 1)}
          {:ok, _} = Cluster.activate(cluster, "w", ids[1])

          {:ok, owner} = Cluster.call(cluster, :n1, Atanor.Cell, :owner, [Cluster.instance(cluster), {"notes", "span"}])
          owner = name_of(cluster, elem(owner, 1))
          ingress = Enum.find([:n1, :n2], &(&1 != owner))

          ctx = %{
            cluster: cluster,
            ingress: ingress,
            owner: owner,
            ids: ids,
            versions: Map.new(ids, fn {n, id} -> {id, n} end)
          }

          final = Enum.reduce(ops, %{open: []}, &d1_step(&1, &2, ctx))
          Enum.reduce(final.open, final, fn _, state -> d1_step(:release, state, ctx) end)
        after
          Process.unlink(cluster)
          Cluster.stop(cluster)
        end
      end
    end

    defp d1_step({:activate, n, where}, state, ctx) do
      {:ok, _} = Cluster.activate(ctx.cluster, "w", ctx.ids[n], only: nodes(where, ctx))
      state
    end

    defp d1_step({:rollback, where}, state, ctx) do
      _ = Cluster.rollback(ctx.cluster, "w", only: nodes(where, ctx))
      state
    end

    defp d1_step(:request, state, ctx) do
      seen = Cluster.status(ctx.cluster, ctx.ingress)["w"].applied
      pid = Base.encode64(:erlang.term_to_binary(self()))

      task =
        Task.async(fn ->
          request(ctx.cluster, ctx.ingress, :get, "/keyed/span", headers: [{"host", "span.test"}, {"x-test-pid", pid}])
        end)

      assert_receive {:in_handler, handler}, 10_000
      %{state | open: state.open ++ [%{task: task, handler: handler, seen: seen}]}
    end

    defp d1_step(:release, %{open: []} = state, _ctx), do: state

    defp d1_step(:release, %{open: [request | rest]} = state, ctx) do
      send(request.handler, :go)
      {:ok, resp} = Task.await(request.task, 10_000)
      body = Jason.decode!(resp.body)

      assert body["start"] == body["end"]
      assert body["start"] == request.seen
      assert body["limit"] == ctx.versions[body["start"]]
      assert body["node"] == Atom.to_string(Cluster.node(ctx.cluster, ctx.owner))
      %{state | open: rest}
    end

    defp nodes(:all, ctx), do: [ctx.ingress, ctx.owner]
    defp nodes(:ingress, ctx), do: [ctx.ingress]
    defp nodes(:owner, ctx), do: [ctx.owner]
  end
end
