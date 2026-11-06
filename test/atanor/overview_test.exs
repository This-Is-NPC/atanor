defmodule Atanor.OverviewTest do
  use ExUnit.Case, async: true

  alias Atanor.{Overview, Registry}
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
end
