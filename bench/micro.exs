# Micro benchmarks of per-request and per-job costs (design §12.14).
#
#   mise run bench:micro                    # every section
#   mise run bench:micro -- config regex    # some sections
#
# Sections: config (Registry.config/1), wasm (Wasm.settings/0),
# regex (Cell.validate_namespace/1), match (Registry.match/3), jobs (enqueue with a deep queue and the
# statements of a full queue), purge (the purge statement over 100 000 finished jobs).
# Each figure is the median (and minimum) of 7 runs, in nanoseconds per call.

defmodule Bench.Micro do
  alias AtanorTestkit.Node

  @runs 7

  def run(sections) do
    IO.puts("load average: #{File.read!("/proc/loadavg") |> String.split() |> Enum.take(3) |> Enum.join(" ")}")

    node =
      Node.start(data_dir: Path.join(System.tmp_dir!(), "atanor-bench-micro-#{System.unique_integer([:positive])}"))

    try do
      for section <- sections, do: section(section, node)
    after
      Node.stop(node)
    end
  end

  defp section("config", node) do
    name = node.name
    IO.puts("config: #{:erts_debug.flat_size(Atanor.Registry.config(name))} words per copy")
    report("Registry.config/1, 1 process", fn -> Atanor.Registry.config(name) end, 1)
    report("Registry.config/1, 12 processes", fn -> Atanor.Registry.config(name) end, 12)
  end

  defp section("wasm", _node) do
    report("Wasm.settings/0", fn -> Atanor.Wasm.settings() end, 1)
  end

  defp section("regex", _node) do
    report("Cell.validate_namespace/1", fn -> Atanor.Cell.validate_namespace("counter") end, 1)
    report("Cell.id/1", fn -> Atanor.Cell.id({"counter", "cell12"}) end, 1)
  end

  defp section("match", node) do
    name = node.name
    {:ok, _} = Node.deploy(node, Atanor.Test.Manifests.probe("native", routes: [{"127.0.0.1", "/native"}]))
    report("Registry.match/3, hit", fn -> Atanor.Registry.match(name, "127.0.0.1", "/native/echo") end, 1)
    report("Registry.match/3, miss", fn -> Atanor.Registry.match(name, "a.b.example.test", "/x/y/z") end, 1)
  end

  defp section("jobs", _node) do
    node =
      Node.start(
        data_dir: Path.join(System.tmp_dir!(), "atanor-bench-micro-jobs-#{System.unique_integer([:positive])}"),
        workers: [Atanor.Test.Manifests.jobs("jobs")],
        diagnostics: [breadcrumbs: :off],
        jobs: [max_pending: 20_000]
      )

    try do
      cell = {"jobs", "deep"}
      {:ok, _} = Atanor.Cell.query(node.name, cell, "SELECT 1")
      later = System.os_time(:millisecond) + 86_400_000
      payload = String.duplicate("x", 200)

      enqueue = fn n ->
        {us, _} =
          :timer.tc(fn ->
            for _ <- 1..n do
              {:ok, _} =
                Atanor.Jobs.enqueue_direct(node.name, "jobs", cell, %{
                  kind: "bench",
                  payload: payload,
                  scheduled_at_ms: later
                })
            end
          end)

        us / n
      end

      first = enqueue.(300)
      enqueue.(4_400)
      deep = enqueue.(300)
      IO.puts("jobs: enqueue at depth 0: #{round(first)} us, at depth 5000: #{round(deep)} us")

      for {label, sql} <- [
            {"SELECT 1", "SELECT 1"},
            {"count and sum of payload sizes (Jobs.full?/3)",
             "SELECT count(*), coalesce(sum(length(payload)), 0) FROM _atanor_jobs WHERE state IN ('pending','running')"},
            {"count only", "SELECT count(*) FROM _atanor_jobs WHERE state IN ('pending','running')"}
          ] do
        {us, _} = :timer.tc(fn -> for _ <- 1..200, do: {:ok, _} = Atanor.Cell.query(node.name, cell, sql) end)
        IO.puts("jobs: #{label} at depth 5000: #{Float.round(us / 200, 1)} us")
      end
    after
      Node.stop(node)
    end
  end

  defp section("purge", _node) do
    node =
      Node.start(
        data_dir: Path.join(System.tmp_dir!(), "atanor-bench-micro-purge-#{System.unique_integer([:positive])}"),
        workers: [Atanor.Test.Manifests.jobs("jobs")],
        diagnostics: [breadcrumbs: :off]
      )

    try do
      cell = {"jobs", "done"}
      {:ok, _} = Atanor.Jobs.enqueue_direct(node.name, "jobs", cell, %{kind: "bench", payload: "x"})
      now = System.os_time(:millisecond)

      {:ok, _} =
        Atanor.Cell.execute(
          node.name,
          cell,
          "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000) " <>
            "INSERT INTO _atanor_jobs (id, worker, kind, payload, state, due_at_ms, inserted_at_ms, attempts, max_attempts, " <>
            "idempotency_key, completed_at_ms) SELECT 'd' || x, 'jobs', 'k', x'00', 'done', #{now}, #{now}, 1, 3, 'i' || x, #{now} FROM c"
        )

      sql =
        "DELETE FROM _atanor_jobs WHERE id IN (SELECT id FROM _atanor_jobs WHERE state IN ('done','cancelled') " <>
          "AND completed_at_ms < ? AND (unique_period IS NULL OR unique_period != 'forever') LIMIT ?)"

      time = fn ->
        {us, _} =
          :timer.tc(fn ->
            for _ <- 1..50, do: {:ok, _} = Atanor.Cell.execute(node.name, cell, sql, [now - 604_800_000, 100])
          end)

        Float.round(us / 50, 1)
      end

      # The cell already has the done index (Jobs creates it at the first wake): drop it for the first figure.
      {:ok, _} = Atanor.Cell.execute(node.name, cell, "DROP INDEX IF EXISTS _atanor_jobs_done")
      without = time.()

      {:ok, _} =
        Atanor.Cell.execute(node.name, cell, "CREATE INDEX _atanor_jobs_done ON _atanor_jobs(state, completed_at_ms)")

      IO.puts(
        "purge: statement over 100 000 finished jobs, without the done index #{without} us, with it #{time.()} us"
      )
    after
      Node.stop(node)
    end
  end

  # Median of @runs runs of `calls` calls in each of `procs` processes.
  defp report(label, fun, procs) do
    calls = div(200_000, procs)
    for _ <- 1..calls, do: fun.()

    times =
      for _ <- 1..@runs do
        {us, _} =
          :timer.tc(fn ->
            1..procs
            |> Task.async_stream(fn _ -> for _ <- 1..calls, do: fun.() end, max_concurrency: procs, timeout: :infinity)
            |> Stream.run()
          end)

        us * 1000 / (calls * procs)
      end

    median = times |> Enum.sort() |> Enum.at(div(@runs, 2))
    sorted = Enum.sort(times)

    IO.puts(
      "#{String.pad_trailing(label, 36)} #{Float.round(median, 1)} ns/call (min #{Float.round(hd(sorted), 1)}, #{procs} proc)"
    )
  end
end

sections = System.argv()
Bench.Micro.run(if sections == [], do: ~w(config wasm regex match jobs purge), else: sections)
