defmodule Atanor.PartitionCellsTest do
  @moduledoc "Partitioned cells on one node: addressing, refusals, deployments and WASM host calls (design §4.2)."
  use ExUnit.Case, async: true

  alias Atanor.{Cell, Deployments, Env, Partition, Registry}
  alias Atanor.Test.{Manifests, WasmCase}
  alias AtanorTestkit.Node

  @plain [[1, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"]]
  @logical {"events", "stream"}

  defp start(opts \\ [], node_opts \\ []) do
    manifest =
      Manifests.partitioned(
        "p",
        3,
        [cells: %{"events" => Atanor.Test.PartitionWorker.migrations(), "plain" => @plain}, jobs: true, alarms: true] ++
          opts
      )

    node = Node.start([workers: [manifest]] ++ node_opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp env(node, worker \\ "p") do
    {:ok, deployment} = Registry.deployment(node.name, worker)
    Env.new(node.name, deployment)
  end

  describe "Env.partition/3" do
    test "gives the physical cell of the partition key, always the same" do
      env = env(start())

      for key <- ["alice", "bob", "user-42", "é", ""] do
        assert {:ok, {"events", physical}} = Env.partition(env, @logical, key)
        assert physical == Integer.to_string(Partition.index(key, 3)) <> ".stream"
        assert {:ok, {"events", ^physical}} = Env.partition(env, @logical, key)
      end

      assert {:ok, [{"events", "0.stream"}, {"events", "1.stream"}, {"events", "2.stream"}]} =
               Env.partitions(env, @logical)
    end

    test "refuses a namespace without partitions, one that is not granted, and invalid keys" do
      env = env(start())
      assert {:error, {:not_partitioned, "plain"}} = Env.partition(env, {"plain", "a"}, "alice")
      assert {:error, {:not_partitioned, "plain"}} = Env.partitions(env, {"plain", "a"})
      assert {:error, {:not_granted, {:cell, "other"}}} = Env.partition(env, {"other", "a"}, "alice")
      assert {:error, :invalid_key} = Env.partition(env, {"events", ""}, "alice")
      assert {:error, :invalid_key} = Env.partition(env, {"events", "a/b"}, "alice")
      assert {:error, :invalid_partition_key} = Env.partition(env, @logical, 5)
    end
  end

  describe "addressing" do
    test "a partitioned namespace is used only through the physical keys of its partitions" do
      env = env(start())
      {:ok, cell} = Env.partition(env, @logical, "alice")
      sql = "INSERT INTO log (pk, n) VALUES ('alice', 1)"

      assert {:ok, _} = Env.execute(env, cell, sql)
      assert {:ok, %{rows: [[1]]}} = Env.query(env, cell, "SELECT n FROM log")

      for bad <- [{"events", "stream"}, {"events", "3.stream"}, {"events", "01.stream"}, {"events", "x.1.stream"}] do
        assert {:error, {:partition_required, "events"}} = Env.execute(env, bad, sql)
        assert {:error, {:partition_required, "events"}} = Env.query(env, bad, "SELECT 1")
        assert {:error, {:partition_required, "events"}} = Env.transaction(env, bad, fn _ -> :ok end)
      end

      assert {:error, :invalid_key} = Env.execute(env, {"events", ""}, sql)
      assert {:ok, _} = Env.execute(env, elem(Env.partition(env, {"events", "a.b-1"}, "x"), 1), sql)
    end

    test "only the partitions that were written exist as cells" do
      node = start()
      env = env(node)
      {:ok, cell} = Env.partition(env, @logical, "alice")
      {:ok, _} = Env.execute(env, cell, "INSERT INTO log (pk, n) VALUES ('alice', 1)")

      alambique = Registry.config(node.name).alambique
      assert [id] = for("events." <> _ = id <- Alambique.cells(alambique, limit: 100).cells, do: id)
      assert {:ok, ^cell} = Cell.parse(id)
    end

    test "a namespace without partitions keeps every key, even one that looks like a partition" do
      env = env(start())

      for key <- ["a", "1.a", "stream.9", "9.9"] do
        assert {:ok, _} = Env.execute(env, {"plain", key}, "INSERT INTO t (v) VALUES ('x')")
      end
    end

    test "jobs, alarms, sockets and channels attach to the physical cell" do
      env = env(start(sockets: true))
      {:ok, cell} = Env.partition(env, @logical, "alice")
      later = System.os_time(:millisecond) + 3_600_000

      assert {:ok, _} = Env.enqueue(env, cell, %{kind: "k", payload: "", scheduled_at_ms: later})
      assert :ok = Env.set_alarm(env, cell, later, "x")
      assert :ok = Env.cancel_alarm(env, cell)
      assert {:ok, %{count: 0}} = Env.channel_members(env, cell)
      assert :ok = Env.publish(env, cell, {:text, "hi"})

      error = {:error, {:partition_required, "events"}}
      assert error == Env.enqueue(env, @logical, %{kind: "k", payload: "", scheduled_at_ms: later})
      assert error == Env.set_alarm(env, @logical, later, "x")
      assert error == Env.cancel_alarm(env, @logical)
      assert error == Env.channel_members(env, @logical)
      assert error == Env.publish(env, @logical, {:text, "hi"})
      assert error == Env.send_to_cell(env, @logical, "x")
    end
  end

  describe "routing keys" do
    test "a four-element routing key reaches the partition of its key" do
      node = start()

      for key <- ["alice", "bob", "carol"] do
        assert %{status: 200, body: %{"cell" => cell}} =
                 Req.post!(node.url <> "/p/#{key}", body: "7", retry: false)

        assert cell == Integer.to_string(Partition.index(key, 3)) <> ".stream"
      end

      assert %{status: 200, body: %{"rows" => [7]}} = Req.get!(node.url <> "/p/alice", retry: false)
    end

    test "a routing key must name a partition of a partitioned namespace" do
      node = start()
      {:ok, deployment} = Registry.deployment(node.name, "p")
      env = Env.new(node.name, deployment)

      assert {:error, {:bad_route_key, _}} =
               Atanor.Dispatch.route(%{env | deployment: bad_router(deployment, {:cell, "events", "stream"})}, :x)

      assert {:error, {:bad_route_key, _}} =
               Atanor.Dispatch.route(%{env | deployment: bad_router(deployment, {:cell, "plain", "a", "k"})}, :x)

      assert {:error, {:bad_route_key, _}} =
               Atanor.Dispatch.route(%{env | deployment: bad_router(deployment, {:cell, "events", "", "k"})}, :x)

      assert {:ok, {"events", <<_, ".stream">>}, :strong} =
               Atanor.Dispatch.route(%{env | deployment: bad_router(deployment, {:cell, "events", "stream", "k"})}, :x)
    end
  end

  # A deployment whose module routes everything to `result`.
  defp bad_router(deployment, result) do
    module = Module.concat(__MODULE__, "Router#{System.unique_integer([:positive])}")

    Module.create(
      module,
      quote do
        def route_key(_input, _env), do: unquote(Macro.escape(result))
      end,
      Macro.Env.location(__ENV__)
    )

    %{deployment | module: module}
  end

  describe "registry" do
    test "two workers that grant a namespace agree on its partitions" do
      node = start([], namespaces: %{"events" => ["p", "q", "r"]})
      migrations = Atanor.Test.PartitionWorker.migrations()
      other = fn name, n -> Manifests.partitioned(name, n, cells: %{"events" => migrations}, routes: []) end
      unpartitioned = Manifests.probe("q", module: Atanor.Test.PartitionWorker, cells: %{"events" => migrations})

      # The store refuses a second number at activation; this is the node's own check when it applies heads.
      for manifest <- [other.("q", 4), unpartitioned] do
        Atanor.Store.delete(node.name, "partitions/events")
        assert {:error, {:namespace_conflict, "events", "p"}} = Node.deploy(node, manifest)
      end

      assert {:ok, _} = Node.deploy(node, other.("r", 3))
      assert Registry.partitions(node.name, "events") == 3
      assert Registry.partitions(node.name, "plain") == nil
    end
  end

  describe "the number of partitions is fixed" do
    defp package(n, opts \\ []) do
      Manifests.package(Manifests.partitioned("w", n, opts))
    end

    defp unpartitioned_package do
      Manifests.package(
        Manifests.probe("w",
          module: Atanor.Test.PartitionWorker,
          cells: %{"events" => Atanor.Test.PartitionWorker.migrations()}
        )
      )
    end

    defp publish!(store, package) do
      {:ok, id} = Deployments.publish(store, package)
      id
    end

    test "a package that declares another number, or none, is refused after the first activation" do
      store = Manifests.memory_store()
      [six, twelve, none] = for p <- [package(6), package(12), unpartitioned_package()], do: publish!(store, p)

      assert {:ok, _} = Deployments.activate(store, "w", six)
      assert {:ok, "6", _, _} = Atanor.Store.get(store, "partitions/events")
      assert {:ok, _} = Deployments.activate(store, "w", six)

      assert {:error, {:partitions_changed, "events", 6, 12}} = Deployments.activate(store, "w", twelve)
      assert {:error, {:partitions_changed, "events", 6, nil}} = Deployments.activate(store, "w", none)
      assert {:ok, %{active: ^six}} = Deployments.head(store, "w")
    end

    test "a rollback to a package with another number is refused" do
      store = Manifests.memory_store()
      none = publish!(store, unpartitioned_package())
      six = publish!(store, package(6))

      {:ok, _} = Deployments.activate(store, "w", none)
      {:ok, _} = Deployments.activate(store, "w", six)
      assert {:error, {:partitions_changed, "events", 6, nil}} = Deployments.rollback(store, "w")
      assert {:ok, %{active: ^six, previous: [^none]}} = Deployments.head(store, "w")
    end

    test "a namespace that has cells cannot become partitioned" do
      node = start()
      env = env(node)
      {:ok, _} = Env.execute(env, {"plain", "a"}, "INSERT INTO t (v) VALUES ('x')")

      migrations = %{"plain" => @plain}
      manifest = Manifests.partitioned("p", 4, cells: migrations, partitions: %{"plain" => 4}, routes: [])
      id = publish!(node.name, Manifests.package(manifest))
      assert {:error, {:namespace_has_data, "plain"}} = Deployments.activate(node.name, "p", id)

      empty = Manifests.partitioned("p", 4, cells: %{"fresh" => @plain}, partitions: %{"fresh" => 4}, routes: [])
      id = publish!(node.name, Manifests.package(empty))
      assert {:ok, _} = Deployments.activate(node.name, "p", id)
    end
  end

  describe "WASM guests" do
    setup do
      node =
        WasmCase.start([
          {"cell", "cell", cells: %{"events" => @plain, "plain" => @plain}, partitions: %{"events" => 3}}
        ])

      %{node: node}
    end

    defp wasm(node, op, key, opts) do
      headers = [{"x-op", op}, {"x-ns", opts[:ns] || "events"}, {"x-key", key}, {"x-partition", opts[:partition] || ""}]
      WasmCase.request(node, "cell", "", method: :post, body: opts[:sql] || "", headers: headers)
    end

    test "partition returns the same physical cell as the native call", %{node: node} do
      for key <- ["alice", "bob", "user-42"] do
        expected = "events." <> Integer.to_string(Partition.index(key, 3)) <> ".stream"
        assert %{status: 200, body: ^expected} = wasm(node, "partition", "stream", partition: key)
      end
    end

    test "the physical cell works with sql, the logical one is refused", %{node: node} do
      %{body: "events." <> key} = wasm(node, "partition", "stream", partition: "alice")
      assert %{status: 200} = wasm(node, "execute", key, sql: "INSERT INTO t (v) VALUES ('x')")
      assert %{status: 200, body: "[count(*)] 1"} = wasm(node, "query", key, sql: "SELECT count(*) FROM t")

      assert %{status: 500, body: "failed: " <> reason} = wasm(node, "query", "stream", sql: "SELECT 1", ns: "events")
      assert reason =~ "partition_required"
    end

    test "partition is refused for a namespace without partitions, one not granted, and an invalid key",
         %{node: node} do
      assert %{status: 500, body: "failed: " <> reason} = wasm(node, "partition", "a", ns: "plain", partition: "k")
      assert reason =~ "not_partitioned"
      assert %{status: 403, body: "not granted: other"} = wasm(node, "partition", "a", ns: "other", partition: "k")
      assert %{status: 500} = wasm(node, "partition", "a/b", partition: "k")
    end
  end
end
