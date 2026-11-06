defmodule Atanor.InstanceTest do
  use ExUnit.Case, async: true

  alias AtanorTestkit.Node

  test "starts and stops cleanly, releasing the port" do
    node = Node.start()
    assert node.port > 0
    assert Process.alive?(node.pid)

    :ok = Node.stop(node)

    refute Process.alive?(node.pid)
    refute File.exists?(node.data_dir)
    assert {:error, _} = :gen_tcp.connect(~c"127.0.0.1", node.port, [], 500)
  end

  test "keeps the config of each instance without a copy and forgets it on stop" do
    a = Node.start(prefix: "config-a")
    b = Node.start(prefix: "config-b")
    on_exit(fn -> Node.stop(a) end)

    assert Atanor.Registry.config(a.name).prefix == "config-a"
    assert Atanor.Registry.config(b.name).prefix == "config-b"
    assert Atanor.Registry.config(a.name) == Atanor.Registry.config(a.name)

    :ok = Node.stop(b)
    assert :persistent_term.get({Atanor.Registry, b.name}, nil) == nil
    assert Atanor.Registry.state(a.name) == :ready
  end

  test "runs several instances side by side" do
    a = Node.start()
    b = Node.start()

    on_exit(fn ->
      Node.stop(a)
      Node.stop(b)
    end)

    assert a.name != b.name
    assert a.port != b.port
  end

  defmodule RaisingStore do
    def get(_config, _key), do: raise("Finch was unable to provide a connection")
    def list(_config, _prefix, _start, _limit), do: exit(:pool_down)
  end

  test "a store that raises or exits answers an error instead of crashing the caller" do
    handle = Atanor.Store.open({RaisingStore, nil}, "p")

    assert {:error, {:store_exception, %RuntimeError{}}} = Atanor.Store.get(handle, "k")
    assert {:error, {:store_exit, :pool_down}} = Atanor.Store.list(handle, "")
  end

  defmodule NoLocations do
    def locate(_opts, _cell), do: {:error, :nope}
    def locations(_opts), do: {:error, :nope}
  end

  # Alambique names the store identity from the placement's locations, so it refuses to start without them.
  test "a placement whose locations fail does not start" do
    {:ok, pid} = AlambiqueTestkit.MemoryStore.start_link()
    store = {AlambiqueTestkit.MemoryStore, AlambiqueTestkit.MemoryStore.config(pid)}
    dir = Path.join(System.tmp_dir!(), "atanor-nolocations-#{System.pid()}-#{System.unique_integer([:positive])}")
    Process.flag(:trap_exit, true)

    opts = [name: :no_locations, placement: {NoLocations, []}, meta_store: store, data_dir: dir, port: 0]

    assert {:error, {:shutdown, {:failed_to_start_child, _, {%ArgumentError{message: message}, _}}}} =
             Supervisor.start_link([{Atanor, opts}], strategy: :one_for_one)

    assert message =~ "locations must be a non-empty list"
  end

  test "stores metadata under the prefix" do
    node = Node.start(prefix: "meta")
    on_exit(fn -> Node.stop(node) end)

    {:ok, _etag} = Atanor.Store.put(node.name, "workers/x/head", "{}")
    assert {:ok, "{}", _, _} = Atanor.Store.get(node.name, "workers/x/head")
    assert {:ok, ["workers/x/head"], nil} = Atanor.Store.list(node.name, "workers/")

    {mod, config} = node.store
    assert {:ok, _, _} = mod.head(config, "meta/workers/x/head")
    :ok = Atanor.Store.delete(node.name, "workers/x/head")
    assert {:error, :not_found} = Atanor.Store.get(node.name, "workers/x/head")
  end

  describe "options" do
    @valid [data_dir: "/tmp/x", store: {Mod, %{}}]

    test "reject invalid values with ArgumentError" do
      for {opts, message} <- [
            {[data_dir: "/tmp/x"], ~r/:store or :placement/},
            {[store: {Mod, %{}}], ~r/:data_dir is required/},
            {@valid ++ [bogus: 1], ~r/unknown options/},
            {@valid ++ [alambique: [join: true]], ~r/:join is set by Atanor/},
            {@valid ++ [alambique: [feed: [internal_prefixes: []]]], ~r/:internal_prefixes is set by Atanor/},
            {@valid ++ [port: 70_000], ~r/:port/},
            {@valid ++ [name: "x"], ~r/:name/},
            {@valid ++ [prefix: "Bad Prefix"], ~r/:prefix/},
            {@valid ++ [placement: {Mod, []}], ~r/not both/},
            {[data_dir: "/tmp/x", placement: {Mod, []}], ~r/:meta_store/},
            {@valid ++ [namespaces: [1]], ~r/:namespaces/},
            {@valid ++ [max_body_bytes: 0], ~r/:max_body_bytes/},
            {@valid ++ [secrets: %{"w" => %{"A" => 1}}], ~r/:secrets/},
            {@valid ++ [secrets: [{"w", "x"}]], ~r/:secrets/},
            {@valid ++ [workers: []], ~r/unknown options/},
            {@valid ++ [poll_interval_ms: 0], ~r/:poll_interval_ms/},
            {@valid ++ [hosts: [a: 1]], ~r/:hosts/},
            {@valid ++ [hosts: %{"w" => ["Bad.Host"]}], ~r/:hosts/},
            {@valid ++ [hosts: %{"w" => ["a.*.test"]}], ~r/:hosts/},
            {@valid ++ [listeners: %{"smtp" => 70_000}], ~r/:listeners/},
            {@valid ++ [tcp: [idle_timeout_ms: 0]], ~r/:tcp/},
            {@valid ++ [tcp: [nope: 1]], ~r/:tcp/},
            {@valid ++ [tcp: [acceptors: 5, max_connections: 4]], ~r/:acceptors/},
            {@valid ++ [websocket: [max_frame_bytes: -1]], ~r/:websocket/},
            {@valid ++ [alarms: [tick_ms: 0]], ~r/:alarms/},
            {@valid ++ [alarms: [page_size: 0]], ~r/:alarms/},
            {@valid ++ [alarms: [concurrency: 0]], ~r/:alarms/},
            {@valid ++ [alarms: [backoff_ms: 0]], ~r/:alarms/},
            {@valid ++ [alarms: [max_backoff_ms: 0]], ~r/:alarms/},
            {@valid ++ [alarms: [shards: 0]], ~r/:alarms/},
            {@valid ++ [alarms: [clock: :system]], ~r/:alarms :clock/},
            {@valid ++ [jobs: [claim_ms: 1, timeout_ms: 10]], ~r/:claim_ms/},
            {@valid ++ [jobs: [worker_concurrency: 9, concurrency: 8]], ~r/:worker_concurrency/},
            {@valid ++ [jobs: [backoff_ms: 10, max_backoff_ms: 9]], ~r/:backoff_ms/},
            {@valid ++ [jobs: [dead_retention_ms: 0]], ~r/:dead_retention_ms/},
            {@valid ++ [sweeps: [renew_ms: 10, lease_ttl_ms: 10]], ~r/:renew_ms/},
            {@valid ++ [sweeps: [cell_timeout_ms: 20_000, lease_ttl_ms: 20_000]], ~r/:cell_timeout_ms/},
            {@valid ++ [sweeps: [canary_gate: "later"]], ~r/canary_gate/},
            {@valid ++ [sweeps: [guard_error_rate: 0]], ~r/guard_error_rate/},
            {@valid ++ [sweeps: [guard_min_cells: 60]], ~r/guard_min_cells/},
            {@valid ++ [feed: [poll_ms: 0]], ~r/:feed/},
            {@valid ++ [feed: [retry_ms: 100, max_backoff_ms: 50]], ~r/:retry_ms/},
            {@valid ++ [deployments: [max_previous: 0]], ~r/:deployments/},
            {@valid ++ [deployments: [max_attempts: -1]], ~r/:deployments/},
            {@valid ++ [calls: [max_depth: 0]], ~r/:calls/},
            {@valid ++ [calls: [max_redirects: 0]], ~r/:calls/},
            {@valid ++ [http: [retry_after_s: 0]], ~r/:http/},
            {@valid ++ [overview: [timeout_ms: 0]], ~r/:overview/},
            {@valid ++ [metadata: [page_size: 0]], ~r/:metadata/},
            {@valid ++ [sockets: [attach_timeout_ms: 0]], ~r/:sockets/},
            {@valid ++ [channels: [max_message_bytes: 0]], ~r/:channels/},
            {@valid ++ [channels: [max_subscriptions: -1]], ~r/:channels/},
            {@valid ++ [channels: [max_channels: 0]], ~r/:channels/},
            {@valid ++ [channels: [nope: 1]], ~r/:channels/},
            {@valid ++ [admin: [token: "t", default_limit: 0]], ~r/:default_limit/},
            {@valid ++ [admin: [token: "t", max_limit: 0]], ~r/:max_limit/},
            {@valid ++ [admin: [token: "t", default_limit: 5, max_limit: 4]], ~r/:default_limit/},
            {@valid ++ [dashboard: [token: "t", page_size: 5, max_page_size: 4]], ~r/:page_size/},
            {@valid ++ [dashboard: [token: "t", poll_ms: 0]], ~r/:poll_ms/},
            {@valid ++ [routing: [pinned_limit: 0]], ~r/:routing/},
            {@valid ++ [listeners: %{"Bad" => 25}], ~r/:listeners/},
            {@valid ++ [listeners: %{"smtp" => [port: 25, ip: "mail.example.com"]}],
             ~r/"smtp": :ip must be an IPv4 or IPv6/},
            {@valid ++ [listeners: %{"smtp" => [port: 25, ip: {1, 2, 3}]}], ~r/:ip must be an IPv4 or IPv6/},
            {@valid ++ [listeners: %{"smtp" => [port: 25, ip: {256, 0, 0, 1}]}], ~r/:ip must be an IPv4 or IPv6/},
            {@valid ++ [allow_private_hosts: "localhost"], ~r/:allow_private_hosts/},
            {@valid ++ [allow_private_hosts: ["10.0.0.0/33"]], ~r/invalid entry/},
            {@valid ++ [allow_private_hosts: ["Bad Host"]], ~r/invalid entry/}
          ] do
        assert_raise ArgumentError, message, fn -> Atanor.child_spec(opts) end
      end
    end

    test "Alambique starts with Atanor's internal prefix next to the operator's feed options" do
      opts = Atanor.Config.build(@valid ++ [alambique: [feed: [window_ms: 5, linger_ms: 0]]]).alambique_opts

      assert Enum.sort(opts[:feed]) == [
               internal_prefixes: ["_atanor_"],
               linger_ms: 0,
               object_batches: 16,
               window_ms: 5
             ]

      assert opts[:join] == false
    end

    test "accept :infinity for the dead-letter retention" do
      config = Atanor.Config.build(@valid ++ [jobs: [dead_retention_ms: :infinity]])
      assert config.jobs.dead_retention_ms == :infinity
    end

    test "accept a placement with a meta store" do
      assert %{id: {Atanor, Atanor}} =
               Atanor.child_spec(data_dir: "/tmp/x", placement: {Mod, []}, meta_store: {Mod, %{}})
    end

    test "default and check the ingress limits" do
      assert %{max_connections: 16_384, acceptors: 10, read_timeout_ms: 10_000, http_2: true} =
               Atanor.Config.build(@valid).http

      assert %{max_path_segments: 64, max_host_labels: 16} = Atanor.Config.build(@valid).http
      assert %{max_connections: 128, acceptors: 4} = Atanor.Config.build(@valid ++ [admin: [token: "t"]]).admin

      assert_raise ArgumentError, ~r/:http :acceptors must not exceed/, fn ->
        Atanor.Config.build(@valid ++ [http: [acceptors: 5, max_connections: 4]])
      end

      assert_raise ArgumentError, ~r/:admin :acceptors must not exceed/, fn ->
        Atanor.Config.build(@valid ++ [admin: [token: "t", acceptors: 5, max_connections: 4]])
      end

      assert_raise ArgumentError, ~r/:http must be a keyword list/, fn ->
        Atanor.Config.build(@valid ++ [http: [max_connections: 0]])
      end
    end

    test "keep non-default operational values" do
      config =
        Atanor.Config.build(
          @valid ++
            [
              tcp: [acceptors: 3],
              alarms: [page_size: 7, concurrency: 2, backoff_ms: 11, max_backoff_ms: 12, max_attempts: 3, shards: 8],
              deployments: [max_previous: 2, max_attempts: 4],
              calls: [max_depth: 2, max_redirects: 3],
              http: [retry_after_s: 9],
              overview: [timeout_ms: 1234],
              metadata: [page_size: 2],
              sockets: [attach_timeout_ms: 55],
              routing: [pinned_limit: 5],
              feed: [poll_ms: 25, page_size: 5, retry_ms: 10, max_backoff_ms: 20, max_backlog: 7],
              admin: [token: "t", default_limit: 3, max_limit: 4],
              dashboard: [token: "t", page_size: 6, max_page_size: 8, poll_ms: 900]
            ]
        )

      assert config.tcp.acceptors == 3

      assert config.alarms == %{
               tick_ms: 1_000,
               timeout_ms: 30_000,
               max_attempts: 3,
               page_size: 7,
               concurrency: 2,
               backoff_ms: 11,
               max_backoff_ms: 12,
               shards: 8,
               clock: {Alambique.Clock.System, nil}
             }

      assert config.deployments == %{max_previous: 2, max_attempts: 4}
      assert config.calls == %{max_depth: 2, max_redirects: 3, fetch_max_bytes: 8_000_000, fetch_timeout_ms: 30_000}
      assert config.http.retry_after_s == 9
      assert config.overview == %{timeout_ms: 1234}
      assert config.metadata == %{page_size: 2}
      assert config.sockets == %{attach_timeout_ms: 55, max_attachments: 16}
      assert config.routing.pinned_limit == 5
      assert config.feed == %{poll_ms: 25, page_size: 5, retry_ms: 10, max_backoff_ms: 20, max_backlog: 7}
      assert config.admin.default_limit == 3 and config.admin.max_limit == 4
      assert config.dashboard.page_size == 6 and config.dashboard.max_page_size == 8
      assert config.dashboard.poll_ms == 900
    end
  end
end
