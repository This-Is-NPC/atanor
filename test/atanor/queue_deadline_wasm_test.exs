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
    capture([[:atanor, :http, :reject], [:atanor, :wasm, :invoke]])

    responses =
      1..@spinners
      |> Enum.map(fn _ -> Task.async(fn -> request(node, "spin") end) end)
      |> Task.await_many(30_000)

    queue_timeouts = for %{status: 503, body: %{"reason" => "queue_timeout"}} <- responses, do: :queue_timeout

    assert length(queue_timeouts) >= 4, inspect(for r <- responses, do: r.status)

    # The node times each call from its admission to its result, so a slow client or connection does not
    # count. A call gave up at the deadline if it ended before any spinner released its thread.
    calls = invoked()
    {refused, ran} = Enum.split_with(calls, &(&1.result == :overloaded))
    assert length(refused) == length(queue_timeouts), inspect(calls)
    assert ran != []
    assert Enum.max(Enum.map(refused, & &1.duration)) < Enum.min(Enum.map(ran, & &1.duration)), inspect(calls)

    assert_receive {:telemetry, [:atanor, :http, :reject], _, %{reason: :queue_timeout}}
    assert Admission.stats(node.name).refused.queue_timeout == length(queue_timeouts)
  end

  # The calls the node ended, as their result and duration. Each ends before its response is sent.
  defp invoked(calls \\ []) do
    receive do
      {:telemetry, [:atanor, :wasm, :invoke], %{duration: duration}, %{result: result}} ->
        invoked([%{result: result, duration: duration} | calls])
    after
      0 -> calls
    end
  end
end
