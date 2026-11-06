defmodule Atanor.JobsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.{Cell, Jobs, Store}
  alias Atanor.Test.Manifests
  alias AlambiqueTestkit.ManualClock
  alias AtanorTestkit.Node

  @start 1_000_000_000_000

  @moduletag timeout: 120_000

  property "enqueue keeps the job rows, unique keys and the wake-up consistent" do
    check all(
            specs <-
              list_of(
                tuple({integer(0..5_000), integer(1..3), member_of([nil, "u1", "u2"])}),
                min_length: 1,
                max_length: 12
              ),
            max_runs: 8
          ) do
      world = ManualClock.new(@start)
      alarms = [clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 3_600_000]
      node = Node.start(workers: [Manifests.jobs("jobs")], alarms: alarms)

      try do
        {inserted, due} =
          specs
          |> Enum.with_index()
          |> Enum.reduce({0, []}, fn {{delay, payload, unique}, _index}, {count, due} ->
            spec = %{
              kind: "test",
              payload: Integer.to_string(payload),
              scheduled_at_ms: @start + delay,
              unique_key: unique
            }

            case Jobs.enqueue_direct(node.name, "jobs", {"jobs", "p"}, spec) do
              {:ok, {:duplicate, _id}} -> {count, due}
              {:ok, _id} -> {count + 1, [@start + delay | due]}
              other -> flunk("unexpected enqueue result: #{inspect(other)}")
            end
          end)

        {:ok, %{rows: [[jobs]]}} =
          Cell.query(node.name, {"jobs", "p"}, "SELECT count(*) FROM _atanor_jobs")

        assert jobs == inserted
        assert no_live_duplicate_unique_keys?(node)

        if inserted == 0 do
          assert {:ok, %{rows: [[0]]}} =
                   Cell.query(node.name, {"jobs", "p"}, "SELECT count(*) FROM _atanor_alarms WHERE worker = '@jobs'")
        else
          assert {:ok, %{rows: [[at]]}} =
                   Cell.query(node.name, {"jobs", "p"}, "SELECT at_ms FROM _atanor_alarms WHERE worker = '@jobs'")

          assert at == Enum.min(due)

          assert {:ok, keys, _} = Store.list(Store.handle(node.name), "alarms/")
          assert Enum.any?(keys, &(String.starts_with?(&1, "alarms/") and String.contains?(&1, "/#{at}/@jobs/jobs.p")))
        end
      after
        Node.stop(node)
      end
    end
  end

  defp no_live_duplicate_unique_keys?(node) do
    {:ok, %{rows: rows}} =
      Cell.query(
        node.name,
        {"jobs", "p"},
        "SELECT worker, unique_key, count(*) FROM _atanor_jobs WHERE unique_key IS NOT NULL GROUP BY worker, unique_key"
      )

    Enum.all?(rows, fn [_worker, _key, count] -> count == 1 end)
  end
end
