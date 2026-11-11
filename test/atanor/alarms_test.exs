defmodule Atanor.AlarmsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Atanor.Test.Await

  alias Atanor.{Alarms, Cell, Env, Store}
  alias Atanor.Test.{AlarmWorker, Manifests}
  alias AlambiqueTestkit.{ManualClock, MemoryStore}
  alias AtanorTestkit.Node

  @start 1_000_000_000_000

  defp manifest(opts \\ []) do
    Manifests.probe(
      "clock",
      Keyword.merge(
        [
          module: AlarmWorker,
          alarms: true,
          cells: %{"clock" => AlarmWorker.migrations()},
          routes: [{"127.0.0.1", "/"}]
        ],
        opts
      )
    )
  end

  # A node whose alarm clock is a manual one; it ticks every 20 ms of real time.
  defp start(opts \\ []) do
    world = ManualClock.new(@start)
    alarms = Keyword.merge([clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 20], opts[:alarms] || [])
    node = Node.start(Keyword.merge([workers: [manifest()]], Keyword.put(opts, :alarms, alarms)))
    on_exit(fn -> Node.stop(node) end)
    Process.register(self(), :alarm_probe)
    {node, world}
  end

  defp set(node, key, at, payload) do
    query = URI.encode_query(key: key, at: at, payload: payload)
    assert Req.get!("#{node.url}/set?#{query}", retry: false).body == ":ok"
  end

  defp cancel(node, key), do: assert(Req.get!("#{node.url}/cancel?key=#{key}", retry: false).body == ":ok")

  defp rows(node, key) do
    {:ok, %{rows: rows}} =
      Cell.query(node.name, {"clock", key}, "SELECT worker, at_ms, payload, attempts FROM _atanor_alarms")

    rows
  end

  defp fires(node, key) do
    {:ok, %{rows: rows}} = Cell.query(node.name, {"clock", key}, "SELECT payload FROM fires ORDER BY id")
    List.flatten(rows)
  end

  defp index(node) do
    {:ok, keys, _} = Store.list(Store.handle(node.name), "alarms/")
    keys
  end

  defp scan_until_stopped(instance) do
    Alarms.run(instance, fn _ -> true end)

    receive do
      :stop -> :ok
    after
      0 -> scan_until_stopped(instance)
    end
  end

  defp index_empty?(node), do: index(node) == []

  # The timeout is real time and also covers the claim, so a loaded host can stop the
  # handler before it sends. Each stop is reported and its alarm is due again after
  # the lease: advance the clock past it until a handler reports a new start.
  defp await_slow(world, after_count) do
    receive do
      {:alarm, "a", "slow", count} when count > after_count ->
        count

      {:failed, %{reason: :timeout}} ->
        ManualClock.advance(world, 60_000)
        await_slow(world, after_count)
    after
      5_000 -> flunk("no slow handler started after #{after_count}")
    end
  end

  describe "an address that cannot be used" do
    test "set_alarm leaves no index entry" do
      {node, _world} = start()
      {:ok, d} = Atanor.Registry.deployment(node.name, "clock")
      env = Env.new(node.name, d)

      assert {:error, _} = Env.set_alarm(env, {"clock", "bad key"}, @start + 1_000, "x")
      assert index(node) == []
    end

    test "an entry that a failed set_alarm left behind expires" do
      {node, world} = start(alarms: [timeout_ms: 1_000])
      store = Store.handle(node.name)
      config = Atanor.Registry.config(node.name)
      :ok = Alarms.put_index(store, config, @start, "clock", "clock.bad key")
      assert [_] = index(node)

      ManualClock.advance(world, 3_600_000)
      Alarms.run(node.name, fn _ -> true end)
      assert until(fn -> index(node) == [] end)
    end
  end

  describe "firing" do
    test "a due alarm fires once with its payload and leaves nothing behind" do
      {node, world} = start()
      set(node, "a", @start + 60_000, "hello")
      assert [_] = index(node)
      assert [["clock", _, "hello", 0]] = rows(node, "a")

      refute_receive {:alarm, _, _, _}, 100
      ManualClock.advance(world, 60_000)
      assert_receive {:alarm, "a", "hello", 1}, 5_000

      assert until(fn -> rows(node, "a") == [] and index_empty?(node) end)
      ManualClock.advance(world, 600_000)
      refute_receive {:alarm, _, _, _}, 200
      assert fires(node, "a") == ["hello"]
    end

    test "alarms that are due when set survive a scan that runs while they are being set" do
      {node, _world} = start(alarms: [tick_ms: 3_600_000])
      {:ok, deployment} = Atanor.Registry.deployment(node.name, "clock")
      env = Env.new(node.name, deployment)
      keys = for n <- 1..60, do: "r#{n}"

      scanner = Task.async(fn -> scan_until_stopped(node.name) end)

      keys
      |> Task.async_stream(&Env.set_alarm(env, {"clock", &1}, @start - 1_000, "now"), max_concurrency: 60)
      |> Stream.run()

      send(scanner.pid, :stop)
      Task.await(scanner)

      # One more scan, as the next tick would do; nothing may be missing from the index.
      Alarms.run(node.name, fn _ -> true end)
      for key <- keys, do: assert(until(fn -> fires(node, key) == ["now"] end))
    end

    test "a scan pages through the index and fires every due alarm" do
      {node, _world} = start(alarms: [tick_ms: 3_600_000, page_size: 1, concurrency: 1])
      for key <- ["p1", "p2", "p3"], do: set(node, key, @start, "due")

      assert Alarms.run(node.name, fn _ -> true end) == 3
      for key <- ["p1", "p2", "p3"], do: assert(fires(node, key) == ["due"])
    end

    test "an alarm waits for its time even inside the current minute" do
      {node, world} = start()
      set(node, "a", @start + 30_000, "p")
      ManualClock.advance(world, 10_000)
      refute_receive {:alarm, _, _, _}, 200
      ManualClock.advance(world, 20_000)
      assert_receive {:alarm, "a", "p", 1}, 5_000
    end

    test "an alarm in the past fires on the next tick" do
      {node, _world} = start()
      set(node, "a", @start - 5_000, "late")
      assert_receive {:alarm, "a", "late", 1}, 5_000
    end

    test "wakes a hibernated cell" do
      {node, world} = start()
      set(node, "a", @start + 1_000, "wake")
      :ok = Cell.hibernate(node.name, {"clock", "a"})
      ManualClock.advance(world, 61_000)
      assert_receive {:alarm, "a", "wake", 1}, 5_000
      assert until(fn -> fires(node, "a") == ["wake"] end)
    end

    test "reports telemetry" do
      id = "alarm-#{System.unique_integer()}"
      test = self()

      :telemetry.attach(
        id,
        [:atanor, :alarm, :fired],
        fn _, measurements, meta, _ -> send(test, {:fired, measurements, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      {node, world} = start()
      set(node, "a", @start + 1_000, "t")
      ManualClock.advance(world, 1_000)
      assert_receive {:fired, %{duration: d}, %{worker: "clock", cell: "clock.a", attempt: 1}}, 5_000
      assert d > 0
    end

    test "a handler that sets a new alarm keeps it" do
      {node, world} = start()
      set(node, "a", @start + 1_000, "rearm")
      ManualClock.advance(world, 1_000)
      assert_receive {:alarm, "a", "rearm", 1}, 5_000
      assert until(fn -> match?([["clock", 10_000_000_000_000, "rearmed", 0]], rows(node, "a")) end)
      assert until(fn -> length(index(node)) == 1 end)
    end

    test "an alarm of a worker that is not deployed waits for it" do
      {node, world} = start()
      set(node, "a", @start + 1_000, "later")
      {:ok, _} = Node.undeploy(node, "clock")
      ManualClock.advance(world, 61_000)
      refute_receive {:alarm, _, _, _}, 300

      {:ok, _} = Node.deploy(node, manifest())
      assert_receive {:alarm, "a", "later", 1}, 5_000
    end
  end

  describe "cancel and reschedule" do
    test "a cancelled alarm does not fire" do
      {node, world} = start()
      set(node, "a", @start + 1_000, "x")
      cancel(node, "a")
      assert rows(node, "a") == []
      assert index_empty?(node)
      cancel(node, "never-set")

      ManualClock.advance(world, 61_000)
      refute_receive {:alarm, _, _, _}, 200
    end

    test "rescheduling replaces the alarm and its index entry" do
      {node, world} = start()
      set(node, "a", @start + 1_000, "old")
      set(node, "a", @start + 200_000, "new")
      assert [_] = index(node)

      ManualClock.advance(world, 61_000)
      refute_receive {:alarm, _, _, _}, 200
      ManualClock.advance(world, 200_000)
      assert_receive {:alarm, "a", "new", 1}, 5_000
    end

    test "stale index entries fire nothing and are deleted" do
      {node, world} = start()
      set(node, "a", @start + 200_000, "real")
      store = Store.handle(node.name)

      # A replaced time, a cancelled alarm and a cell that never had alarms.
      stale = [
        Alarms.index_key(@start + 1_000, "clock", "clock.a"),
        Alarms.index_key(@start + 1_000, "clock", "clock.gone"),
        Alarms.index_key(@start + 1_000, "clock", "clock.never")
      ]

      {:ok, _} = Cell.execute(node.name, {"clock", "gone"}, "CREATE TABLE IF NOT EXISTS fires (x)")
      for key <- stale, do: {:ok, _} = Store.put(store, key, "")
      assert length(index(node)) == 4

      ManualClock.advance(world, 61_000)
      assert until(fn -> length(index(node)) == 1 end)
      refute_receive {:alarm, _, _, _}, 200
      assert [["clock", _, "real", 0]] = rows(node, "a")
    end
  end

  describe "an alarm that is still being committed" do
    # `set_alarm` writes the index entry before the row, and a scan can come
    # in between: the cluster suite lost an alarm that way.
    test "its entry is kept until it is older than the timeout, then it is stale" do
      {node, world} = start()
      key = Alarms.index_key(@start + 1_000, "clock", "clock.late")
      {:ok, _} = Store.put(Store.handle(node.name), key, Integer.to_string(@start))
      ManualClock.advance(world, 2_000)

      assert Alarms.run(node.name, fn _shard -> true end) == 0
      assert index(node) == [key]

      ManualClock.advance(world, 30_000)
      assert until(fn -> index(node) == [] end)
    end
  end

  describe "failures" do
    test "a failing handler is retried with backoff until it succeeds" do
      {node, world} = start()
      set(node, "a", @start + 1_000, "flaky")
      ManualClock.advance(world, 1_000)
      assert_receive {:alarm, "a", "flaky", 1}, 5_000
      assert until(fn -> rows(node, "a") == [["clock", @start + 2_000, "flaky", 1]] end)

      refute_receive {:alarm, _, _, _}, 200
      ManualClock.advance(world, 1_000)
      assert_receive {:alarm, "a", "flaky", 2}, 5_000
      assert until(fn -> rows(node, "a") == [["clock", @start + 4_000, "flaky", 2]] end)

      ManualClock.advance(world, 2_000)
      assert_receive {:alarm, "a", "flaky", 3}, 5_000
      assert until(fn -> rows(node, "a") == [] and index_empty?(node) end)
    end

    test "gives up after max_attempts and reports it" do
      id = "alarm-failed-#{System.unique_integer()}"
      test = self()

      :telemetry.attach(
        id,
        [:atanor, :alarm, :failed],
        fn _, _, meta, _ -> send(test, {:failed, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      {node, world} = start(alarms: [max_attempts: 2])
      set(node, "a", @start + 1_000, "fail")
      ManualClock.advance(world, 1_000)
      assert_receive {:alarm, "a", "fail", 1}, 5_000
      assert_receive {:failed, %{reason: :boom, final: false, attempt: 1}}, 5_000
      ManualClock.advance(world, 1_000)
      assert_receive {:alarm, "a", "fail", 2}, 5_000
      assert_receive {:failed, %{reason: :boom, final: true, attempt: 2}}, 5_000

      assert until(fn -> rows(node, "a") == [] and index_empty?(node) end)
      ManualClock.advance(world, 600_000)
      refute_receive {:alarm, _, _, _}, 200
    end

    test "a handler that raises is retried and its error is logged" do
      {node, world} = start()

      log =
        capture_log(fn ->
          set(node, "a", @start + 1_000, "raise")
          ManualClock.advance(world, 1_000)
          assert_receive {:alarm, "a", "raise", 1}, 5_000
          assert until(fn -> match?([["clock", at, "raise", 1]] when at == @start + 2_000, rows(node, "a")) end)
        end)

      assert log =~ "secret internals"
    end

    test "a handler that outlives timeout_ms is stopped and tried again" do
      id = "alarm-timeout-#{System.unique_integer()}"
      test = self()

      :telemetry.attach(
        id,
        [:atanor, :alarm, :failed],
        fn _, _, meta, _ -> send(test, {:failed, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      {node, world} = start(alarms: [timeout_ms: 200])
      set(node, "a", @start + 1_000, "slow")
      ManualClock.advance(world, 1_000)
      first = await_slow(world, 0)

      # The claim moved the row past the timeout; the stopped handler was reported.
      assert_receive {:failed, %{reason: :timeout, final: false}}, 5_000
      assert [["clock", at, "slow", attempts]] = rows(node, "a")
      assert attempts >= 1 and at >= @start + 1_000 + 200
      ManualClock.advance(world, 60_000)
      assert await_slow(world, first) > first
    end
  end

  describe "schedulers" do
    test "concurrent scans over one store fire each alarm once" do
      {node, world} = start(alarms: [tick_ms: 3_600_000])
      keys = for n <- 1..20, do: "c#{n}"
      for key <- keys, do: set(node, key, @start + 1_000, "once")
      ManualClock.advance(world, 61_000)

      fired =
        1..3
        |> Enum.map(fn _ -> Task.async(fn -> Alarms.run(node.name, fn _ -> true end) end) end)
        |> Task.await_many(30_000)

      assert Enum.sum(fired) == 20
      for key <- keys, do: assert(fires(node, key) == ["once"])
      assert until(fn -> index_empty?(node) end)
    end

    test "rendezvous hashing splits shards among members and moves few when one leaves" do
      members = for _ <- 1..3, do: spawn(fn -> Process.sleep(:infinity) end)
      owners = for shard <- 0..63, do: Alarms.owner(members, shard)
      assert Enum.all?(members, &(&1 in owners))

      [gone | rest] = members
      moved = for shard <- 0..63, Enum.at(owners, shard) != Alarms.owner(rest, shard), do: shard
      assert Enum.all?(moved, &(Enum.at(owners, &1) == gone))
      for pid <- members, do: Process.exit(pid, :kill)
    end

    test "a scheduler leaves the shards another member of its group owns" do
      {node, world} = start()
      scheduler = Process.whereis(Module.concat(node.name, Alarms))
      prefix = Atanor.Registry.config(node.name).prefix
      other = spawn(fn -> Process.sleep(:infinity) end)
      :ok = :pg.join(Atanor.PG, Alarms.group(prefix), other)
      members = [scheduler, other]

      keys = for n <- 1..30, do: "c#{n}"
      mine = Enum.filter(keys, &(Alarms.owner(members, Alarms.shard("clock." <> &1)) == scheduler))
      theirs = keys -- mine
      assert mine != [] and theirs != []

      for key <- keys, do: set(node, key, @start + 1_000, "once")
      ManualClock.advance(world, 61_000)
      assert until(fn -> Enum.all?(mine, &(fires(node, &1) == ["once"])) end)
      for key <- theirs, do: refute_receive({:alarm, ^key, _, _}, 50)
      assert length(index(node)) == length(theirs)

      # The other member leaves: its shards pass to this scheduler.
      Process.exit(other, :kill)
      assert until(fn -> index_empty?(node) end)
      for key <- keys, do: assert(fires(node, key) == ["once"])
    end
  end

  describe "grants" do
    test "alarms and the cell namespace must be granted" do
      {node, _world} = start()
      {:ok, deployment} = Atanor.Registry.deployment(node.name, "clock")
      env = Env.new(node.name, deployment)
      assert {:error, {:not_granted, {:cell, "other"}}} = Env.set_alarm(env, {"other", "a"}, 1, "x")
      assert {:error, {:not_granted, {:cell, "other"}}} = Env.cancel_alarm(env, {"other", "a"})

      {:ok, plain} = Node.deploy(node, manifest(alarms: false))
      env = Env.new(node.name, plain)
      assert {:error, {:not_granted, :alarms}} = Env.set_alarm(env, {"clock", "a"}, 1, "x")
      assert {:error, {:not_granted, :alarms}} = Env.cancel_alarm(env, {"clock", "a"})
    end

    test "a manifest with alarms needs handle_alarm/3" do
      {node, _world} = start()

      assert {:error, {:missing_callback, Atanor.Test.ProbeWorker, {:handle_alarm, 3}}} =
               Node.deploy(node, Manifests.probe("probe", alarms: true))
    end
  end

  describe "shards" do
    test "a non-default count works end to end" do
      {node, _world} = start(alarms: [shards: 8, tick_ms: 3_600_000])
      set(node, "a", @start, "x")

      assert [key] = index(node)
      shard = key |> String.split("/") |> Enum.at(2) |> String.to_integer()
      assert shard in 0..7
      assert Alarms.run(node.name, fn _ -> true end) == 1
      assert fires(node, "a") == ["x"]
    end

    test "the first start records the count and a later start refuses another" do
      {_store_pid, node_opts} = external_store()

      {:ok, sup} =
        Supervisor.start_link([{Atanor, node_opts ++ [alarms: [shards: 8, tick_ms: 3_600_000]]}],
          strategy: :one_for_one
        )

      assert {:ok, "8", _, _} =
               Store.get(Atanor.Store.open(node_opts[:store], node_opts[:prefix]), "meta/alarms/shards")

      Supervisor.stop(sup)

      previous = Process.flag(:trap_exit, true)

      assert {:error, _} =
               Supervisor.start_link(
                 [{Atanor, node_opts ++ [alarms: [shards: 16, tick_ms: 3_600_000]]}],
                 strategy: :one_for_one
               )

      Process.flag(:trap_exit, previous)
      receive do: ({:EXIT, _, _} -> :ok), after: (0 -> :ok)
    end

    defp external_store do
      {:ok, pid} = MemoryStore.start_link()
      id = System.unique_integer([:positive])
      prefix = "shards#{id}"
      store = {MemoryStore, MemoryStore.config(pid)}

      opts = [
        name: Module.concat(__MODULE__, "S#{id}"),
        data_dir: Path.join(System.tmp_dir!(), "atanor-shards-#{id}"),
        store: store,
        prefix: prefix,
        port: 0
      ]

      on_exit(fn ->
        File.rm_rf!(opts[:data_dir])
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {pid, opts}
    end
  end
end
