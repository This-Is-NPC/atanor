defmodule Atanor.QueueDeadlineWasmTest do
  @moduledoc """
  A call that waits for a thread of the guest pool longer than `http: [queue_wait_ms:]` is a 503 `queue_timeout`
  (design §7.1, §14.2), where the pool alone would let it wait `wasm: [queue_wait_ms:]` and then run it.
  """
  # Not async: the guests fill the node-wide pool, which would 503 other tests.
  use ExUnit.Case, async: false

  import Atanor.Test.WasmCase

  alias Atanor.Admission

  @spinners 12

  test "calls queued behind spinning guests are refused at the deadline" do
    # The pool has 4 threads (test_helper) and each spinner holds one for the 300 ms of its CPU limit.
    node = start([{"spin", "spin", limits: %{"timeout_ms" => 3000}}], http: [queue_wait_ms: 100])
    capture([[:atanor, :http, :reject]])

    responses =
      1..@spinners
      |> Enum.map(fn _ -> Task.async(fn -> timed(fn -> request(node, "spin") end) end) end)
      |> Task.await_many(30_000)

    queue_timeouts =
      for {%{status: 503, body: %{"reason" => "queue_timeout"}}, ms} <- responses, do: ms

    assert length(queue_timeouts) >= 4, inspect(for {r, ms} <- responses, do: {r.status, ms})
    # They gave up at the deadline, not when a thread came free after the 300 ms of the spinners.
    assert Enum.all?(queue_timeouts, &(&1 < 280)), inspect(queue_timeouts)
    assert_receive {:telemetry, [:atanor, :http, :reject], _, %{reason: :queue_timeout}}
    assert Admission.stats(node.name).refused.queue_timeout == length(queue_timeouts)
  end

  defp timed(fun) do
    {us, response} = :timer.tc(fun)
    {response, div(us, 1000)}
  end
end
