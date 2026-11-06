defmodule Atanor.HotCells.PolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.HotCells.{Cpu, Policy}

  @cfg %{
    write_enter: 500,
    write_exit: 250,
    read_enter: 2_000,
    read_exit: 1_000,
    queue_enter: 50,
    queue_exit: 10,
    cpu_enter: 70,
    cpu_exit: 50,
    margin: 20,
    residence_ms: 300_000,
    max_moves: 2,
    affinity: [{"rooms", "hot"}],
    sustain_ms: 10_000,
    replica_enter: 1_000,
    replica_exit: 500,
    replica_hold_ms: 60_000
  }

  @nodes [:a@h, :b@h, :c@h, :d@h]

  defp sample(opts), do: Map.merge(%{reads: 0, writes: 0, queue: 0}, Map.new(opts))

  describe "hot?/3" do
    test "enters at the enter threshold of any signal" do
      refute Policy.hot?(false, sample(writes: 499), @cfg)
      assert Policy.hot?(false, sample(writes: 500), @cfg)
      assert Policy.hot?(false, sample(reads: 2_000), @cfg)
      assert Policy.hot?(false, sample(queue: 50), @cfg)
    end

    test "a hot cell stays hot above the exit thresholds and leaves under all of them" do
      assert Policy.hot?(true, sample(writes: 250), @cfg)
      assert Policy.hot?(true, sample(queue: 10), @cfg)
      refute Policy.hot?(true, sample(writes: 249, reads: 999, queue: 9), @cfg)
    end

    property "between the thresholds the answer is the previous one" do
      check all(writes <- integer(250..499), reads <- integer(0..999), queue <- integer(0..9), was <- boolean()) do
        assert Policy.hot?(was, sample(writes: writes, reads: reads, queue: queue), @cfg) == was
      end
    end
  end

  describe "replicas/4" do
    @entry %{since: 0, on: false, hot_at: 0, pending: false}

    # Runs the policy over `{time_ms, reads}` samples, making every change at once, and returns the actions.
    defp run(samples) do
      {_, actions} =
        Enum.reduce(samples, {nil, []}, fn {at, reads}, {entry, actions} ->
          {entry, action} = Policy.replicas(entry, reads, at, @cfg)
          entry = if action, do: Policy.confirm_replicas(%{entry | pending: true}, action, true), else: entry
          {entry, if(action, do: [{at, action} | actions], else: actions)}
        end)

      Enum.reverse(actions)
    end

    test "turn on after the enter rate has held for sustain_ms, and not before" do
      assert run([{0, 999}, {10_000, 999}]) == []
      assert run([{0, 1_000}, {9_999, 1_000}]) == []
      assert run([{0, 1_000}, {9_999, 1_000}, {10_000, 1_000}]) == [{10_000, :on}]
    end

    test "a rate that falls under the enter rate before sustain_ms starts the wait again" do
      assert run([{0, 1_000}, {5_000, 999}, {6_000, 1_000}, {15_999, 1_000}]) == []
      assert run([{0, 1_000}, {5_000, 999}, {6_000, 1_000}, {16_000, 1_000}]) == [{16_000, :on}]
    end

    test "turn off after hold_ms under the exit rate; rates between exit and enter keep them on" do
      samples = [{0, 5_000}, {10_000, 5_000}, {20_000, 700}, {70_000, 700}, {80_000, 499}, {129_999, 499}]
      assert run(samples) == [{10_000, :on}]
      assert run(samples ++ [{130_000, 499}]) == [{10_000, :on}, {130_000, :off}]
    end

    test "a read at the exit rate restarts the hold" do
      samples = [{0, 5_000}, {10_000, 5_000}, {20_000, 499}, {60_000, 500}, {119_999, 499}]
      assert run(samples) == [{10_000, :on}]
      assert run(samples ++ [{120_000, 499}]) == [{10_000, :on}, {120_000, :off}]
    end

    test "a change in progress or one that failed is not repeated or lost" do
      assert {%{pending: true}, nil} = Policy.replicas(%{@entry | pending: true}, 5_000, 99_000, @cfg)
      entry = %{@entry | pending: true}
      assert %{pending: false, on: false} = Policy.confirm_replicas(entry, :on, false)
      assert {_, :on} = Policy.replicas(Policy.confirm_replicas(entry, :on, false), 5_000, 99_000, @cfg)
      assert %{on: true, pending: false} = Policy.confirm_replicas(entry, :on, true)
      assert Policy.confirm_replicas(%{entry | on: true}, :off, true) == nil
      assert %{on: true} = Policy.confirm_replicas(%{entry | on: true}, :off, false)
    end

    property "never on and off within hold_ms, and off only after a quiet hold" do
      check all(rates <- list_of(integer(0..3_000), min_length: 1, max_length: 80)) do
        samples = rates |> Enum.with_index() |> Enum.map(fn {reads, i} -> {i * 5_000, reads} end)
        actions = run(samples)

        for {{t1, a1}, {t2, a2}} <- Enum.zip(actions, Enum.drop(actions, 1)) do
          assert a1 != a2
          if a1 == :on, do: assert(t2 - t1 >= @cfg.replica_hold_ms)
        end

        for {t, :off} <- actions do
          quiet = for {at, reads} <- samples, at > t - @cfg.replica_hold_ms, at <= t, do: reads
          assert Enum.all?(quiet, &(&1 < @cfg.replica_exit))
        end
      end
    end
  end

  describe "pressured?/3" do
    test "has an enter and an exit threshold" do
      refute Policy.pressured?(false, 69.9, @cfg)
      assert Policy.pressured?(false, 70, @cfg)
      assert Policy.pressured?(true, 50, @cfg)
      refute Policy.pressured?(true, 49.9, @cfg)
    end
  end

  defp load,
    do:
      gen(
        all(
          cpu <- integer(0..100),
          hot <- integer(0..5),
          tags <- member_of([[], ["hot"], ["gpu"]]),
          do: %{cpu: cpu, hot: hot, tags: tags}
        )
      )

  defp nodes_of(values), do: map(list_of(tuple({member_of(@nodes), values}), max_length: 4), &Map.new/1)

  defp context do
    gen all(
          namespace <- member_of(["rooms", "notes"]),
          self <- member_of(@nodes),
          cpu <- integer(0..100),
          tags <- member_of([[], ["hot"], ["gpu"]]),
          pressured <- boolean(),
          peers <- nodes_of(load()),
          since <- one_of([constant(nil), integer(0..600_000)]),
          moving <- integer(0..3),
          cooling <- nodes_of(integer(1..30_000))
        ) do
      %{
        namespace: namespace,
        self: %{node: self, cpu: cpu, tags: tags, pressured: pressured},
        peers: peers,
        since_move_ms: since,
        moving: moving,
        cooling: cooling
      }
    end
  end

  property "a move never targets this node, a cooling node or an unknown node" do
    check all(ctx <- context()) do
      case Policy.decide(ctx, @cfg) do
        {:move, target, _} ->
          assert target != ctx.self.node
          refute Map.has_key?(ctx.cooling, target)
          assert Map.has_key?(ctx.peers, target)

        {:stay, _} ->
          :ok
      end
    end
  end

  property "a cell inside its residence time, a full cluster or a cooling node never moves" do
    check all(ctx <- context()) do
      decision = Policy.decide(ctx, @cfg)

      if ctx.since_move_ms != nil and ctx.since_move_ms < @cfg.residence_ms, do: assert(decision == {:stay, :residence})

      if ctx.moving >= @cfg.max_moves and not (ctx.since_move_ms != nil and ctx.since_move_ms < @cfg.residence_ms),
        do: assert(decision == {:stay, :cap})

      if Map.has_key?(ctx.cooling, ctx.self.node), do: refute(match?({:move, _, _}, decision))
    end
  end

  property "a load move needs pressure, the margin and the least loaded open node" do
    check all(ctx <- context()) do
      with {:move, target, :load} <- Policy.decide(ctx, @cfg) do
        assert ctx.self.pressured
        assert ctx.peers[target].cpu + @cfg.margin <= ctx.self.cpu
        refute "hot" in ctx.peers[target].tags

        open =
          Enum.reject(ctx.peers, fn {node, l} ->
            node == ctx.self.node or Map.has_key?(ctx.cooling, node) or "hot" in l.tags
          end)

        assert ctx.peers[target].cpu == open |> Enum.map(fn {_, l} -> l.cpu end) |> Enum.min()
      end
    end
  end

  property "an affinity move goes to a node with the tag, and a cell on such a node stays" do
    check all(ctx <- context()) do
      case {ctx.namespace, Policy.decide(ctx, @cfg)} do
        {"rooms", {:move, target, :affinity}} ->
          assert "hot" in ctx.peers[target].tags
          refute "hot" in ctx.self.tags

        {"notes", {:move, _, reason}} ->
          assert reason == :load

        {_, {:stay, :on_dedicated}} ->
          assert ctx.namespace == "rooms" and "hot" in ctx.self.tags

        _ ->
          :ok
      end
    end
  end

  describe "examples" do
    @self %{node: :a@h, cpu: 90, tags: [], pressured: true}
    @ctx %{
      namespace: "notes",
      self: @self,
      peers: %{b@h: %{cpu: 30, hot: 0, tags: []}, c@h: %{cpu: 60, hot: 0, tags: []}},
      since_move_ms: nil,
      moving: 0,
      cooling: %{}
    }

    test "moves to the least loaded node" do
      assert Policy.decide(@ctx, @cfg) == {:move, :b@h, :load}
    end

    test "stays when the node is not under pressure" do
      assert Policy.decide(put_in(@ctx.self.pressured, false), @cfg) == {:stay, :not_pressured}
    end

    test "stays when the best target is not less loaded by the margin" do
      ctx = %{@ctx | peers: %{b@h: %{cpu: 75, hot: 0, tags: []}}}
      assert Policy.decide(ctx, @cfg) == {:stay, :no_margin}
    end

    test "stays with no node to receive it" do
      assert Policy.decide(%{@ctx | peers: %{}}, @cfg) == {:stay, :no_target}
    end

    test "a dedicated node is not offered the cells of other namespaces" do
      ctx = %{@ctx | peers: %{b@h: %{cpu: 0, hot: 0, tags: ["hot"]}, c@h: %{cpu: 40, hot: 0, tags: []}}}
      assert Policy.decide(ctx, @cfg) == {:move, :c@h, :load}
    end

    test "a hot cell of a ruled namespace goes to the tagged node although the node is not under pressure" do
      ctx = %{@ctx | namespace: "rooms", self: %{@self | pressured: false, cpu: 5}}
      ctx = %{ctx | peers: %{b@h: %{cpu: 90, hot: 3, tags: ["hot"]}, c@h: %{cpu: 0, hot: 0, tags: []}}}
      assert Policy.decide(ctx, @cfg) == {:move, :b@h, :affinity}
    end

    test "with no tagged node the load rule decides" do
      ctx = %{@ctx | namespace: "rooms"}
      assert Policy.decide(ctx, @cfg) == {:move, :b@h, :load}
    end

    test "residence time, cap and cooldown come first" do
      assert Policy.decide(%{@ctx | since_move_ms: 10_000}, @cfg) == {:stay, :residence}
      assert Policy.decide(%{@ctx | since_move_ms: 300_000}, @cfg) == {:move, :b@h, :load}
      assert Policy.decide(%{@ctx | moving: 2}, @cfg) == {:stay, :cap}
      assert Policy.decide(%{@ctx | cooling: %{a@h: 5_000}}, @cfg) == {:stay, :cooldown}

      assert Policy.decide(%{@ctx | cooling: %{b@h: 5_000}}, @cfg) == {:move, :c@h, :load}
    end
  end

  describe "Cpu" do
    @sched_before %{schedulers: [{1, 0, 100}, {2, 0, 100}, {3, 0, 100}, {4, 0, 100}, {5, 0, 100}], os: nil}
    @sched_later %{schedulers: [{1, 50, 200}, {2, 100, 200}, {3, 100, 200}, {4, 0, 200}, {5, 100, 200}], os: nil}

    test "counts normal and dirty CPU schedulers against the normal ones" do
      # Busy: 0.5, 1, 1 and 0 of the first four schedulers (the fifth is dirty IO); 2.5 of 2 cores is capped.
      assert %{cpu: 100.0, os: nil} = Cpu.utilization(@sched_before, @sched_later, {2, 2})
      assert %{cpu: cpu} = Cpu.utilization(@sched_before, @sched_later, {3, 1})
      assert Float.round(cpu, 1) == 83.3
    end

    test "the machine counts when the schedulers look idle" do
      idle = %{schedulers: [{1, 0, 100}], os: Cpu.parse_stat("cpu  100 0 100 800 0 0 0 0")}
      later = %{schedulers: [{1, 1, 200}], os: Cpu.parse_stat("cpu  400 0 300 1000 0 0 0 100")}

      # 600 of 800 ticks busy, steal included; the scheduler saw 1 %.
      assert %{cpu: 75.0, scheduler: scheduler, os: 75.0} = Cpu.utilization(idle, later, {1, 0})
      assert scheduler < 2
    end

    test "parses /proc/stat and refuses other lines" do
      assert Cpu.parse_stat("cpu  10 1 5 80 2 0 1 1 0 0") == {18, 100}
      assert Cpu.parse_stat("cpu0 10 1 5 80 2 0 1 1 0 0") == nil
      assert Cpu.parse_stat("cpu  10 1") == nil
    end
  end
end
