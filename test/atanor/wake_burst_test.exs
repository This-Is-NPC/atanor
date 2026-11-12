defmodule Atanor.WakeBurstTest.Store do
  @moduledoc false
  # The memory store, counting the reads of the files of the state (`.ltx`), whole or by range.
  @behaviour Alambique.Store

  # Counter 1 counts the reads, counter 2 is 1 once the store fails: a write then waits `@fail_ms` and
  # answers an HTTP 500, as a store whose disk is full does.
  @fail_ms 250

  def wrap(config), do: {__MODULE__, {AlambiqueTestkit.MemoryStore, config, :counters.new(2, [])}}
  def reads({__MODULE__, {_, _, counter}}), do: :counters.get(counter, 1)
  def fail({__MODULE__, {_, _, counter}}), do: :counters.put(counter, 2, 1)

  defp count(counter, key), do: if(String.contains?(key, ".ltx"), do: :counters.add(counter, 1, 1))

  @impl true
  def put({m, c, n}, key, body, condition, meta) do
    if :counters.get(n, 2) == 1 do
      Process.sleep(@fail_ms)
      {:error, {:http, 500, "store full"}}
    else
      m.put(c, key, body, condition, meta)
    end
  end

  @impl true
  def get({m, c, n}, key), do: tap(m.get(c, key), fn _ -> count(n, key) end)
  @impl true
  def head({m, c, _}, key), do: m.head(c, key)
  @impl true
  def get_range({m, c, n}, key, offset, length), do: tap(m.get_range(c, key, offset, length), fn _ -> count(n, key) end)
  @impl true
  def list({m, c, _}, prefix, start_after, limit), do: m.list(c, prefix, start_after, limit)
  @impl true
  def delete({m, c, _}, key), do: m.delete(c, key)
end

defmodule Atanor.WakeBurstTest do
  @moduledoc """
  A node whose store fails its writes must not die of the wakes that its queued requests start (design §4.3).

  An upload that fails stops the cell; every request waiting for it then wakes it again, each wake restores
  the state of the cell from the store, and nothing bounded those restores. Run alone, it measures the memory
  of the VM: `mix test test/atanor/wake_burst_test.exs`.
  """
  # Not async: the memory of the node is measured, so no other test may run beside it.
  use ExUnit.Case, async: false

  alias Atanor.{Env, Overview}
  alias Atanor.Test.{Await, Manifests}
  alias Atanor.WakeBurstTest.Store
  alias AlambiqueTestkit.MemoryStore
  alias AtanorTestkit.Node

  @moduletag :tmp_dir

  @cells 48
  @requests 480
  # Two 1 MB random blobs per cell: the state a restore reads is about 2 MB.
  @fill "INSERT INTO notes (body) VALUES (randomblob(1000000))"
  @write "INSERT INTO notes (body) VALUES ('x')"
  @limit 128 * 1_048_576
  @sample_ms 50

  defp start(tmp_dir) do
    {:ok, server} = MemoryStore.start_link([])
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    store = Store.wrap(MemoryStore.config(server))

    # The cgroup files are a node with plenty of room: the memory gate stays off, so only the bound on the
    # wakes is under test.
    current = Path.join(tmp_dir, "memory.current")
    File.write!(current, "1000\n")

    manifest = Manifests.probe("burst", cells: %{"notes" => Manifests.notes_migrations()})

    node =
      Node.start(
        store: store,
        workers: [manifest],
        alambique: [op_timeout_ms: 1_000],
        memory: [limit_bytes: @limit, current_path: current, stat_path: Path.join(tmp_dir, "none")]
      )

    on_exit(fn -> Node.stop(node) end)
    {:ok, deployment} = Atanor.Registry.deployment(node.name, "burst")
    {node, Env.new(node.name, deployment), store}
  end

  defp wakes(node) do
    config = Atanor.Registry.config(node.name).alambique
    [{:wakes, n}] = :ets.lookup(Alambique.Config.fetch!(config).admission, :wakes)
    n
  end

  # {peak total memory above the start, peak wakes in flight, peak process count above the start}
  defp sampler(node) do
    parent = self()
    base = :erlang.memory(:total)
    procs = :erlang.system_info(:process_count)

    pid =
      spawn_link(fn ->
        loop = fn loop, {mem, wake, count} ->
          receive do
            :stop -> send(parent, {:peaks, {mem, wake, count}})
          after
            @sample_ms ->
              loop.(loop, {
                max(mem, :erlang.memory(:total) - base),
                max(wake, wakes(node)),
                max(count, :erlang.system_info(:process_count) - procs)
              })
          end
        end

        loop.(loop, {0, 0, 0})
      end)

    fn ->
      send(pid, :stop)
      assert_receive {:peaks, peaks}, 5_000
      peaks
    end
  end

  defp burst(tmp_dir) do
    {node, env, store} = start(tmp_dir)

    cells = for n <- 1..@cells, do: {"notes", "c#{n}"}

    for cell <- cells do
      {:ok, _} = Env.execute(env, cell, @fill)
      {:ok, _} = Env.execute(env, cell, @fill)
    end

    assert Overview.cells_count(node.name).count == @cells

    # The store now fails every write: the next upload of each cell fails and stops it.
    Store.fail(store)
    # Each cell fails its upload and stops, as the cells of the node did when its store filled up.
    cells
    |> Task.async_stream(&Env.execute(env, &1, @write), max_concurrency: @cells, timeout: 30_000)
    |> Stream.run()

    Await.until(fn -> Overview.cells_count(node.name).count == 0 end, 30_000)
    reads = Store.reads(store)
    stop = sampler(node)

    results =
      1..@requests
      |> Task.async_stream(
        fn n -> Env.execute(env, Enum.at(cells, rem(n, @cells)), @write) end,
        max_concurrency: @requests,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {mem, wake, procs} = stop.()
    {mem, wake, procs, Store.reads(store) - reads, results}
  end

  test "requests that wake the cells of a failing store are bounded by the memory of the node", %{tmp_dir: dir} do
    {mem, wake, procs, reads, results} = burst(dir)
    peaks = "memory +#{div(mem, 1_048_576)} MiB, wakes #{wake}, processes +#{procs}, restore reads #{reads}"

    # No request is answered by a cell; they are refused or fail with the store.
    assert Enum.all?(results, &match?({:error, _}, &1))
    # A 128 MiB node gives 9.6 MiB of its headroom to wakes: 4 at once (design §4.3). Without the bound all
    # 48 cells wake together: memory +13 MiB, processes +626, 336 reads.
    assert wake <= 4, peaks
    assert reads <= 100, peaks
    assert procs <= 200, peaks
    assert mem <= 8 * 1_048_576, peaks
  end
end
