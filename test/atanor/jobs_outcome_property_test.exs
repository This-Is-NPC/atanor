defmodule Atanor.JobsOutcomeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Jobs
  alias Atanor.Jobs.Job

  @max 4
  @timeout_ms 60_000
  @config %{jobs: %{backoff_ms: 1_000, max_backoff_ms: 8_000, infrastructure_timeout_ms: @timeout_ms}}

  @infra [
    :unknown_outcome,
    :timeout,
    :partitioned,
    :overloaded,
    {:unavailable, :no_quorum},
    {:unavailable, :store_unavailable},
    {:store, :closed},
    {:lost, :n1, :noconnection}
  ]
  @handler [:boom, :handler_timeout, :crashed, {:exit, :killed}, {:bad_return, 1}, "text"]

  # What `finished/7` does to the row: a claim adds an attempt, the outcome may give it back.
  defp apply_outcome(row, result, now) do
    job = %Job{
      id: "j",
      cell: {"jobs", "a"},
      worker: "jobs",
      kind: "t",
      payload: "",
      attempt: row.attempts + 1,
      max_attempts: @max,
      infrastructure_since_ms: row.since
    }

    {state, _error, _due, completed, refund, cause} = Jobs.outcome(result, job, now, @config)
    %{state: state, attempts: job.attempt - refund, since: if(state == "pending", do: completed), cause: cause}
  end

  property "only handler failures consume max_attempts" do
    check all(
            steps <-
              list_of(
                one_of([
                  tuple({constant(:handler), member_of(@handler)}),
                  tuple({constant(:infra), member_of(@infra)})
                ]),
                min_length: 1,
                max_length: 60
              )
          ) do
      {row, failures, _now} =
        Enum.reduce_while(steps, {%{state: "pending", attempts: 0, since: nil}, 0, 0}, fn {kind, reason},
                                                                                          {row, n, now} ->
          # One second apart: the whole run stays inside the infrastructure deadline.
          now = now + 1_000
          next = apply_outcome(row, {:error, reason}, now)
          n = if kind == :handler, do: n + 1, else: n
          assert next.attempts == n
          assert next.state == "dead" == n >= @max
          if next.state == "dead", do: assert(next.cause == :max_attempts)
          {if(next.state == "dead", do: :halt, else: :cont), {next, n, now}}
        end)

      assert row.attempts == failures
    end
  end

  test "an infrastructure error past the deadline is dead with cause infrastructure, attempts untouched" do
    row = %{attempts: 1, since: nil}
    first = apply_outcome(row, {:error, {:unavailable, :no_quorum}}, 1_000_000)
    assert %{state: "pending", attempts: 1, since: 1_000_000} = first

    assert %{state: "pending"} = apply_outcome(first, {:error, :overloaded}, 1_000_000 + @timeout_ms - 1)

    assert %{state: "dead", cause: :infrastructure, attempts: 1} =
             apply_outcome(first, {:error, :overloaded}, 1_000_000 + @timeout_ms)
  end

  test "the delay of successive infrastructure errors grows to max_backoff_ms and never shrinks" do
    # An error every time the job is due again, so each waits for the delay the one before it set.
    {delays, _} =
      Enum.map_reduce(1..10, {0, nil}, fn _, {now, since} ->
        job = %Job{
          id: "j",
          cell: {"jobs", "a"},
          worker: "jobs",
          kind: "t",
          payload: "",
          attempt: 1,
          max_attempts: @max,
          infrastructure_since_ms: since
        }

        {"pending", _, due, since, 1, nil} = Jobs.outcome({:error, :overloaded}, job, now, @config)
        {due - now, {due, since}}
      end)

    assert delays == Enum.sort(delays)
    assert hd(delays) == 1_000
    assert List.last(delays) == 8_000
  end

  test "a handler failure ends the wait on the infrastructure" do
    row = %{attempts: 1, since: 5}
    assert %{state: "pending", since: nil, attempts: 2} = apply_outcome(row, {:error, :boom}, 9)
  end
end
