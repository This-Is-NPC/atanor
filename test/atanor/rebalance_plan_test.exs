defmodule Atanor.RebalancePlanTest do
  @moduledoc """
  The decisions of the rebalance on join (design §8.1), with no cluster: what a plan hands out and in which
  order, and, over random sequences of joins and leaves, that no cell is chased in a loop.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Rebalance.Plan

  @nodes [:a, :b, :c, :d, :e]
  @cells for i <- 1..40, do: "c#{i}"
  @max_rounds 12

  # The formula of `Alambique.Membership.preferred/2`.
  defp preferred(members, id), do: Enum.max_by(members, &{:erlang.phash2({id, &1}, 4_294_967_296), &1})

  describe "a round" do
    test "lists the cells whose preferred node is another, coldest first" do
      entries = [{"hot", 90}, {"stays", 5}, {"cold", 10}, {"cool", 40}]
      preferred = fn id -> if id == "stays", do: :me, else: :other end

      plan = Plan.round(Plan.new(), entries, preferred, :me, [])
      assert drain(plan, fn _ -> {:move, :other} end) == ["cold", "cool", "hot"]
    end

    test "leaves out the cells that are waking, pinned or already handed out" do
      entries = [{"waking", nil}, {"pinned", 1}, {"done", 2}, {"free", 3}]
      pinned = MapSet.new(["pinned"])

      plan = Plan.round(Plan.new(), entries, fn _ -> :other end, :me, pinned)
      assert {{:move, "done", :other}, plan} = Plan.next(plan, fn _ -> {:move, :other} end)
      assert {{:move, "free", :other}, plan} = Plan.next(plan, fn _ -> {:move, :other} end)

      plan = Plan.round(plan, entries, fn _ -> :other end, :me, pinned)
      assert Plan.pending(plan) == 0
    end
  end

  describe "a step" do
    test "drops a cell that no longer needs to move" do
      plan = Plan.round(Plan.new(), [{"a", 1}, {"b", 2}], fn _ -> :other end, :me, [])
      assert {{:move, "b", :other}, plan} = Plan.next(plan, fn id -> if id == "a", do: :stay, else: {:move, :other} end)
      assert Plan.pending(plan) == 0
    end

    test "leaves a cell with a call in flight for the next steps, and then for the next round" do
      plan = Plan.round(Plan.new(), [{"busy", 1}, {"idle", 2}], fn _ -> :other end, :me, [])
      check = fn id -> if id == "busy", do: :busy, else: {:move, :other} end

      assert {{:move, "idle", :other}, plan} = Plan.next(plan, check)
      assert Plan.pending(plan) == 1

      plan = Enum.reduce(1..2, plan, fn _, plan -> elem(Plan.next(plan, check), 1) end)
      assert {plan.deferred, Plan.pending(plan)} == {0, 1}
      assert {:none, plan} = Plan.next(plan, check)
      assert {plan.deferred, Plan.pending(plan)} == {1, 0}
    end

    test "looks at each cell once per step, up to a bound" do
      entries = for i <- 1..100, do: {"c#{i}", i}
      plan = Plan.round(Plan.new(), entries, fn _ -> :other end, :me, [])
      assert {:none, plan} = Plan.next(plan, fn _ -> :busy end)
      assert Plan.pending(plan) == 100
    end
  end

  defp drain(plan, check) do
    case Plan.next(plan, check) do
      {{:move, id, _}, plan} -> [id | drain(plan, check)]
      {:none, _} -> []
    end
  end

  # A cluster where each node holds the cells that are awake on it. A move works, fails and the cell stays, or
  # works and the cell is back on its node (a call woke it there again). A cell may have a call in flight.
  # Every node runs its plan, round after round, until a round finds nothing, as the server does.
  defp cluster(members), do: %{members: members, where: Map.new(@cells, &{&1, preferred(members, &1)})}

  defp change(%{members: members, where: where}, {:join, node}) do
    if node not in members, do: %{members: Enum.sort([node | members]), where: where}
  end

  defp change(%{members: members, where: where}, {:leave, node}) do
    remaining = members -- [node]

    if node in members and remaining != [] do
      # The leaving node hands its cells off: they wake where the others prefer.
      handed = for {id, at} <- where, into: %{}, do: {id, if(at == node, do: preferred(remaining, id), else: at)}
      %{members: remaining, where: handed}
    end
  end

  # One change of the membership. `views` say what each node believes: a node can lag and still see the
  # members of before. Returns the cluster, the `{node, cell}` pairs handed out, and the rounds that found work.
  defp settle(cluster, previous, views, faults?) do
    view = fn node -> if views[node] == :stale and node in previous, do: previous, else: cluster.members end
    plans = Map.new(cluster.members, &{&1, Plan.new()})
    rounds(cluster, plans, {view, faults?}, [], 1)
  end

  # The rounds that found work, or one more than the bound when the plans never run out of work.
  defp rounds(cluster, plans, {view, _} = env, handed, number) do
    plans =
      Map.new(plans, fn {node, plan} ->
        entries = for {id, ^node} <- cluster.where, do: {id, 0}
        {node, Plan.round(plan, entries, &preferred(view.(node), &1), node, [])}
      end)

    cond do
      Enum.all?(plans, fn {_, plan} -> Plan.pending(plan) == 0 end) ->
        {cluster, handed, number - 1}

      number > @max_rounds ->
        {cluster, handed, number}

      true ->
        {cluster, plans, handed} =
          Enum.reduce(cluster.members, {cluster, plans, handed}, fn node, acc -> run(node, acc, env) end)

        rounds(cluster, plans, env, handed, number + 1)
    end
  end

  defp run(node, {cluster, plans, handed}, {view, faults?} = env) do
    check = fn id ->
      target = preferred(view.(node), id)

      cond do
        cluster.where[id] != node or target == node or target not in cluster.members -> :stay
        faults? and :rand.uniform() < 0.1 -> :busy
        true -> {:move, target}
      end
    end

    case Plan.next(plans[node], check) do
      {{:move, id, target}, plan} ->
        outcome = if faults?, do: outcome(:rand.uniform()), else: :ok
        where = if outcome == :ok, do: Map.put(cluster.where, id, target), else: cluster.where
        run(node, {%{cluster | where: where}, Map.put(plans, node, plan), [{node, id} | handed]}, env)

      {:none, plan} ->
        acc = {cluster, Map.put(plans, node, plan), handed}
        if Plan.pending(plan) == 0, do: acc, else: run(node, acc, env)
    end
  end

  defp outcome(roll) when roll < 0.7, do: :ok
  defp outcome(roll) when roll < 0.85, do: :failed
  defp outcome(_roll), do: :bounced

  defp events, do: list_of({member_of([:join, :leave]), member_of(@nodes)}, min_length: 1, max_length: 8)

  property "with failures, bounces and nodes that lag, a node hands a cell out at most once per change" do
    check all(
            events <- events(),
            seed <- integer(1..1_000_000),
            lag <- list_of(member_of([:fresh, :stale]), length: length(@nodes)),
            max_runs: 200
          ) do
      views = Map.new(Enum.zip(@nodes, lag))
      :rand.seed(:exsss, seed)

      Enum.reduce(events, cluster([:a, :b]), fn event, cluster ->
        case change(cluster, event) do
          nil ->
            cluster

          next ->
            {next, handed, rounds} = settle(next, cluster.members, views, true)
            repeated = for {key, [_, _ | _]} <- Enum.group_by(handed, & &1), do: key
            assert repeated == [], "handed out again within one change: #{inspect(repeated)}"
            assert rounds <= @max_rounds, "still moving after #{rounds} rounds"
            next
        end
      end)
    end
  end

  property "with the same view everywhere a cell moves at most once per change and settles on its preferred node" do
    check all(events <- events(), max_runs: 200) do
      views = Map.new(@nodes, &{&1, :fresh})

      Enum.reduce(events, cluster([:a, :b]), fn event, cluster ->
        case change(cluster, event) do
          nil ->
            cluster

          next ->
            {next, handed, _rounds} = settle(next, cluster.members, views, false)
            assert handed |> Enum.map(&elem(&1, 1)) |> Enum.frequencies() |> Map.values() |> Enum.all?(&(&1 == 1))
            assert next.where == Map.new(@cells, &{&1, preferred(next.members, &1)})

            # The membership did not change: nothing moves.
            assert {_, [], 0} = settle(next, next.members, views, false)
            next
        end
      end)
    end
  end
end
