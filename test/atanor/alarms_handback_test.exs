defmodule Atanor.AlarmsHandbackTest do
  @moduledoc """
  Alarms when two nodes that share a store are not clustered, as during a node swap: each scans every
  shard, and the cell's lease decides which one fires (design §7.4).
  """
  use ExUnit.Case, async: false

  import Atanor.Test.Await

  alias Atanor.{Alarms, Cell}
  alias Atanor.Test.{AlarmWorker, Manifests}
  alias AlambiqueTestkit.ManualClock
  alias AtanorTestkit.Node

  @moduletag capture_log: true
  @start 1_000_000_000_000

  defp manifest do
    Manifests.probe("clock",
      module: AlarmWorker,
      alarms: true,
      cells: %{"clock" => AlarmWorker.migrations()},
      routes: [{"127.0.0.1", "/"}]
    )
  end

  # Neither scheduler ticks: the test scans, as a node that owns every shard would.
  defp start(world, opts \\ []) do
    clock = {ManualClock, ManualClock.config(world, 0)}

    node =
      Node.start(
        [
          workers: [manifest()],
          alarms: [clock: clock, tick_ms: 3_600_000],
          alambique: [node_id: "node-#{System.unique_integer([:positive])}"],
          stop: [exit: false]
        ] ++ opts
      )

    on_exit(fn -> Node.stop(node) end)
    node
  end

  setup do
    world = ManualClock.new(@start)
    a = start(world)
    b = start(world, store: a.store)
    Process.register(self(), :alarm_probe)

    assert Req.get!("#{a.url}/set?key=k&at=#{@start + 1_000}&payload=once", retry: false).body == ":ok"
    ManualClock.advance(world, 2_000)
    %{a: a, b: b}
  end

  defp scan(node), do: Alarms.run(node.name, fn _ -> true end)

  defp fires(node) do
    {:ok, %{rows: rows}} = Cell.query(node.name, {"clock", "k"}, "SELECT payload FROM fires ORDER BY id")
    List.flatten(rows)
  end

  test "an alarm due while both nodes scan fires once", %{a: a, b: b} do
    # A scans twice at once as well: the conditional claim, not the lease alone, lets one scan fire.
    for _ <- 1..5 do
      [a, a, b] |> Enum.map(&Task.async(fn -> scan(&1) end)) |> Task.await_many()
    end

    assert_receive {:alarm, "k", "once", 1}, 5_000
    assert fires(a) == ["once"]

    # The other node keeps scanning after A hands the cell back: the alarm is done, not fired again.
    assert {:ok, _} = Atanor.drain(a.name, exit: false)
    scan(b)
    scan(b)
    refute_receive {:alarm, _, _, _}, 300
    assert fires(b) == ["once"]
  end

  test "the node that does not hold the cell leaves the alarm until the cell is handed back", %{a: a, b: b} do
    scan(b)
    refute_receive {:alarm, _, _, _}, 300
    {:ok, keys, _} = Atanor.Store.list(Atanor.Store.handle(b.name), "alarms/")
    assert [_] = Enum.filter(keys, &String.contains?(&1, "/clock.k"))

    assert {:ok, _} = Atanor.drain(a.name, exit: false)
    assert until(fn -> scan(b) == 1 or fires(b) == ["once"] end)
    assert_receive {:alarm, "k", "once", 1}
    scan(b)
    refute_receive {:alarm, _, _, _}, 300
    assert fires(b) == ["once"]
  end
end
