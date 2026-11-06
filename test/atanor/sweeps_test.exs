defmodule Atanor.SweepsTest do
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias Atanor.{Cell, Registry, Store, Sweeps}
  alias Atanor.Test.Manifests
  alias AlambiqueTestkit.ManualClock
  alias AtanorTestkit.Node

  @start 1_000_000_000_000

  defp start(opts \\ []) do
    world = ManualClock.new(@start)

    sweeps =
      Keyword.merge(
        [
          poll_ms: 50,
          lease_ttl_ms: 2_000,
          renew_ms: 500,
          cell_timeout_ms: 1_000,
          page_size: 2,
          rate_per_s: 100,
          concurrency: 2,
          max_active: 2,
          cell_attempts: 1,
          retry_ms: 10
        ],
        opts[:sweeps] || []
      )

    alarms = [clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 20]
    node = Node.start(workers: [Manifests.jobs("jobs")], alarms: alarms, sweeps: sweeps, poll_interval_ms: 100)
    on_exit(fn -> Node.stop(node) end)
    {node, world}
  end

  defp wake(node, keys) do
    for key <- keys do
      {:ok, _} = Cell.query(node.name, {"jobs", key}, "SELECT 1")
    end
  end

  defp effects(node, keys) do
    for key <- keys do
      {:ok, %{rows: rows}} = Cell.query(node.name, {"jobs", key}, "SELECT payload FROM effects")
      {key, List.flatten(rows)}
    end
  end

  defp operation(node, attrs \\ %{}) do
    base = %{
      "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
      "action" => %{
        "worker" => "jobs",
        "kind" => "sweep",
        "payload_base64" => Base.encode64("swept")
      }
    }

    {:ok, op} = Sweeps.start(node.name, Map.merge(base, attrs))
    op
  end

  test "the records of operations are bounded by max_records" do
    {node, _world} = start(sweeps: [max_records: 3])
    for _ <- 1..3, do: operation(node)

    attrs = %{
      "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
      "action" => %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => ""}
    }

    assert {:error, :too_many_operations} = Sweeps.start(node.name, attrs)
  end

  test "a namespace operation enqueues one job per awake cell and records markers" do
    {node, _world} = start()
    wake(node, ~w(a b c))
    op = operation(node, %{"page_size" => 2, "concurrency" => 2})

    assert until(fn -> effects(node, ~w(a b c)) == [{"a", ["swept"]}, {"b", ["swept"]}, {"c", ["swept"]}] end)

    assert until(fn ->
             {:ok, record, _etag} = Sweeps.get(node.name, op["id"])
             record["state"] == "done" and record["counters"]["dispatched"] == 3
           end)

    for key <- ~w(a b c) do
      assert until(fn ->
               match?(
                 {:ok, %{rows: [["done"]]}},
                 Cell.query(node.name, {"jobs", key}, "SELECT state FROM _atanor_jobs WHERE operation_id = ?", [
                   op["id"]
                 ])
               )
             end)
    end

    assert %{sampled: 3, done: 3, failed: 0, missing: 0} = Sweeps.sample_outcomes(node.name, op["id"], 10)
  end

  test "an index cell selects the target keys" do
    {node, _world} = start()
    wake(node, ~w(a b c idx))

    {:ok, _} = Cell.execute(node.name, {"jobs", "idx"}, "CREATE TABLE mailboxes (key TEXT PRIMARY KEY)")

    for key <- ~w(a c),
        do: {:ok, _} = Cell.execute(node.name, {"jobs", "idx"}, "INSERT INTO mailboxes (key) VALUES (?)", [key])

    op =
      operation(node, %{
        "selector" => %{
          "kind" => "index",
          "cell" => %{"namespace" => "jobs", "key" => "idx"},
          "namespace" => "jobs",
          "sql" => "SELECT key FROM mailboxes WHERE key > ? ORDER BY key LIMIT ?"
        }
      })

    assert until(fn -> effects(node, ~w(a b c)) == [{"a", ["swept"]}, {"b", []}, {"c", ["swept"]}] end)
    assert until(fn -> match?({:ok, %{"state" => "done"}, _}, Sweeps.get(node.name, op["id"])) end)
  end

  test "pause stops dispatch and resume continues from the cursor" do
    {node, _world} = start(sweeps: [rate_per_s: 1, concurrency: 1, page_size: 1])
    wake(node, ~w(a b c))
    op = operation(node)

    assert until(fn -> match?({:ok, %{"state" => "running"}, _}, Sweeps.get(node.name, op["id"])) end)
    assert {:ok, paused} = Sweeps.pause(node.name, op["id"])
    assert paused["state"] == "paused"

    # Whatever was already dispatched stays; no new page should start after
    # the driver sees the pause.
    Process.sleep(300)
    {:ok, first, _} = Sweeps.get(node.name, op["id"])
    assert first["state"] == "paused"
    assert {:ok, _} = Sweeps.resume(node.name, op["id"])

    assert until(fn -> Enum.all?(effects(node, ~w(a b c)), fn {_, list} -> list == ["swept"] end) end)
    assert until(fn -> match?({:ok, %{"state" => "done"}, _}, Sweeps.get(node.name, op["id"])) end)
  end

  test "the manager does not read a finished operation again" do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, _} = start_supervised({AlambiqueTestkit.MemoryStore, name: name})

    store =
      Atanor.Test.CountingStore.wrap(
        {AlambiqueTestkit.MemoryStore, AlambiqueTestkit.MemoryStore.config(name)},
        "operations/"
      )

    world = ManualClock.new(@start)
    alarms = [clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 20]
    sweeps = [poll_ms: 30, lease_ttl_ms: 2_000, renew_ms: 500, cell_timeout_ms: 1_000, rate_per_s: 100, retry_ms: 10]
    node = Node.start(store: store, workers: [Manifests.jobs("jobs")], alarms: alarms, sweeps: sweeps)
    on_exit(fn -> Node.stop(node) end)
    wake(node, ~w(a b))

    op = operation(node)
    assert until(fn -> match?({:ok, %{"state" => "done"}, _}, Sweeps.get(node.name, op["id"])) end)

    # The manager reads the finished record once more, keeps it, and then only lists.
    Process.sleep(200)
    reads = Atanor.Test.CountingStore.reads(store)
    Process.sleep(400)
    assert Atanor.Test.CountingStore.reads(store) == reads
  end

  test "the manager reads a finished operation again after reread_ms" do
    {node, _world} = start(sweeps: [reread_ms: 100])
    wake(node, ~w(a))
    op = operation(node)
    assert until(fn -> match?({:ok, %{"state" => "done"}, _}, Sweeps.get(node.name, op["id"])) end)

    # Let the manager keep the done record, then age it in the store: retention removes it.
    Process.sleep(300)
    {:ok, stored, etag} = Sweeps.get(node.name, op["id"])
    old = Jason.encode!(%{stored | "updated_at_ms" => 0})
    assert {:ok, _} = Store.put(node.name, "operations/" <> op["id"], old, {:if_match, etag})
    assert until(fn -> match?({:error, :not_found}, Store.get(node.name, "operations/" <> op["id"])) end)
  end

  test "an operation runs with reread_ms 1" do
    {node, _world} = start(sweeps: [reread_ms: 1])
    wake(node, ~w(a))
    op = operation(node)
    assert until(fn -> match?({:ok, %{"state" => "done"}, _}, Sweeps.get(node.name, op["id"])) end)

    # The next poll caches the finished record; a second operation must still start.
    op = operation(node)
    assert until(fn -> match?({:ok, %{"state" => "done"}, _}, Sweeps.get(node.name, op["id"])) end)
  end

  test "cancel stops a running operation" do
    {node, _world} = start(sweeps: [rate_per_s: 1, concurrency: 1, page_size: 1])
    wake(node, for(i <- 1..20, do: "c#{i}"))

    op = operation(node)

    # One cell per second: the operation cannot be done before cancel.
    assert {:ok, cancelled} = Sweeps.cancel(node.name, op["id"])
    assert cancelled["state"] == "cancelled"
    assert until(fn -> match?({:ok, %{"state" => "cancelled"}, _}, Sweeps.get(node.name, op["id"])) end)
  end

  test "run mode enqueues due now and wakes the cell" do
    {node, _world} = start()
    wake(node, ~w(a b))

    op =
      operation(node, %{
        "action" => %{
          "mode" => "run",
          "worker" => "jobs",
          "kind" => "sweep",
          "payload_base64" => Base.encode64("run")
        }
      })

    assert until(fn -> effects(node, ~w(a b)) == [{"a", ["run"]}, {"b", ["run"]}] end)
    assert until(fn -> match?({:ok, %{"state" => "done"}, _}, Sweeps.get(node.name, op["id"])) end)
  end

  test "a control that loses the compare-and-swap to another write is retried" do
    # No driver runs (long poll), so the only write is the control's own; the store refuses the first as a lost race.
    {node, _world} = start(sweeps: [poll_ms: 3_600_000, control_attempts: 2])
    wake(node, ~w(a))

    op = operation(node)
    {_, config} = node.store

    fault =
      AlambiqueTestkit.MemoryStore.inject(config,
        kind: :error,
        reason: :precondition_failed,
        ops: [:put],
        key: ~r/operations\//,
        times: 1
      )

    assert {:ok, %{"state" => "paused"}} = Sweeps.pause(node.name, op["id"])
    AlambiqueTestkit.MemoryStore.remove(config, fault)

    # With one attempt left the race is reported.
    AlambiqueTestkit.MemoryStore.inject(config,
      kind: :error,
      reason: :precondition_failed,
      ops: [:put],
      key: ~r/operations\//,
      times: 2
    )

    assert {:error, :precondition_failed} = Sweeps.resume(node.name, op["id"])
  end

  test "the action worker must be granted jobs and the namespace of the selector" do
    {node, _world} = start()
    {:ok, _} = Node.deploy(node, Manifests.probe("plain", cells: %{"other" => []}, routes: [{"127.0.0.1", "/plain"}]))

    action = fn worker -> %{"worker" => worker, "kind" => "sweep", "payload_base64" => Base.encode64("x")} end
    namespace = fn ns -> %{"kind" => "namespace", "namespace" => ns} end

    for {selector, worker} <- [
          {namespace.("other"), "jobs"},
          {namespace.("jobs"), "plain"},
          {%{"kind" => "prefix", "prefix" => "other.a"}, "jobs"},
          {%{
             "kind" => "index",
             "cell" => %{"namespace" => "other", "key" => "i"},
             "namespace" => "jobs",
             "sql" => "SELECT 1"
           }, "jobs"}
        ] do
      assert_raise ArgumentError, ~r/not granted/, fn ->
        Sweeps.start(node.name, %{"selector" => selector, "action" => action.(worker)})
      end
    end

    assert {:ok, _} =
             Sweeps.start(node.name, %{
               "selector" => %{"kind" => "prefix", "prefix" => "jobs.a"},
               "action" => action.("jobs")
             })
  end

  test "operation values above the instance bounds are refused" do
    {node, _world} = start()
    assert_raise ArgumentError, fn -> operation(node, %{"rate_per_s" => 1_000_000}) end
    assert_raise ArgumentError, fn -> operation(node, %{"concurrency" => 1_000}) end
  end

  test "a malformed operation is refused and says what is wrong" do
    {node, _world} = start()
    action = %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("x")}
    ns = %{"kind" => "namespace", "namespace" => "jobs"}
    start = fn attrs -> Sweeps.start(node.name, Map.merge(%{"selector" => ns, "action" => action}, attrs)) end

    for {attrs, message} <- [
          {%{"page_size" => 3}, ~r/page_size must not exceed/},
          {%{"rate_per_s" => 0}, ~r/rate_per_s must be a positive integer, got: 0/},
          {%{"concurrency" => "2"}, ~r/concurrency must be a positive integer/},
          {%{"undo" => "yes"}, ~r/undo must be a boolean/},
          {%{"selector" => %{"kind" => "prefix", "prefix" => ""}}, ~r/invalid selector/},
          {%{"selector" => "jobs"}, ~r/invalid selector/},
          {%{"action" => "run"}, ~r/invalid action: "run"/},
          {%{"action" => %{action | "worker" => "Bad Worker"}}, ~r/invalid action worker/},
          {%{"action" => %{action | "kind" => ""}}, ~r/invalid action kind/},
          {%{"action" => Map.put(action, "mode", "sometimes")}, ~r/invalid action mode/},
          {%{"action" => %{action | "payload_base64" => Base.encode64(:binary.copy("x", 2_000_000))}},
           ~r/payload is too large/},
          {%{"selector" => %{"kind" => "namespace", "namespace" => "nobody"}}, ~r/not granted by an active worker/}
        ] do
      assert_raise ArgumentError, message, fn -> start.(attrs) end
    end

    assert {:ok, %{"page_size" => 2, "undo" => %{"enabled" => true}}} = start.(%{"undo" => true})
  end

  test "a driver's lease is released on a normal stop so another node can resume" do
    {node, _world} = start()
    wake(node, ~w(a b c))
    op = operation(node, %{"rate_per_s" => 10})
    assert until(fn -> match?({:ok, %{"state" => "done"}, _}, Sweeps.get(node.name, op["id"])) end)

    {:ok, record, _} = Sweeps.get(node.name, op["id"])
    assert record["driver"] == nil
    assert record["lease_until_ms"] == 0
    assert Registry.config(node.name).sweeps.max_active == 2
  end

  describe "canary and guard" do
    @failing %{
      "action" => %{
        "worker" => "jobs",
        "kind" => "sweep",
        "payload_base64" => Base.encode64("fail"),
        "max_attempts" => 1
      }
    }

    defp record(node, op), do: elem(Sweeps.get(node.name, op["id"]), 1)
    defp state?(node, op, state), do: record(node, op)["state"] == state

    test "an auto canary passes after its window and the operation finishes" do
      {node, _world} = start()
      keys = for i <- 1..6, do: "c#{i}"
      wake(node, keys)
      op = operation(node, %{"canary_size" => 3, "canary_window_ms" => 50, "guard_poll_ms" => 10})

      assert until(fn -> state?(node, op, "done") end)
      assert %{"canary" => %{"passed" => true, "dispatched" => 3}} = record(node, op)
      assert until(fn -> Enum.all?(effects(node, keys), fn {_, list} -> list == ["swept"] end) end)
    end

    test "an auto canary that fails halts before the rest is dispatched" do
      {node, _world} = start()
      keys = for i <- 1..6, do: "c#{i}"
      wake(node, keys)

      op =
        operation(
          node,
          Map.merge(@failing, %{
            "canary_size" => 3,
            "canary_window_ms" => 50,
            "guard_poll_ms" => 10,
            "guard_min_cells" => 3
          })
        )

      assert until(fn -> state?(node, op, "halted") end)
      halted = record(node, op)
      assert halted["halt_reason"] == "error_rate"
      assert halted["canary"]["passed"] == false
      assert halted["counters"]["dispatched"] == 3
      assert halted["guard"]["failed"] == 3
      assert halted["driver"] == nil
    end

    test "a pause gate waits for confirmation and continue resumes at the cursor" do
      {node, _world} = start()
      keys = ~w(a b c d e)
      wake(node, keys)
      op = operation(node, %{"canary_size" => 2, "canary_gate" => "pause"})

      assert until(fn -> state?(node, op, "awaiting_confirmation") end)
      waiting = record(node, op)
      assert waiting["driver"] == nil and waiting["lease_until_ms"] == 0
      assert waiting["counters"]["dispatched"] == 2
      assert {:error, :invalid_state} = Sweeps.pause(node.name, op["id"])

      assert {:ok, %{"state" => "running", "canary" => %{"passed" => true}}} = Sweeps.continue(node.name, op["id"])
      assert until(fn -> state?(node, op, "done") end)
      assert until(fn -> Enum.all?(effects(node, keys), fn {_, list} -> list == ["swept"] end) end)
      assert {:error, :invalid_state} = Sweeps.continue(node.name, op["id"])
    end

    test "a canary smaller than a page keeps the rest of the page" do
      {node, _world} = start(sweeps: [page_size: 4])
      keys = ~w(a b c d e)
      wake(node, keys)
      op = operation(node, %{"canary_size" => 1, "canary_gate" => "pause", "page_size" => 4})

      assert until(fn -> state?(node, op, "awaiting_confirmation") end)
      assert %{"cursor" => "jobs.a", "counters" => %{"dispatched" => 1}} = record(node, op)

      assert {:ok, _} = Sweeps.continue(node.name, op["id"])
      assert until(fn -> state?(node, op, "done") end)
      assert until(fn -> Enum.all?(effects(node, keys), fn {_, list} -> list == ["swept"] end) end)
      assert record(node, op)["counters"]["dispatched"] == 5
    end

    test "the guard halts an operation whose recent jobs fail" do
      {node, _world} = start(sweeps: [rate_per_s: 20])
      keys = for i <- 10..39, do: "c#{i}"
      wake(node, keys)

      op =
        operation(
          node,
          Map.merge(@failing, %{
            "canary_size" => 0,
            "guard_poll_ms" => 1,
            "guard_min_cells" => 2,
            "guard_window_cells" => 4
          })
        )

      assert until(fn -> state?(node, op, "halted") end)
      halted = record(node, op)
      assert halted["halt_reason"] == "error_rate"
      assert halted["counters"]["dispatched"] < length(keys)
      assert halted["guard"]["rate"] > 0.1
      assert length(halted["recent"]) <= 4
    end

    test "resume clears the window, keeps the canary and continues" do
      {node, _world} = start()
      keys = for i <- 1..8, do: "c#{i}"
      wake(node, keys)

      op =
        operation(
          node,
          Map.merge(@failing, %{
            "canary_size" => 2,
            "canary_window_ms" => 50,
            "guard_poll_ms" => 10,
            "guard_min_cells" => 2
          })
        )

      assert until(fn -> state?(node, op, "halted") end)
      assert {:ok, resumed} = Sweeps.resume(node.name, op["id"])
      assert resumed["recent"] == [] and resumed["halt_reason"] == nil
      assert resumed["canary"]["passed"] == true
      assert until(fn -> record(node, op)["counters"]["dispatched"] > 2 end)
    end

    test "repeated sampling failures halt with guard_unavailable" do
      {node, _world} = start()
      wake(node, ~w(a b c))
      op = operation(node, %{"canary_size" => 0, "guard_poll_ms" => 1, "guard_attempts" => 2, "rate_per_s" => 1})
      assert {:ok, _} = Sweeps.pause(node.name, op["id"])
      assert until(fn -> record(node, op)["driver"] == nil end)

      # A window cell that cannot be read makes every sample fail.
      {:ok, stored, etag} = Sweeps.get(node.name, op["id"])
      stored = Map.put(stored, "recent", ["jobs.a", "no such cell"])

      assert {:ok, _} =
               Store.put(Store.handle(node.name), "operations/" <> op["id"], Jason.encode!(stored), {:if_match, etag})

      assert {:ok, _} = Sweeps.resume(node.name, op["id"])

      assert until(fn -> state?(node, op, "halted") end)
      assert %{"halt_reason" => "guard_unavailable", "guard" => %{"failures" => 2}} = record(node, op)
    end

    test "invalid canary and guard options are refused" do
      {node, _world} = start()

      for attrs <- [
            %{"canary_size" => -1},
            %{"canary_gate" => "later"},
            %{"canary_window_ms" => 0},
            %{"canary_window_ms" => 10_000, "canary_timeout_ms" => 1_000},
            %{"guard_error_rate" => 0},
            %{"guard_error_rate" => 1.5},
            %{"guard_min_cells" => 100},
            %{"guard_attempts" => "3"}
          ] do
        assert_raise ArgumentError, fn -> operation(node, attrs) end
      end
    end

    test "sample_outcomes reads named cells without waking them" do
      {node, _world} = start()
      wake(node, ~w(a b))
      op = operation(node, %{"canary_size" => 0})
      assert until(fn -> state?(node, op, "done") end)

      cells = ["jobs.a", "jobs.b", "jobs.never"]

      assert until(fn ->
               match?(%{done: 2}, Sweeps.sample_outcomes(node.name, op["id"], 10, cells: cells, at: :latest))
             end)

      assert %{sampled: 3, done: 2, failed: 0, pending: 0} =
               Sweeps.sample_outcomes(node.name, op["id"], 10, cells: cells, at: :latest)
    end
  end
end
