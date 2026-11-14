defmodule Atanor.QueueDeadlineTest do
  @moduledoc """
  A request waits at most `http: [queue_wait_ms:]` for its handler, its cell owner and its cell calls; after
  that it is a 503 `queue_timeout` (design §7.1). A call that may have been applied is never reported as
  refused.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.{Admission, Cell, Config}
  alias Atanor.Test.{Await, Manifests}
  alias AlambiqueTestkit.MemoryStore
  alias AtanorTestkit.Node

  @cells %{"notes" => Manifests.notes_migrations()}
  @wait_ms 200

  defp start(opts \\ []) do
    workers = [Manifests.probe("w", cells: @cells, routes: [{"127.0.0.1", "/"}])]
    node = Node.start(Keyword.merge([workers: workers, http: [queue_wait_ms: @wait_ms]], opts))
    on_exit(fn -> Node.stop(node) end)
    node
  end

  # A latency on every store request of the cell `key`.
  defp slow(node, key, ms, ops \\ [:get, :get_range, :head, :list, :put]) do
    {MemoryStore, store} = node.store
    fault = MemoryStore.inject(store, kind: :latency, ms: ms, key: ~r{/cells/cells/notes\.#{key}/}, ops: ops)
    on_exit(fn -> MemoryStore.clear(store) end)
    fn -> MemoryStore.remove(store, fault) end
  end

  defp get(node, path), do: timed(fn -> Req.get!(node.url <> path, retry: false, receive_timeout: 20_000) end)

  defp post(node, path, body),
    do: timed(fn -> Req.post!(node.url <> path, body: body, retry: false, receive_timeout: 20_000) end)

  defp timed(fun) do
    {us, response} = :timer.tc(fun)
    {response, div(us, 1000)}
  end

  describe "the wake of a cell" do
    test "a request whose cell wakes slowly is a 503 queue_timeout at the deadline, not a late 200" do
      node = start()
      unslow = slow(node, "wake", 1_500)
      test = self()

      :telemetry.attach(
        "qd-#{inspect(self())}",
        [:atanor, :http, :reject],
        fn _, _, meta, _ -> send(test, {:reject, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("qd-#{inspect(self())}") end)

      {response, ms} = get(node, "/keyed/wake")

      assert response.status == 503
      assert %{"error" => "overloaded", "reason" => "queue_timeout"} = response.body
      assert response.headers["retry-after"] == ["1"]
      assert ms < 1_000, "answered after #{ms} ms"
      assert_receive {:reject, %{reason: :queue_timeout, status: 503}}
      assert %{refused: %{queue_timeout: 1}} = Admission.stats(node.name)

      unslow.()
      Await.until(fn -> Req.get!(node.url <> "/keyed/wake", retry: false).status == 200 end)
    end

    test "queue_wait_ms 0 or :infinity turns the deadline off" do
      for off <- [0, :infinity] do
        node = start(http: [queue_wait_ms: off])
        slow(node, "wake", 600)
        {response, ms} = get(node, "/keyed/wake")
        assert response.status == 200
        assert ms >= 500
        assert %{refused: %{queue_timeout: 0}} = Admission.stats(node.name)
      end
    end

    test "the time a client takes to send the body does not count" do
      node = start()
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", node.port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "POST /echo HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 2\r\n\r\nx")
      Process.sleep(@wait_ms * 2)
      :ok = :gen_tcp.send(socket, "y")
      assert {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.close(socket)
    end
  end

  describe "the cell calls of a handler" do
    test "a read that waits past the deadline is a 503 queue_timeout" do
      node = start()
      slow(node, "r1", 1_500)
      {response, ms} = get(node, "/read?key=r1")

      assert response.status == 503
      assert %{"error" => "overloaded", "reason" => "queue_timeout"} = response.body
      assert ms < 1_000
    end

    test "a write that waits past the deadline is an unknown outcome, never a queue_timeout, and it may commit" do
      node = start(http: [queue_wait_ms: 1_000])
      # An awake cell, so that only the commit waits.
      assert {:ok, _} = Cell.query(node.name, {"notes", "w1"}, "SELECT 1")
      unslow = slow(node, "w1", 2_500, [:put])
      {response, ms} = post(node, "/write?key=w1", "late")

      assert response.status == 503
      assert %{"error" => "unknown_outcome"} = response.body
      assert ms < 2_000

      unslow.()

      Await.until(fn ->
        match?({:ok, %{rows: [["late"]]}}, Cell.query(node.name, {"notes", "w1"}, "SELECT body FROM notes"))
      end)
    end

    # The property that makes the 503 safe to retry: whatever the latency, a request answered queue_timeout
    # left nothing in the cell, and one answered 200 left its row.
    property "a queue_timeout never matches a committed write" do
      node = start()
      ops = [[:get, :get_range, :head, :list], [:put], [:get, :get_range, :head, :list, :put]]

      check all(latency <- member_of([0, 120, 400, 700]), ops <- member_of(ops), max_runs: 12) do
        key = "p#{System.unique_integer([:positive])}"
        unslow = slow(node, key, latency, ops)
        {response, _ms} = post(node, "/write?key=#{key}", "v")
        unslow.()
        Process.sleep(latency + 700)

        {:ok, %{rows: rows}} = Cell.query(node.name, {"notes", key}, "SELECT body FROM notes")

        case {response.status, response.body} do
          {200, _} -> assert rows == [["v"]]
          {503, %{"reason" => "queue_timeout"}} -> assert rows == [], "refused as queue_timeout but committed"
          {503, %{"error" => "unknown_outcome"}} -> assert rows in [[], [["v"]]]
        end
      end
    end

    test "a handler that wrote is not refused afterwards, and a request that has not is" do
      node = start()
      key = {"notes", "committed"}
      # Awake, so that the deadline is not spent on the wake.
      assert {:ok, _} = Cell.query(node.name, key, "SELECT 1")
      assert :ok = Admission.enter(node.name)
      on_exit(fn -> Admission.leave(node.name) end)

      assert {:ok, _} = Cell.execute(node.name, key, "INSERT INTO notes (body) VALUES ('a')")
      Process.sleep(@wait_ms + 50)
      assert Admission.expired?()
      assert {:ok, %{rows: [["a"]]}} = Cell.query(node.name, key, "SELECT body FROM notes")

      Cell.clear_unknown()
      Cell.clear_unavailable()
      assert {:error, {:unavailable, :overloaded}} = Cell.query(node.name, key, "SELECT body FROM notes")
      assert Cell.overload_cause() == :queue_timeout
    end
  end

  describe "the process of a cell call" do
    # What a transaction callback sees, and whether the caller itself calls Alambique, with the cell
    # cold and then warm. The callback runs in the cell process; the call is made from the process of the caller.
    defp callback_view(node, key) do
      Process.put(:handler_key, :set)
      parent = self()
      # A tracer is never traced itself, so another process collects the calls.
      tracer = spawn_link(fn -> collect([]) end)
      :erlang.trace_pattern({Alambique.Router, :call, 5}, true, [:local])
      :erlang.trace(parent, true, [:call, {:tracer, tracer}])

      assert {:ok, view} =
               Cell.transaction(node.name, {"notes", key}, fn _tx -> {Process.get(:handler_key), self() == parent} end)

      :erlang.trace(parent, false, [:call])
      :erlang.trace_pattern({Alambique.Router, :call, 5}, false, [:local])
      send(tracer, {:done, parent})
      assert_receive {:calls, calls}
      {view, calls != []}
    end

    defp collect(acc) do
      receive do
        {:trace, _, :call, mfa} -> collect([mfa | acc])
        {:done, to} -> send(to, {:calls, acc})
      end
    end

    test "a cell call runs in the process of the handler with the cell cold and warm" do
      node = start(http: [queue_wait_ms: 5_000])
      assert :ok = Admission.enter(node.name)
      on_exit(fn -> Admission.leave(node.name) end)
      cold = callback_view(node, "cold")
      assert {_view, true} = cold
      assert callback_view(node, "cold") == cold
    end

    test "a write that finds the cell still waking is not sent: queue_timeout, never committed" do
      node = start()
      unslow = slow(node, "twice", 1_500)
      alambique = Atanor.Registry.config(node.name).alambique
      insert = fn -> Cell.execute(node.name, {"notes", "twice"}, "INSERT INTO notes (body) VALUES ('x')") end

      call = fn ->
        assert :ok = Admission.enter(node.name)
        result = {insert.(), Cell.unknown_outcome?(), Cell.overload_cause()}
        Admission.leave(node.name)
        result
      end

      # The first request leaves the wake behind its deadline; the cell keeps waking.
      assert {{:error, {:unavailable, :overloaded}}, false, :queue_timeout} = Task.await(Task.async(call))
      # The cell gets its process before the wake ends: a call finds it and may queue behind the wake.
      Await.until(fn -> match?({:ok, _}, Alambique.load(alambique, "notes.twice")) end)

      {result, ms} = timed(fn -> Task.await(Task.async(call)) end)
      assert {{:error, {:unavailable, :overloaded}}, false, :queue_timeout} = result
      assert ms < 1_000

      unslow.()
      Process.sleep(1_800)
      assert {:ok, %{rows: []}} = Cell.query(node.name, {"notes", "twice"}, "SELECT body FROM notes")
    end

    test "a write to an awake cell goes straight to the bounded call, without a touch" do
      node = start(http: [queue_wait_ms: 5_000])
      alambique = Atanor.Registry.config(node.name).alambique
      # A write marks its process as committed, which lifts the deadline: warm the cell in another process.
      warm = fn -> Cell.execute(node.name, {"notes", "warm"}, "INSERT INTO notes (body) VALUES ('a')") end
      assert {:ok, _} = Task.await(Task.async(warm))
      assert {:ok, %{waking: false}} = Alambique.load(alambique, "notes.warm")
      assert :ok = Admission.enter(node.name)
      on_exit(fn -> Admission.leave(node.name) end)

      # A tracer is never traced itself, so another process collects the calls.
      parent = self()
      tracer = spawn_link(fn -> collect([]) end)
      :erlang.trace_pattern({Alambique, :touch, 3}, true, [:local])
      :erlang.trace(parent, true, [:call, {:tracer, tracer}])
      assert {:ok, _} = Cell.execute(node.name, {"notes", "warm"}, "INSERT INTO notes (body) VALUES ('b')")
      :erlang.trace(parent, false, [:call])
      :erlang.trace_pattern({Alambique, :touch, 3}, false, [:local])
      send(tracer, {:done, parent})
      assert_receive {:calls, []}
    end

    test "a write whose cell wakes past the deadline is a queue_timeout and is never committed" do
      node = start()
      unslow = slow(node, "slowwake", 1_500, [:get, :get_range, :head, :list])
      assert :ok = Admission.enter(node.name)
      on_exit(fn -> Admission.leave(node.name) end)

      {result, ms} =
        timed(fn -> Cell.execute(node.name, {"notes", "slowwake"}, "INSERT INTO notes (body) VALUES ('x')") end)

      assert result == {:error, {:unavailable, :overloaded}}
      assert Cell.overload_cause() == :queue_timeout
      refute Cell.unknown_outcome?()
      assert ms < 1_000
      unslow.()
      Process.sleep(1_800)
      Admission.leave(node.name)
      assert {:ok, %{rows: []}} = Cell.query(node.name, {"notes", "slowwake"}, "SELECT body FROM notes")
    end
  end

  describe "the setting" do
    test "defaults to 5 s and takes 0 or :infinity as off" do
      assert Config.build(store: {AlambiqueTestkit.MemoryStore, %{}}, data_dir: "/tmp/x").http.queue_wait_ms == 5_000

      assert Config.build(store: {AlambiqueTestkit.MemoryStore, %{}}, data_dir: "/tmp/x", http: [queue_wait_ms: 0]).http.queue_wait_ms ==
               :infinity

      assert Config.build(store: {AlambiqueTestkit.MemoryStore, %{}}, data_dir: "/tmp/x", http: [queue_wait_ms: 900]).http.queue_wait_ms ==
               900

      for bad <- [-1, 1.5, "5"] do
        assert_raise ArgumentError, ~r/queue_wait_ms/, fn ->
          Config.build(store: {AlambiqueTestkit.MemoryStore, %{}}, data_dir: "/tmp/x", http: [queue_wait_ms: bad])
        end
      end
    end
  end
end
