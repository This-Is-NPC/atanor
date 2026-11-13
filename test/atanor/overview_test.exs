defmodule Atanor.OverviewTest.Store do
  @moduledoc false
  # The memory store; once `fail/1` is called every request answers an HTTP 500.
  @behaviour Alambique.Store

  def wrap(config), do: {__MODULE__, {AlambiqueTestkit.MemoryStore, config, :atomics.new(1, [])}}
  def fail({__MODULE__, {_, _, flag}}), do: :atomics.put(flag, 1, 1)

  defp run({m, c, flag}, fun, args) do
    if :atomics.get(flag, 1) == 1, do: {:error, {:http, 500, "down"}}, else: apply(m, fun, [c | args])
  end

  @impl true
  def put(h, key, body, condition, meta), do: run(h, :put, [key, body, condition, meta])
  @impl true
  def get(h, key), do: run(h, :get, [key])
  @impl true
  def head(h, key), do: run(h, :head, [key])
  @impl true
  def get_range(h, key, offset, length), do: run(h, :get_range, [key, offset, length])
  @impl true
  def list(h, prefix, start_after, limit), do: run(h, :list, [prefix, start_after, limit])
  @impl true
  def delete(h, key), do: run(h, :delete, [key])
end

defmodule Atanor.OverviewTest do
  use ExUnit.Case, async: true

  alias Atanor.{Env, Overview, Registry}
  alias Atanor.OverviewTest.Store
  alias Atanor.Test.{Await, Manifests}
  alias AlambiqueTestkit.MemoryStore
  alias AtanorTestkit.Node

  defp start(opts \\ []) do
    node = Node.start(opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  test "a node that starts or stops says so, and does not serve" do
    node = start()
    assert %{status: "ok"} = Overview.health(node.name)
    assert {200, %{status: "ready"}} = Overview.ready(node.name)

    :ok = Registry.put_state(node.name, {:starting, "migrating"})
    assert %{status: "starting"} = Overview.health(node.name)
    assert {503, %{status: "starting", reason: "migrating"}} = Overview.ready(node.name)
    assert {503, %{status: "starting"}} = Overview.serving(node.name)

    :ok = Registry.put_state(node.name, :stopping)
    assert %{status: "stopping"} = Overview.health(node.name)
    assert {503, %{status: "stopping", reason: "the node is stopping"}} = Overview.ready(node.name)
    assert {503, %{status: "stopping"}} = Overview.serving(node.name)
  end

  test "the hot cells are off by default, and a policy reports its settings as text" do
    off = start()
    assert %{enabled: false} = Overview.hot_cells(off.name)

    on = start(hot_cells: [enabled: true])
    me = Atom.to_string(node())
    assert %{enabled: true, node: ^me, peers: [], hot: [], moving: []} = Overview.hot_cells(on.name)
  end

  test "an open store breaker is shown on health and runtime and does not change readiness" do
    {:ok, server} = MemoryStore.start_link([])
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    store = Store.wrap(MemoryStore.config(server))
    manifest = Manifests.probe("breaker", cells: %{"notes" => Manifests.notes_migrations()})
    node = start(store: store, workers: [manifest], alambique: [breaker: [failures: 1, cooldown_ms: 60_000]])
    {:ok, deployment} = Registry.deployment(node.name, "breaker")
    env = Env.new(node.name, deployment)

    assert {:ok, _} = Env.execute(env, {"notes", "a"}, "INSERT INTO notes (body) VALUES ('x')")
    assert [%{state: "closed", failures: 0}] = Map.values(Overview.health(node.name).store)

    Store.fail(store)
    {:error, _} = Env.execute(env, {"notes", "b"}, "INSERT INTO notes (body) VALUES ('x')")

    Await.until(fn -> match?([%{state: "open"}], Map.values(Overview.health(node.name).store)) end)
    assert [%{state: "open", failures: 1, since_ms: since}] = Map.values(Overview.runtime(node.name).store)
    assert is_integer(since)
    assert %{status: "ok"} = Overview.health(node.name)
    assert {200, %{status: "ready"}} = Overview.ready(node.name)
  end
end
