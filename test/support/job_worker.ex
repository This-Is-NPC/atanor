defmodule Atanor.Test.JobWorker do
  @moduledoc """
  Test worker for jobs. Requests: `/enqueue?key&kind&payload&at&max&unique`,
  `/tx?key` (a write and a job in one transaction), `/cron?key&expr`, and
  `/jobs?key`, `/runs?key`, `/effects?key`. Job payloads `noop` (writes nothing), `fail`, `flaky` and
  `slow`, `own_timeout` and `own_no_quorum` (errors the handler makes up: they count as attempts) exercise retries and timeouts; `heal:<table>` fails with `store_unavailable` until the test puts
  `:healed` in the ETS set `<table>` (public, owned by the test), `unhealed:<dir>` until the file `<dir>/healed` exists; every execution is recorded and effects
  are deduplicated by job id. `track:<ms>:<table>` holds a slot for `<ms>` and
  records how many jobs ran at once and in what order in the ETS table `<table>`
  (a public named set the test owns). `file:<ms>:<dir>` appends `start`, `beat`
  (every 100 ms) and `end` lines to `<dir>/<job id>` outside the cell, so the
  attempts of a job on several nodes can be compared. `pulse:<ms>:<table>` stamps
  `{:pulse, os_ms}` into the ETS bag `<table>` (public, owned by the test) every 5 ms for `<ms>`. `gate:<table>` stores its pid in
  `<table>`, waits for `:go` and then calls `Detector.blocked?/2`.
  """

  @behaviour Atanor.Worker

  alias Alambique.Tx
  alias Atanor.{Env, Jobs, Request, Response}

  @migrations [
    [1, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"],
    [
      2,
      "CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT, attempt INTEGER NOT NULL, payload TEXT)"
    ],
    [3, "CREATE TABLE effects (job_id TEXT PRIMARY KEY, payload TEXT)"]
  ]

  def migrations, do: @migrations

  @impl true
  def handle_request(%Request{method: "POST", path: "/enqueue", query: query}, env) do
    params = URI.decode_query(query)
    key = params["key"] || "a"

    spec = %{
      kind: params["kind"] || "test",
      payload: params["payload"] || "ok",
      scheduled_at_ms: at(params["at"]),
      max_attempts: params["max"] && String.to_integer(params["max"]),
      unique_key: params["unique"],
      unique_period: params["period"] && period(params["period"])
    }

    reply(Env.enqueue(env, {"jobs", key}, spec))
  end

  def handle_request(%Request{method: "POST", path: "/tx", query: query}, env) do
    %{"key" => key} = URI.decode_query(query)

    result =
      Env.transaction(env, {"jobs", key}, fn tx ->
        {:ok, _} = Tx.execute(tx, "INSERT INTO notes (body) VALUES ('committed')")
        Jobs.enqueue(tx, env, {"jobs", key}, %{kind: "tx", payload: "tx"})
      end)

    reply(result)
  end

  def handle_request(%Request{method: "POST", path: "/cron", query: query}, env) do
    %{"key" => key, "expr" => expr} = URI.decode_query(query)
    reply(Env.cron(env, {"jobs", key}, %{kind: "cron", payload: "cron", expression: expr}))
  end

  def handle_request(%Request{method: "GET", path: "/jobs", query: query}, env) do
    %{"key" => key} = URI.decode_query(query)

    case Env.query(
           env,
           {"jobs", key},
           "SELECT id, worker, kind, payload, state, attempts, max_attempts, last_error FROM _atanor_jobs ORDER BY id"
         ) do
      {:ok, %{rows: rows}} -> json(200, %{rows: rows})
      {:error, reason} -> json(500, %{error: inspect(reason)})
    end
  end

  def handle_request(%Request{method: "GET", path: "/runs", query: query}, env) do
    %{"key" => key} = URI.decode_query(query)
    {:ok, %{rows: rows}} = Env.query(env, {"jobs", key}, "SELECT job_id, attempt, payload FROM runs ORDER BY id")
    json(200, %{rows: rows})
  end

  def handle_request(%Request{method: "GET", path: "/effects", query: query}, env) do
    %{"key" => key} = URI.decode_query(query)
    {:ok, %{rows: rows}} = Env.query(env, {"jobs", key}, "SELECT job_id, payload FROM effects ORDER BY job_id")
    json(200, %{rows: rows})
  end

  @impl true
  def handle_job(%{payload: "noop"}, _env), do: :ok

  def handle_job(job, env) do
    payload = job.payload

    {:ok, _} =
      Env.execute(env, job.cell, "INSERT INTO runs (job_id, attempt, payload) VALUES (?, ?, ?)", [
        job.id,
        job.attempt,
        payload
      ])

    {:ok, _} =
      Env.execute(env, job.cell, "INSERT INTO effects (job_id, payload) VALUES (?, ?) ON CONFLICT DO NOTHING", [
        job.id,
        payload
      ])

    case payload do
      "fail" -> {:error, :boom}
      "flaky" when job.attempt < 2 -> {:error, :flaky}
      "slow" -> Process.sleep(:infinity)
      "own_timeout" -> {:error, :timeout}
      "own_no_quorum" -> {:error, :no_quorum}
      "cell_timeout" -> cell_timeout()
      "heal:" <> table -> heal(table)
      "unhealed:" <> dir -> unhealed(dir)
      "track:" <> rest -> track(job, rest)
      "file:" <> rest -> file(job, rest)
      "pulse:" <> rest -> pulse(rest)
      "gate:" <> table -> gate(env, table)
      "raise" -> raise "job failure"
      _ -> :ok
    end
  end

  # An infrastructure error until the test inserts `:healed` into its public ETS set `<table>`.
  defp heal(table) do
    if :ets.lookup(String.to_existing_atom(table), :healed) == [], do: cell_failed(:store_unavailable), else: :ok
  end

  # The same, until the file `<dir>/healed` exists: for tests whose handler runs on another node.
  defp unhealed(dir) do
    if File.exists?(Path.join(dir, "healed")), do: :ok, else: cell_failed(:no_quorum)
  end

  # A cell call of this handler failed as one does when the cell cannot be reached: Atanor marks the process
  # (`Atanor.Cell.mark_unavailable/1`), and the handler passes the failure on as a term of its own.
  defp cell_failed(reason) do
    Atanor.Cell.mark_unavailable(reason)
    {:error, :cell_unreachable}
  end

  # A cell read that timed out, passed on as the bare `:timeout` the call returned.
  defp cell_timeout do
    Process.put({Atanor.Cell, :unanswered}, true)
    {:error, :timeout}
  end

  defp track(job, rest) do
    [ms, table] = String.split(rest, ":", parts: 2)
    table = String.to_existing_atom(table)
    {_, key} = job.cell

    for k <- [key, :all], do: sample(table, k, 1)
    seq = :ets.update_counter(table, :seq, 1, {:seq, 0})
    :ets.insert(table, {{:started, seq}, key, job.id})
    Process.sleep(String.to_integer(ms))
    for k <- [key, :all], do: sample(table, k, -1)
    :ok
  end

  # Every change of the running count is kept, so the maximum is exact.
  defp sample(table, key, delta) do
    n = :ets.update_counter(table, {:running, key}, delta, {{:running, key}, 0})
    :ets.insert(table, {{:sample, System.unique_integer([:monotonic])}, key, n})
  end

  # Announces itself, waits for `:go`, then asks the detector, as a forwarded call does. The test owns the table.
  defp gate(env, table) do
    table = String.to_existing_atom(table)
    :ets.insert(table, {:gate, self()})

    receive do
      :go -> :ets.insert(table, {:blocked, Atanor.Detector.blocked?(env.instance, :gone@nowhere)})
    end

    :ok
  end

  defp pulse(rest) do
    [ms, table] = String.split(rest, ":", parts: 2)
    table = String.to_existing_atom(table)
    until = System.monotonic_time(:millisecond) + String.to_integer(ms)
    pulse_until(table, until)
  end

  defp pulse_until(table, until) do
    if System.monotonic_time(:millisecond) < until do
      :ets.insert(table, {:pulse, System.os_time(:millisecond)})
      Process.sleep(5)
      pulse_until(table, until)
    else
      :ets.insert(table, {:end, System.os_time(:millisecond)})
      :ok
    end
  end

  defp file(job, rest) do
    [ms, dir] = String.split(rest, ":", parts: 2)
    path = Path.join(dir, job.id)
    line = fn what -> File.write!(path, "#{what} #{node()} #{System.os_time(:millisecond)}\n", [:append]) end

    line.("start")
    beats(String.to_integer(ms), line)
    line.("end")
    :ok
  end

  defp beats(ms, line) when ms <= 0, do: line

  defp beats(ms, line) do
    Process.sleep(min(ms, 100))
    line.("beat")
    beats(ms - 100, line)
  end

  defp at(nil), do: nil
  defp at(""), do: nil
  defp at(text), do: String.to_integer(text)

  defp period("forever"), do: :forever
  defp period("until_done"), do: :until_done
  defp period("seconds:" <> n), do: {:seconds, String.to_integer(n)}

  defp reply(result), do: %Response{body: inspect(result)}

  defp json(status, term),
    do: %Response{status: status, headers: [{"content-type", "application/json"}], body: Jason.encode!(term)}
end
