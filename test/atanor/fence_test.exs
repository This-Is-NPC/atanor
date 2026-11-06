defmodule Atanor.FenceTest do
  @moduledoc """
  A node cut off from the store keeps no handler of its cells running after its lease ends minus the skew
  margin (design §8.13). The store is the in-memory store with a partition; the clock is the system clock,
  because the cell renews its lease on real timers.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias AlambiqueTestkit.MemoryStore
  alias Atanor.{Cell, Jobs, Registry}
  alias Atanor.Test.{Await, Fence, Manifests}
  alias AtanorTestkit.Node

  @moduletag timeout: 120_000

  # The handler is far longer than any lease below, so only the fence can end it before it returns.
  defmodule SlowReads do
    @moduledoc "A store that waits before each read of an object while `:slow` is set, and passes every call on."
    @behaviour Alambique.Store

    def wrap({module, config}), do: {__MODULE__, {module, config}}

    @impl true
    def put({m, c}, key, body, condition, meta), do: m.put(c, key, body, condition, meta)
    @impl true
    def get({m, c}, key), do: :persistent_term.get({__MODULE__, :slow}, 0) |> Process.sleep() && m.get(c, key)
    @impl true
    def head({m, c}, key), do: m.head(c, key)
    @impl true
    def get_range({m, c}, key, offset, length), do: m.get_range(c, key, offset, length)
    @impl true
    def list({m, c}, prefix, after_key, limit), do: m.list(c, prefix, after_key, limit)
    @impl true
    def delete({m, c}, key), do: m.delete(c, key)
  end

  @handler_ms 6_000
  # The kill happens in a `receive ... after` set to the deadline: it is late by the timer, the scheduler and
  # the kill. Pulses are 5 ms apart. The overshoot measured in the runs recorded in the design is printed
  # by `ATANOR_TEST_VERBOSE=1`; this bound is several times above it and far below the shortest lease.
  # A VM that the host does not schedule (a loaded machine stalls even a bare 5 ms timer by hundreds of ms)
  # cannot run the kill: `stall_end/2` finds such a stall around the deadline and the bound moves to its end.
  @tolerance_ms 60
  @tick_ms 5

  defp start(ttl, margin, check) do
    node =
      Node.start(
        workers: [Manifests.jobs("jobs")],
        alambique: [lease_ttl_ms: ttl, skew_margin_ms: margin],
        routing: Fence.routing(fence_check_ms: check),
        jobs: [timeout_ms: 30_000, claim_ms: 60_000]
      )

    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp lease(node, key) do
    {:ok, id} = Cell.id({"jobs", key})
    {:ok, lease} = Alambique.lease(Registry.config(node.name).alambique, id)
    lease
  end

  defp run(ttl, margin, check, isolate_after, key) do
    node = start(ttl, margin, check)
    table = :"pulses_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public, :bag])
    {:ok, _} = Cell.query(node.name, {"jobs", key}, "SELECT 1")
    ticks = :ets.new(:ticks, [:public, :ordered_set])
    probe = spawn_link(fn -> tick(ticks) end)
    spec = %{kind: "test", payload: "pulse:#{@handler_ms}:#{table}"}
    {:ok, _id} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", key}, spec)
    Await.until(fn -> :ets.member(table, :pulse) end, 10_000)
    Process.sleep(isolate_after)

    # The lease as the store has it when the node is cut off. A renewal between the two calls would only
    # make the fence stricter than the bound below.
    expires = lease(node, key).expires_at_ms
    {_module, config} = node.store
    fault = MemoryStore.partition(config, node())
    on_exit(fn -> if Process.alive?(node.pid), do: MemoryStore.remove(config, fault) end)

    deadline = expires - margin
    Await.until(fn -> System.os_time(:millisecond) > deadline + @tolerance_ms + 500 end, 30_000)
    pulses = for {:pulse, ms} <- :ets.lookup(table, :pulse), do: ms
    Process.unlink(probe)
    Process.exit(probe, :kill)
    {deadline, Enum.max(pulses), :ets.member(table, :end), stall_end(:ets.tab2list(ticks), deadline)}
  end

  # A probe in the VM beside the handler, to tell a late kill from a VM that was not running.
  defp tick(table) do
    :ets.insert(table, {System.os_time(:millisecond)})
    Process.sleep(@tick_ms)
    tick(table)
  end

  # The end of the longest gap between probe ticks that began by the deadline and ended after it, when the
  # gap is longer than the tolerance; else the deadline. Nothing in the VM could run during that gap.
  defp stall_end(ticks, deadline) do
    times = Enum.map(ticks, &elem(&1, 0))

    times
    |> Enum.zip(tl(times))
    |> Enum.filter(fn {from, to} ->
      from <= deadline + @tolerance_ms and to >= deadline and to - from > @tolerance_ms
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.max(fn -> deadline end)
  end

  property "no handler runs after the lease ends minus the skew margin" do
    check all(
            margin <- integer(100..300//50),
            extra <- integer(500..1_200//100),
            check <- integer(100..600//100),
            isolate_after <- integer(0..400//100),
            max_runs: 6,
            max_shrinking_steps: 0
          ) do
      ttl = 2 * margin + extra

      {deadline, last, finished?, stalled_until} =
        run(ttl, margin, check, isolate_after, "p#{System.unique_integer([:positive])}")

      if System.get_env("ATANOR_TEST_VERBOSE"),
        do:
          IO.puts(
            "fence: ttl #{ttl} margin #{margin} check #{check}: last pulse #{last - deadline} ms after the deadline"
          )

      refute finished?, "the handler ran to its end"

      assert last <= max(deadline, stalled_until) + @tolerance_ms,
             "a handler ran #{last - deadline} ms after the deadline (VM stalled until #{stalled_until - deadline})"
    end
  end

  describe "after an early takeover" do
    @margin_ms 100

    defp start_deferred do
      node =
        Node.start(
          workers: [Manifests.jobs("jobs", routes: []), Manifests.probe("clock", alarm_manifest())],
          alambique: [lease_ttl_ms: 1_000, skew_margin_ms: @margin_ms],
          routing: Fence.routing(),
          alarms: [tick_ms: 50],
          jobs: [wait_ms: 50]
        )

      on_exit(fn -> Node.stop(node) end)
      node
    end

    defp alarm_manifest do
      [
        module: Atanor.Test.AlarmWorker,
        alarms: true,
        cells: %{"clock" => Atanor.Test.AlarmWorker.migrations()},
        routes: [{"127.0.0.1", "/"}]
      ]
    end

    property "no job or alarm handler starts before the previous lease's expiry plus the margin" do
      check all(
              hold_ms <- integer(300..1_500//150),
              max_runs: 5,
              max_shrinking_steps: 0
            ) do
        node = start_deferred()
        config = Registry.config(node.name)
        table = :"deferred_#{System.unique_integer([:positive])}"
        :ets.new(table, [:named_table, :public, :bag])
        key = "d#{System.unique_integer([:positive])}"
        {:ok, id} = Cell.id({"jobs", key})
        {:ok, _} = Cell.query(node.name, {"jobs", key}, "SELECT 1")
        {:ok, _} = Cell.query(node.name, {"clock", key}, "SELECT 1")

        # What `Atanor.Takeover` does with the lease it read: its expiry was `hold_ms - margin` from now.
        until = System.os_time(:millisecond) + hold_ms
        {:ok, clock_id} = Cell.id({"clock", key})
        :ok = Atanor.Fence.hold(config, id, until - @margin_ms)
        :ok = Atanor.Fence.hold(config, clock_id, until - @margin_ms)

        {:ok, _} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", key}, %{kind: "test", payload: "pulse:50:#{table}"})
        query = URI.encode_query(key: key, at: System.os_time(:millisecond), payload: "ok")
        assert Req.get!("#{node.url}/set?#{query}", retry: false).body == ":ok"

        Await.until(fn -> :ets.member(table, :end) end, 10_000)
        job_start = :ets.lookup(table, :pulse) |> Enum.map(&elem(&1, 1)) |> Enum.min()

        # The alarm handler writes a row; the first time the row is seen is not before the handler ran.
        alarm_at =
          Await.until(
            fn ->
              {:ok, %{rows: rows}} = Cell.query(node.name, {"clock", key}, "SELECT count(*) FROM fires")
              if rows == [[1]], do: System.os_time(:millisecond)
            end,
            10_000
          )

        assert job_start >= until, "the job started #{until - job_start} ms before the hold ended"
        assert alarm_at >= until, "the alarm fired #{until - alarm_at} ms before the hold ended"
      end
    end

    test "a hold is not evicted when the lease table reaches its bound, and ends at its instant" do
      node =
        Node.start(
          alambique: [lease_ttl_ms: 1_000, skew_margin_ms: @margin_ms],
          routing: Fence.routing(owner_check_cells: 3)
        )

      on_exit(fn -> Node.stop(node) end)
      config = Registry.config(node.name)
      :ok = Atanor.Fence.hold(config, "held.cell", System.os_time(:millisecond) + 400 - @margin_ms)

      # Past the bound the lease table is emptied again and again.
      for i <- 1..10, do: Registry.fence_put(node.name, 3, {"other.#{i}", :owned, 1, 0, 0})

      assert Atanor.Fence.held?(node.name, "held.cell")
      Await.until(fn -> not Atanor.Fence.held?(node.name, "held.cell") end, 5_000)
      assert Registry.fence_hold(node.name, "held.cell") == nil
    end

    test "reaching the bound of the verified table evicts a few entries, not all" do
      node = Node.start(routing: Fence.routing(owner_check_cells: 32))
      on_exit(fn -> Node.stop(node) end)
      ids = for i <- 1..33, do: "cell.#{i}"
      for id <- ids, do: Registry.put_verified(node.name, id, 32)

      # The 33rd entry meets a full table: a sixteenth of it goes (2), the other 30 stay.
      assert Enum.count(ids, &Registry.verified?(node.name, &1, 60_000)) >= 30
    end

    test "processes that insert past the bound at the same time do not crash" do
      node = Node.start(routing: Fence.routing(owner_check_cells: 64))
      on_exit(fn -> Node.stop(node) end)

      tasks =
        for p <- 1..8 do
          Task.async(fn -> for i <- 1..5_000, do: Registry.put_verified(node.name, "c#{rem(i * p, 300)}", 64) end)
        end

      assert Enum.all?(Task.await_many(tasks, 60_000), &is_list/1)
    end
  end

  describe "reading the lease ahead of the owner check" do
    test "one caller wins the right to read, once the last read is old enough" do
      node = Node.start(routing: Fence.routing(owner_check_ms: 400))
      on_exit(fn -> Node.stop(node) end)
      Registry.put_verified(node.name, "ahead.1", 32)

      refute Registry.claim_refresh(node.name, "ahead.1", 200, 400)
      Process.sleep(220)
      assert Registry.claim_refresh(node.name, "ahead.1", 200, 400)
      refute Registry.claim_refresh(node.name, "ahead.1", 200, 400)
      refute Registry.claim_refresh(node.name, "unknown.cell", 200, 400)

      # A claim that never ended (the reader died) is open again after the retry time.
      Process.sleep(420)
      assert Registry.claim_refresh(node.name, "ahead.1", 200, 400)
    end

    test "the mark is dated from the start of the read, not from its end" do
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      {:ok, _} = start_supervised({MemoryStore, name: name})
      store = SlowReads.wrap({MemoryStore, MemoryStore.config(name)})
      node = Node.start(store: store, workers: [Manifests.jobs("jobs")], routing: Fence.routing(owner_check_ms: 4_000))

      on_exit(fn ->
        Node.stop(node)
        :persistent_term.erase({SlowReads, :slow})
      end)

      {:ok, _} = Cell.query(node.name, {"jobs", "slow"}, "SELECT 1")
      {:ok, id} = Cell.id({"jobs", "slow"})
      config = Registry.config(node.name)

      Registry.put_verified(node.name, id, 32)
      Process.sleep(3_100)
      :persistent_term.put({SlowReads, :slow}, 600)
      assert :ok = Atanor.Fence.refresh_ahead(node.name, config, id)

      # The old mark is 3 s old; the new one appears when the read ends, dated 600 ms back.
      Await.until(fn -> Registry.verified?(node.name, id, 1_000) end, 5_000)
      refute Registry.verified?(node.name, id, 450)
    end

    test "a read in the background keeps the mark fresh for a busy cell" do
      node = Node.start(workers: [Manifests.jobs("jobs")], routing: Fence.routing(owner_check_ms: 400))
      on_exit(fn -> Node.stop(node) end)
      {:ok, _} = Cell.query(node.name, {"jobs", "busy"}, "SELECT 1")
      {:ok, id} = Cell.id({"jobs", "busy"})
      config = Registry.config(node.name)
      Registry.put_verified(node.name, id, 32)
      Process.sleep(320)

      assert :ok = Atanor.Fence.refresh_ahead(node.name, config, id)
      # The mark is younger than the pause: the lease was read and stored again.
      Await.until(fn -> Registry.verified?(node.name, id, 150) end, 5_000)
    end
  end
end
