defmodule Atanor.Jobs.Schema do
  @moduledoc false
  # Atanor's private per-cell schema (design §15.1). It does not use
  # Alambique's `PRAGMA user_version`: that belongs to the worker's migrations.
  #
  # Version 1 is the presence of the two base tables. A future version adds
  # whatever migration it needs then; there is no schema-version row in a job
  # table, so it cannot appear in a job listing or be purged with a job.
  #
  # The missing tables and indexes are created by one `Alambique.Tx.script/2`, so a new cell pays
  # one change-capture cycle, not one per statement. The job indexes and the cron and undo tables
  # are lazy and found in `sqlite_master`, not in a bookkeeping table.

  alias Alambique.Tx

  @alarms_table "_atanor_alarms"
  @jobs_table "_atanor_jobs"
  @cron_table "_atanor_cron"
  @undo_table "_atanor_undo"
  @due_index "_atanor_jobs_due"
  @done_index "_atanor_jobs_done"

  @alarms """
  CREATE TABLE IF NOT EXISTS #{@alarms_table} (
    worker TEXT PRIMARY KEY,
    at_ms INTEGER NOT NULL,
    payload BLOB NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0
  )
  """

  @jobs """
  CREATE TABLE IF NOT EXISTS #{@jobs_table} (
    id TEXT PRIMARY KEY,
    worker TEXT NOT NULL,
    kind TEXT NOT NULL,
    payload BLOB NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending','running','done','dead','cancelled')),
    due_at_ms INTEGER NOT NULL,
    inserted_at_ms INTEGER NOT NULL,
    claimed_until_ms INTEGER,
    claimed_by TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL,
    unique_key TEXT,
    unique_period TEXT,
    unique_until_ms INTEGER,
    idempotency_key TEXT NOT NULL,
    operation_id TEXT,
    last_error TEXT,
    completed_at_ms INTEGER,
    UNIQUE(worker, unique_key)
  )
  """

  # The due index serves the scan for jobs to run; the done index serves the purge of finished jobs, which
  # would otherwise read every finished row of the cell at each wake.
  @indexes [
    "CREATE INDEX IF NOT EXISTS #{@due_index} ON #{@jobs_table}(state, due_at_ms)",
    "CREATE INDEX IF NOT EXISTS #{@done_index} ON #{@jobs_table}(state, completed_at_ms)"
  ]

  @cron """
  CREATE TABLE IF NOT EXISTS #{@cron_table} (
    id TEXT PRIMARY KEY,
    worker TEXT NOT NULL,
    kind TEXT NOT NULL,
    payload BLOB NOT NULL,
    expression TEXT NOT NULL,
    next_at_ms INTEGER NOT NULL,
    max_attempts INTEGER NOT NULL,
    unique_key TEXT,
    idempotency_key TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    inserted_at_ms INTEGER NOT NULL,
    last_job_id TEXT
  )
  """

  @cron_indexes [
    "CREATE UNIQUE INDEX IF NOT EXISTS _atanor_cron_unique ON #{@cron_table}(worker, unique_key) WHERE unique_key IS NOT NULL AND enabled = 1",
    "CREATE INDEX IF NOT EXISTS _atanor_cron_next ON #{@cron_table}(enabled, next_at_ms)"
  ]

  # The position of a cell before an undoable operation applied (design §15.9).
  @undo """
  CREATE TABLE IF NOT EXISTS #{@undo_table} (
    operation_id TEXT NOT NULL,
    job_id TEXT NOT NULL,
    before_txid INTEGER NOT NULL,
    before_at_ms INTEGER NOT NULL,
    PRIMARY KEY (operation_id, job_id)
  )
  """

  @doc """
  Ensures the base Atanor tables exist and, for each feature in `features`,
  the structures that feature needs. `:indexes`, `:cron` and `:undo` are lazy.
  Everything missing is created by one script.
  """
  @spec ensure!(Tx.t(), [:indexes | :cron | :undo]) :: :ok
  def ensure!(tx, features \\ []) do
    case missing_base(tx) ++ Enum.flat_map(Enum.uniq(features), &missing_feature(tx, &1)) do
      [] -> :ok
      statements -> script!(tx, statements)
    end
  end

  @doc "Whether a lazy feature exists in this cell."
  @spec feature?(Tx.t(), :indexes | :cron | :undo) :: boolean
  def feature?(tx, :indexes) do
    case query(tx, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name IN (?, ?)", [
           @due_index,
           @done_index
         ]) do
      {:ok, %{rows: [[2]]}} -> true
      _ -> false
    end
  end

  def feature?(tx, :cron) do
    exists?(tx, "table", @cron_table)
  end

  def feature?(tx, :undo) do
    exists?(tx, "table", @undo_table)
  end

  @doc """
  Records the position before `operation_id`'s job `job_id`: the TXID of the
  state just before this transaction. The transaction must be isolated
  (`isolated: true`), which gives it a batch of its own. Needs
  `ensure!(tx, [:undo])`.
  """
  @spec record_undo!(Tx.t(), String.t(), String.t(), integer) :: :ok
  def record_undo!(tx, operation_id, job_id, before_at_ms) do
    {:ok, before_txid} = Tx.before(tx)

    run!(
      tx,
      "INSERT INTO #{@undo_table} (operation_id, job_id, before_txid, before_at_ms) VALUES (?, ?, ?, ?)",
      [operation_id, job_id, before_txid, before_at_ms]
    )

    :ok
  end

  @doc "Whether the cell holds a position for `operation_id`."
  @spec undo_recorded?(Tx.t(), String.t()) :: boolean
  def undo_recorded?(tx, operation_id) do
    match?(
      {:ok, %{rows: [_ | _]}},
      Tx.query(tx, "SELECT 1 FROM #{@undo_table} WHERE operation_id = ? LIMIT 1", [operation_id])
    )
  end

  defp missing_base(tx) do
    names =
      case query(tx, "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?)", [
             @alarms_table,
             @jobs_table
           ]) do
        {:ok, %{rows: rows}} -> MapSet.new(rows, fn [name] -> name end)
        {:error, _} -> MapSet.new()
      end

    for {table, sql} <- [{@alarms_table, @alarms}, {@jobs_table, @jobs}], not MapSet.member?(names, table), do: sql
  end

  defp missing_feature(tx, feature) do
    if feature?(tx, feature), do: [], else: feature_statements(feature)
  end

  defp feature_statements(:indexes), do: @indexes
  defp feature_statements(:cron), do: [@cron | @cron_indexes]
  defp feature_statements(:undo), do: [@undo]

  defp script!(tx, statements) do
    case Tx.script(tx, Enum.map_join(statements, ";\n", &String.trim/1)) do
      :ok -> :ok
      {:error, reason} -> Tx.rollback(tx, reason)
    end
  end

  defp exists?(tx, type, name) do
    case query(tx, "SELECT name FROM sqlite_master WHERE type = ? AND name = ?", [type, name]) do
      {:ok, %{rows: [[_]]}} -> true
      _ -> false
    end
  end

  defp query(tx, sql, params) do
    Tx.query(tx, sql, params)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp run!(tx, sql, params) do
    case Tx.execute(tx, sql, params) do
      {:ok, result} -> result
      {:error, reason} -> Tx.rollback(tx, reason)
    end
  end
end
