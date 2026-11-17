defmodule Atanor.PressureTest do
  @moduledoc """
  Under memory pressure the node hibernates its idle cells before the refuse mark, and never a busy one
  (design §4.3).
  """
  use ExUnit.Case, async: true

  alias Atanor.{Admission, Cell, Pressure}
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Node

  @moduletag :tmp_dir

  @sql "INSERT INTO notes (body) VALUES ('x')"

  def pressure(_event, measures, %{instance: name}, {test, name}), do: send(test, {:pressure, measures})
  def pressure(_event, _measures, _meta, _config), do: :ok

  defp flush_pressure(acc) do
    receive do
      {:pressure, measures} -> flush_pressure([measures | acc])
    after
      0 -> acc
    end
  end

  defp awake(node), do: Atanor.Overview.cells_count(node.name).count

  test "hibernates idle cells at the pressure mark, in batches, and skips a busy one", %{tmp_dir: dir} do
    current = Path.join(dir, "memory.current")
    stat = Path.join(dir, "memory.stat")
    File.write!(current, "100000\n")

    node =
      Node.start(
        workers: [Manifests.probe("gate", cells: %{"notes" => Manifests.notes_migrations()})],
        memory: [
          limit_bytes: 1_000_000,
          current_path: current,
          stat_path: stat,
          sample_ms: 20,
          hibernate_fraction: 0.75,
          hibernate_batch: 2,
          hibernate_interval_ms: 50
        ]
      )

    on_exit(fn -> Node.stop(node) end)
    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, [:atanor, :memory, :pressure], &__MODULE__.pressure/4, {self(), node.name})
    on_exit(fn -> :telemetry.detach(handler) end)

    for key <- 1..5, do: assert({:ok, _} = Cell.execute(node.name, {"notes", "idle#{key}"}, @sql))
    assert awake(node) == 5
    assert %{hibernated: 0, hibernate_at_bytes: 750_000} = Pressure.stats(node.name)

    test = self()

    busy =
      Task.async(fn ->
        Cell.transaction(node.name, {"notes", "busy"}, fn _tx ->
          send(test, {:busy, self()})

          receive do
            :release -> :done
          end
        end)
      end)

    assert_receive {:busy, in_cell}, 30_000

    # Past the pressure mark and below the refuse mark (850 000): the node sheds cells and does not refuse.
    File.write!(current, "800000\n")
    Await.until(fn -> awake(node) == 1 end, 20_000)
    refute Admission.stats(node.name).refusing
    # A batch is counted when the whole batch returns, so the last cell can be asleep before its count lands.
    Await.until(fn -> Pressure.stats(node.name).hibernated == 5 end, 20_000)

    batches = flush_pressure([])
    assert length(batches) >= 3
    assert Enum.all?(batches, &(&1.candidates <= 2 and &1.working_set_bytes == 800_000))

    send(in_cell, :release)
    assert {:ok, :done} = Task.await(busy, 30_000)
  end

  test "does nothing below the mark: telemetry events stay silent", %{tmp_dir: dir} do
    current = Path.join(dir, "memory.current")
    File.write!(current, "700000\n")

    node =
      Node.start(
        workers: [Manifests.probe("gate", cells: %{"notes" => Manifests.notes_migrations()})],
        memory: [
          limit_bytes: 1_000_000,
          current_path: current,
          stat_path: Path.join(dir, "memory.stat"),
          hibernate_interval_ms: 20
        ]
      )

    on_exit(fn -> Node.stop(node) end)
    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, [:atanor, :memory, :pressure], &__MODULE__.pressure/4, {self(), node.name})
    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} = Cell.execute(node.name, {"notes", "a"}, @sql)
    refute_receive {:pressure, _}, 300
    assert awake(node) == 1
    assert Pressure.stats(node.name).hibernated == 0
  end

  test "is off without a limit or with hibernate_fraction nil", %{tmp_dir: dir} do
    node = Node.start(workers: [Manifests.probe("gate")], memory: [cgroup_path: Path.join(dir, "none")])
    on_exit(fn -> Node.stop(node) end)
    assert Pressure.stats(node.name) == nil

    off = Node.start(workers: [Manifests.probe("gate")], memory: [limit_bytes: 1_000, hibernate_fraction: nil])
    on_exit(fn -> Node.stop(off) end)
    assert Pressure.stats(off.name) == nil
  end
end
