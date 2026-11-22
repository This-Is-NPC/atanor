defmodule Atanor.JobsTripsTest do
  # Not async: the commit events are VM-wide, and a concurrent test would add its own transactions to the count.
  use ExUnit.Case, async: false

  import Atanor.Test.Await

  alias Atanor.Cell
  alias Atanor.Test.Manifests
  alias AlambiqueTestkit.ManualClock
  alias AtanorTestkit.Node

  @start 1_000_000_000_000

  setup do
    world = ManualClock.new(@start)
    alarms = [clock: {ManualClock, ManualClock.config(world, 0)}, tick_ms: 20]
    node = Node.start(workers: [Manifests.jobs("jobs")], alarms: alarms)
    on_exit(fn -> Node.stop(node) end)
    {:ok, node: node}
  end

  defp run_job(node, payload) do
    query = URI.encode_query(key: "a", payload: payload)
    Req.post!("#{node.url}/enqueue?#{query}", retry: false)

    until(fn ->
      done = Cell.query(node.name, {"jobs", "a"}, "SELECT payload FROM effects WHERE payload = '#{payload}'")
      wake = Cell.query(node.name, {"jobs", "a"}, "SELECT at_ms FROM _atanor_alarms WHERE worker = '@jobs'")
      match?({:ok, %{rows: [[^payload]]}}, done) and match?({:ok, %{rows: []}}, wake)
    end)
  end

  # Cell transactions that committed, counted from the commit events (whatever the uploads they shared).
  defp transactions(agent), do: Agent.get(agent, & &1)

  # The claim re-arms the `@jobs` wake inside its own transaction, not in one more. One
  # job is six write transactions: enqueue, the alarm's claim of the wake, the claim, two in the test
  # handler, the finish.
  test "a job is six cell transactions", %{node: node} do
    run_job(node, "warm")
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    id = "jobs-trips-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:alambique, :cell, :commit],
      fn _, %{transactions: n}, %{result: :ok}, _ -> Agent.update(agent, &(&1 + n)) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    run_job(node, "measured")
    assert transactions(agent) == 6
  end
end
