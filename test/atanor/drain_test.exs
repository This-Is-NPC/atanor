defmodule Atanor.DrainTest do
  @moduledoc "The drain of one node and the 503s around it (design §8.11, §8.4)."
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias Atanor.{CLI, Config, Overview, Registry}
  alias Atanor.Test.Manifests
  alias AlambiqueTestkit.{GatedStore, ManualClock, MemoryStore}
  alias AtanorTestkit.Node

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @operator "operator-secret"
  @cell_id "log.a"

  defp start(opts \\ []) do
    stop = Keyword.merge([exit: false], Keyword.get(opts, :stop, []))
    node = Node.start([workers: [Manifests.counter("counter")]] ++ Keyword.put(opts, :stop, stop))
    on_exit(fn -> Node.stop(node) end)
    node
  end

  # A node whose uploads to the cell `log.a` wait until the test opens the gate, so its hibernation never ends.
  defp stuck(opts) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, _} = start_supervised({MemoryStore, name: name})
    gate = start_supervised!(GatedStore)
    node = start([store: GatedStore.wrap(gate, {MemoryStore, MemoryStore.config(name)})] ++ opts)
    assert post(node, "/c/a", "1").status == 200
    GatedStore.hold(gate, ~r{log\.a})
    {node, gate}
  end

  defp get(node, path), do: Req.get!(node.url <> path, retry: false)
  defp post(node, path, body), do: Req.post!(node.url <> path, body: body, retry: false)

  defp lease(node), do: elem(Alambique.lease(Registry.config(node.name).alambique, @cell_id), 1)

  defp attach(events) do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach_many(
      handler,
      events,
      fn event, measures, meta, _ -> send(parent, {event, measures, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "Atanor.drain/2" do
    test "reports draining, hands the cells back, refuses new wakes and calls the exit" do
      node = start(admin: [token: @operator, port: 0])
      attach([[:atanor, :node, :drain, :start], [:atanor, :node, :drain]])
      assert post(node, "/c/a", "1").status == 200
      assert %{owner: owner, released: false} = lease(node)
      assert owner == node()

      parent = self()
      assert {:ok, status} = Atanor.drain(node.name, exit: &send(parent, {:exit, &1}))

      assert %{state: :drained, hibernated: 1, errors: []} = status
      assert_receive {:exit, 0}
      assert %{released: true} = lease(node)

      # The admin listener keeps serving: the balancer is told to stop.
      admin = "http://127.0.0.1:#{Atanor.admin_port(node.name)}"
      headers = [authorization: "Bearer " <> @operator]

      assert %{status: 503, body: %{"status" => "draining"}} =
               Req.get!(admin <> "/health/ready", headers: headers, retry: false)

      assert %{status: 503, body: %{"status" => "draining"}} =
               Req.get!(admin <> "/health/serving", headers: headers, retry: false)

      assert %{status: 200, body: %{"status" => "draining"}} =
               Req.get!(admin <> "/health", headers: headers, retry: false)

      # The cell is not woken again here, and the client is told why.
      for path <- ["/c/a", "/r/a?ms=60000"] do
        resp = get(node, path)
        assert resp.status == 503
        assert resp.body == %{"error" => "unavailable", "reason" => "draining"}
        assert resp.headers["retry-after"] == ["1"]
      end

      assert_received {[:atanor, :node, :drain, :start], %{system_time: _}, %{trigger: :api, node: _}}
      assert_received {[:atanor, :node, :drain], %{hibernated: 1, errors: 0, duration: _}, %{trigger: :api}}
      assert {:ok, ^status} = Atanor.drain(node.name, exit: false)
    end

    test "a second call joins the drain that ran, and the status says what it did" do
      node = start()
      assert %{state: :idle} = Atanor.drain_status(node.name)
      assert {:ok, %{state: :drained} = status} = Atanor.drain(node.name)
      assert Atanor.drain_status(node.name) == status
      assert %{status: "draining"} = Overview.health(node.name)
      assert {503, %{status: "draining"}} = Overview.ready(node.name)
    end

    test "the alarm scheduler leaves its group, so the other nodes take the shards" do
      node = start(alarms: [tick_ms: 20])
      group = Atanor.Alarms.group(Registry.config(node.name).prefix)
      scheduler = Process.whereis(Module.concat(node.name, Atanor.Alarms))
      assert scheduler in :pg.get_members(Atanor.PG, group)

      assert {:ok, _} = Atanor.drain(node.name)
      until(fn -> scheduler not in :pg.get_members(Atanor.PG, group) end)
    end

    test "the exit of the node follows `stop.exit` unless the call says otherwise" do
      parent = self()
      node = start(stop: [exit: false])
      assert {:ok, _} = Atanor.drain(node.name, exit: &send(parent, {:exit, &1}))
      assert_receive {:exit, 0}
      assert Registry.config(node.name).stop.exit == false
      assert Config.build(data_dir: "/tmp/x", store: {Mod, nil}).stop.exit == true
    end

    test "a drain that ends at the deadline reports the cells it left, and exits with status 1" do
      {node, gate} = stuck(stop: [shutdown_ms: 200, drain_timeout_ms: 200])
      parent = self()
      assert {:ok, %{errors: [{:drain, :deadline}]}} = Atanor.drain(node.name, exit: &send(parent, {:exit, &1}))
      assert_receive {:exit, 1}
      GatedStore.open(gate)
    end
  end

  describe "the admin API and the CLI" do
    test "POST /drain drains, GET /drain reads the state, both need the operator", %{tmp_dir: dir} do
      node = start(admin: [token: @operator, port: 0])
      post(node, "/c/a", "1")
      admin = "http://127.0.0.1:#{Atanor.admin_port(node.name)}"
      headers = [authorization: "Bearer " <> @operator]

      assert Req.post!(admin <> "/drain", retry: false).status == 401
      assert %{status: 200, body: %{"state" => "idle"}} = Req.get!(admin <> "/drain", headers: headers, retry: false)

      resp = Req.post!(admin <> "/drain", headers: headers, retry: false)
      assert %{status: 200, body: %{"state" => "drained", "hibernated" => 1, "errors" => []}} = resp
      assert %{status: 200, body: %{"state" => "drained"}} = Req.get!(admin <> "/drain", headers: headers, retry: false)

      env = %{"ATANOR_URL" => admin, "ATANOR_TOKEN" => @operator, "XDG_CONFIG_HOME" => dir, "HOME" => dir}
      ctx = %{env: env, cwd: dir, stdin: fn _ -> :eof end}
      assert {0, "drained " <> line, ""} = CLI.run(["drain"], ctx)
      assert line =~ "1 cells handed back"
    end

    test "atanor drain exits 1 and names the cells left to their leases", %{tmp_dir: dir} do
      {node, gate} = stuck(admin: [token: @operator, port: 0], stop: [shutdown_ms: 200, drain_timeout_ms: 200])
      admin = "http://127.0.0.1:#{Atanor.admin_port(node.name)}"
      env = %{"ATANOR_URL" => admin, "ATANOR_TOKEN" => @operator, "XDG_CONFIG_HOME" => dir, "HOME" => dir}

      assert {1, "", err} = CLI.run(["drain"], %{env: env, cwd: dir, stdin: fn _ -> :eof end})
      assert err =~ "drain left"
      assert err =~ "deadline"
      GatedStore.open(gate)
    end
  end

  describe "a cell held by a node outside the cluster" do
    setup do
      world = ManualClock.new(1_800_000_000_000)
      clock = {ManualClock, ManualClock.config(world, 0)}
      a = start(alambique: [node_id: "node-a", lease_ttl_ms: 20_000, clock: clock])

      b =
        start(
          store: a.store,
          http: [retry_after_s: 3],
          alambique: [node_id: "node-b", lease_ttl_ms: 20_000, clock: clock]
        )

      assert post(a, "/c/a", "1").status == 200
      %{a: a, b: b}
    end

    test "is a 503 held_elsewhere with the fixed Retry-After on every path, until A hands it back", %{a: a, b: b} do
      # The lease still runs for 22 s, but the wait is the fixed `http.retry_after_s` (3 on B): a routed
      # request, a bounded read and a handler with no routing key (a WASM worker) answer alike.
      for path <- ["/c/a", "/r/a?ms=60000", "/c/direct/a"] do
        resp = get(b, path)
        assert resp.status == 503
        assert resp.body == %{"error" => "unavailable", "reason" => "held_elsewhere"}
        assert resp.headers["retry-after"] == ["3"]
      end

      assert {:ok, _} = Atanor.drain(a.name, exit: false)
      assert %{status: 200, body: %{"rows" => [1]}} = get(b, "/c/a")
      assert %{owner: owner} = lease(b)
      assert owner == node()
    end
  end

  describe "configuration" do
    defp build(opts), do: Config.build([data_dir: "/tmp/x", store: {Mod, nil}] ++ opts)

    test "the defaults are explicit" do
      config = build([])

      assert %{drain_timeout_ms: 15_000, drain_concurrency: 64, shutdown_ms: 75_000, exit: true} =
               Map.take(config.stop, [:drain_timeout_ms, :drain_concurrency, :shutdown_ms, :exit])
    end

    test "wrong values are refused at start" do
      for opts <- [
            [stop: [drain_timeout_ms: nil]],
            [stop: [drain_timeout_ms: 0]],
            [stop: [drain_concurrency: 0]],
            [stop: [exit: "yes"]],
            [stop: [drain_timeout_ms: 80_000, shutdown_ms: 75_000]]
          ] do
        assert_raise ArgumentError, fn -> build(opts) end
      end

      assert build(stop: [drain_timeout_ms: 5_000, shutdown_ms: 5_000, drain_concurrency: 8, exit: false])
    end
  end
end
