# Jobs per cell and bulk operations (design §12.9).
#
#   mise run bench:jobs              # 1 000 cells, 2 000 jobs in one cell
#   mise run bench:jobs -- 4000 4000
#
# Measures enqueue-only jobs/s, end-to-end no-op jobs/s (the handler writes two
# rows), and sweep cells/s, on one node over the in-memory store. It also drains
# a burst of 100 jobs in one cell, four at a time, with the default one-second
# scan, once with `claim_on_finish: false` (a scan claims) and once with `true`
# (a finishing job claims the next ones) (design §15.5). The throughput phases
# use `claim_on_finish`; ATANOR_BENCH_CLAIM_ON_FINISH=off turns it off for them.

Code.require_file("load.exs", __DIR__)

defmodule Bench.Jobs do
  alias Atanor.{Cell, Jobs, Sweeps}
  alias Atanor.Bench.Load
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  def burst do
    IO.puts("burst: 100 jobs in one cell, cell_concurrency 4, alarms.tick_ms 1000")

    for claim_on_finish <- [false, true] do
      dir = Path.join(System.tmp_dir!(), "atanor-bench-burst-#{System.unique_integer([:positive])}")

      node =
        Node.start(
          data_dir: dir,
          workers: [Manifests.jobs("jobs")],
          release: [hash_nifs: false],
          diagnostics: [breadcrumbs: :off],
          jobs: [cell_concurrency: 4, worker_concurrency: 8, claim_on_finish: claim_on_finish]
        )

      try do
        {:ok, _} = Cell.query(node.name, {"jobs", "burst"}, "SELECT 1")

        for i <- 1..100 do
          {:ok, _} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", "burst"}, %{kind: "bench", payload: "x#{i}"})
        end

        start = System.monotonic_time(:millisecond)
        await(fn -> count_rows(node, {"jobs", "burst"}, "SELECT count(*) FROM effects") == 100 end, 300_000)
        ms = System.monotonic_time(:millisecond) - start

        IO.puts(
          "  claim_on_finish #{claim_on_finish}: #{ms} ms after the enqueue returned, #{Float.round(ms / 1000, 1)} scans"
        )
      after
        Node.stop(node)
      end
    end

    IO.puts("")
  end

  def run(cells, per_cell) do
    dir = Path.join(System.tmp_dir!(), "atanor-bench-jobs-#{System.unique_integer([:positive])}")

    diagnostics =
      case System.get_env("ATANOR_BENCH_BREADCRUMBS", "off") do
        "off" -> [breadcrumbs: :off]
        "durable" -> [breadcrumbs: :durable, settle_ms: 0]
        "all" -> [breadcrumbs: :all, settle_ms: 0]
      end

    node =
      Node.start(
        data_dir: dir,
        workers: [Manifests.jobs("jobs")],
        release: [hash_nifs: false],
        diagnostics: diagnostics,
        alarms: [tick_ms: 20, timeout_ms: 5_000],
        jobs: [
          concurrency: 64,
          worker_concurrency: 64,
          cell_concurrency: 16,
          claim_on_finish: System.get_env("ATANOR_BENCH_CLAIM_ON_FINISH", "on") != "off",
          max_pending: max(per_cell + 100, 20_000),
          backoff_ms: 100,
          max_backoff_ms: 1_000
        ],
        sweeps: [
          poll_ms: 20,
          lease_ttl_ms: 10_000,
          renew_ms: 2_000,
          cell_timeout_ms: 5_000,
          page_size: 100,
          rate_per_s: 10_000,
          concurrency: 32,
          max_active: 1,
          cell_attempts: 1,
          retry_ms: 10,
          # The benchmark measures dispatch, not the canary wait.
          canary_size: 0
        ]
      )

    try do
      IO.puts("machine: #{Load.machine()}\ncells: #{cells}, jobs in one cell: #{per_cell}\n")

      enqueue_one(node, per_cell)
      await_jobs(node, 120_000)
      enqueue_many(node, cells)
      await_jobs(node, 120_000)
      end_to_end(node, per_cell)
      sweep(node, cells)
      await_jobs(node, 120_000)
    after
      Node.stop(node)
    end
  end

  defp enqueue_one(node, count) do
    {:ok, _} = Cell.query(node.name, {"jobs", "one"}, "SELECT 1")

    {us, _} =
      :timer.tc(fn ->
        Enum.each(1..count, fn i ->
          {:ok, _} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", "one"}, %{kind: "bench", payload: "x#{i}"})
        end)
      end)

    ran = count_rows(node, {"jobs", "one"}, "SELECT count(*) FROM effects")
    IO.puts("enqueue, one cell: #{rate(count, us)} jobs/s (#{count} jobs; #{ran} of them ran meanwhile)")
  end

  defp enqueue_many(node, count) do
    cells = for i <- 1..count, do: "c#{i}"
    Enum.each(cells, fn key -> {:ok, _} = Cell.query(node.name, {"jobs", key}, "SELECT 1") end)

    {us, _} =
      :timer.tc(fn ->
        cells
        |> Task.async_stream(
          fn key ->
            {:ok, _} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", key}, %{kind: "bench", payload: key})
          end,
          max_concurrency: 64,
          timeout: :infinity
        )
        |> Stream.run()
      end)

    IO.puts("enqueue, one job in #{count} cells: #{rate(count, us)} cells/s")
  end

  defp end_to_end(node, count) do
    {:ok, _} = Cell.query(node.name, {"jobs", "e2e"}, "SELECT 1")

    {us, _} =
      :timer.tc(fn ->
        for i <- 1..count do
          {:ok, _} = Jobs.enqueue_direct(node.name, "jobs", {"jobs", "e2e"}, %{kind: "bench", payload: "x#{i}"})
        end

        await(fn -> count_rows(node, {"jobs", "e2e"}, "SELECT count(*) FROM effects") == count end, 120_000)
      end)

    IO.puts("end to end, one cell: #{rate(count, us)} jobs/s (handler writes runs and effects)")
  end

  defp sweep(node, count) do
    cells = for i <- 1..count, do: "s#{i}"
    Enum.each(cells, fn key -> {:ok, _} = Cell.query(node.name, {"jobs", key}, "SELECT 1") end)

    {us, _} =
      :timer.tc(fn ->
        {:ok, op} =
          Sweeps.start(node.name, %{
            "selector" => %{"kind" => "prefix", "prefix" => "jobs.s"},
            "action" => %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("s")},
            "rate_per_s" => 10_000,
            "concurrency" => 32,
            "page_size" => 100
          })

        await(
          fn ->
            case Sweeps.get(node.name, op["id"]) do
              {:ok, %{"state" => "done"}, _} -> true
              _ -> false
            end
          end,
          120_000
        )
      end)

    IO.puts("sweep, one job in #{count} cells: #{rate(count, us)} cells/s")
  end

  # A sweep's `done` means every cell was dispatched, not that every job ran;
  # wait before stopping the node so no handler is cut off by the shutdown.
  defp await_jobs(node, timeout) do
    await(fn -> pending_jobs(node) == 0 end, timeout)
  end

  defp pending_jobs(node) do
    cells =
      Stream.unfold(nil, fn
        :done ->
          nil

        after_cursor ->
          %{cells: cells, next: next} =
            Alambique.cells(Module.concat(node.name, Cells), after: after_cursor, limit: 500)

          {cells, if(next == nil, do: :done, else: next)}
      end)
      |> Enum.flat_map(& &1)

    cells
    |> Task.async_stream(fn id -> pending_in(node, id) end,
      max_concurrency: 32,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(0, fn
      {:ok, count}, acc -> acc + count
      _, acc -> acc
    end)
  end

  defp pending_in(node, id) do
    case Cell.parse(id) do
      {:ok, cell} ->
        case Cell.query(node.name, cell, "SELECT count(*) FROM _atanor_jobs WHERE state IN ('pending','running')") do
          {:ok, %{rows: [[count]]}} -> count
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp count_rows(node, cell, sql) do
    {:ok, %{rows: [[count]]}} = Cell.query(node.name, cell, sql)
    count
  end

  defp rate(count, us), do: round(count / max(us / 1_000_000, 0.000_001))

  defp await(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: raise("bench timed out")
      Process.sleep(20)
      do_await(fun, deadline)
    end
  end
end

[cells, per_cell] =
  case System.argv() do
    [] -> [1_000, 2_000]
    [cells] -> [String.to_integer(cells), 2_000]
    [cells, per_cell] -> [String.to_integer(cells), String.to_integer(per_cell)]
  end

Bench.Jobs.burst()
Bench.Jobs.run(cells, per_cell)
