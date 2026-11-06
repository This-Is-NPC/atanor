defmodule Atanor.Jobs do
  @moduledoc """
  Jobs per cell and the managed bulk operations' queue (design §15).

  A job is a row in the cell's SQLite, written in the same transaction as the
  worker's data. The earliest due job is the cell's `@jobs` alarm, a reserved
  row in `_atanor_alarms`; a sleeping cell is woken only when a job is due.
  Delivery is at least once. A job id is stable across retries and takeovers;
  it is the default idempotency key.
  """

  require Logger

  alias Alambique.Tx
  alias Atanor.{Alarms, Cell, Dispatch, Env, Fence, Registry, Store}
  alias Atanor.Jobs.{Cron, Job, Schema, Slots}

  @jobs_worker "@jobs"
  @table "_atanor_jobs"

  @doc "Enqueue a job inside the transaction of a native worker."
  @spec enqueue(Tx.t(), Env.t(), Cell.address(), map) :: {:ok, String.t()} | {:ok, {:duplicate, String.t()}}
  def enqueue(%Tx{} = tx, %Env{} = env, cell, spec) do
    with :ok <- granted(env, cell), do: enqueue(tx, env.instance, Env.worker(env), cell, spec)
  end

  @doc "Enqueue a job inside a transaction, naming the worker directly."
  @spec enqueue(Tx.t(), atom, String.t(), Cell.address(), map) ::
          {:ok, String.t()} | {:ok, {:duplicate, String.t()}}
  def enqueue(%Tx{} = tx, instance, worker, cell, spec), do: tx |> enqueue_tx(instance, worker, cell, spec) |> elem(0)

  # The result and the `@jobs` index entry that the enqueue replaced (`nil` when none), which only a
  # caller that owns its transaction can delete, once it has committed.
  defp enqueue_tx(tx, instance, worker, cell, spec) do
    config = Registry.config(instance)
    now = Alarms.now(config)
    spec = normalize!(spec, config.jobs, now)
    Schema.ensure!(tx)
    if full?(tx, config.jobs, byte_size(spec.payload)), do: Tx.rollback(tx, :queue_full)
    id = new_id(now)

    case unique_conflict(tx, worker, spec, now) do
      {:duplicate, existing} ->
        {{:ok, {:duplicate, existing}}, nil}

      :ok ->
        check_tombstones!(tx, config.jobs, spec)

        case operation_marker(tx, spec, worker, id, now) do
          {:duplicate, existing} ->
            {{:ok, {:duplicate, existing}}, nil}

          :ok ->
            insert!(tx, id, worker, spec, now)
            superseded = arm!(tx, instance, cell, spec.due_at_ms)

            :telemetry.execute([:atanor, :job, :enqueued], %{count: 1}, %{
              instance: instance,
              worker: worker,
              cell: cell,
              kind: spec.kind,
              operation_id: spec.operation_id,
              unique: spec.unique_key != nil,
              node: node()
            })

            {{:ok, id}, superseded}
        end
    end
  end

  defp enqueue_committed(instance, cell, {:ok, {result, superseded}}) do
    delete_superseded(instance, cell, superseded)
    result
  end

  defp enqueue_committed(_instance, _cell, {:error, _} = error), do: error

  # The row now names the new entry, so the old one is not needed. A failed or unconfirmed commit keeps
  # it: the row may still name it, and it expires as stale otherwise.
  defp delete_superseded(_instance, _cell, nil), do: :ok

  defp delete_superseded(instance, cell, {at, nonce}),
    do: Alarms.delete_index(Store.handle(instance), Registry.config(instance), at, @jobs_worker, cell_id!(cell), nonce)

  @doc "Enqueue a job in its own transaction, naming the worker directly."
  @spec enqueue_direct(atom, String.t(), Cell.address(), map) ::
          {:ok, String.t()} | {:ok, {:duplicate, String.t()}} | {:error, term}
  def enqueue_direct(instance, worker, cell, spec) when is_atom(instance) and is_binary(worker) do
    result =
      Cell.transaction(instance, cell, fn tx -> enqueue_tx(tx, instance, worker, cell, spec) end, idempotent: true)

    enqueue_committed(instance, cell, result)
  end

  @doc "Enqueue a job in its own transaction (no worker data to join)."
  @spec enqueue(Env.t(), Cell.address(), map) :: {:ok, String.t()} | {:ok, {:duplicate, String.t()}} | {:error, term}
  def enqueue(%Env{} = env, cell, spec) do
    result =
      Cell.transaction(
        env.instance,
        cell,
        fn tx ->
          case granted(env, cell) do
            :ok -> enqueue_tx(tx, env.instance, Env.worker(env), cell, spec)
            error -> {error, nil}
          end
        end,
        idempotent: true
      )

    enqueue_committed(env.instance, cell, result)
  end

  @doc """
  Registers a recurring job. The cron row is a schedule; each fire inserts a
  normal job with the deterministic idempotency key `<cron id>:<fire ms>`.
  """
  @spec cron(Tx.t(), Env.t(), Cell.address(), map) :: {:ok, String.t()} | {:ok, {:duplicate, String.t()}}
  def cron(%Tx{} = tx, %Env{} = env, cell, spec) do
    with :ok <- granted(env, cell), do: cron(tx, env.instance, Env.worker(env), cell, spec)
  end

  @spec cron(Tx.t(), atom, String.t(), Cell.address(), map) :: {:ok, String.t()} | {:ok, {:duplicate, String.t()}}
  def cron(%Tx{} = tx, instance, worker, cell, spec) do
    config = Registry.config(instance)
    now = Alarms.now(config)
    spec = normalize_cron!(spec, config.jobs, now)
    Schema.ensure!(tx, [:cron])
    check_cron!(tx, config.jobs)
    id = new_id(now)

    case unique_cron(tx, worker, spec, now) do
      {:duplicate, existing} ->
        {:ok, {:duplicate, existing}}

      :ok ->
        {:ok, _} =
          Tx.execute(
            tx,
            "INSERT INTO _atanor_cron (id, worker, kind, payload, expression, next_at_ms, max_attempts, unique_key, idempotency_key, enabled, inserted_at_ms) " <>
              "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)",
            [
              id,
              worker,
              spec.kind,
              {:blob, spec.payload},
              spec.expression,
              spec.next_at_ms,
              spec.max_attempts,
              spec.unique_key,
              spec.idempotency_key || id,
              now
            ]
          )

        arm!(tx, instance, cell, spec.next_at_ms)
        {:ok, id}
    end
  end

  @doc false
  # Called by `Atanor.Alarms` for the reserved `@jobs` row. It claims due jobs
  # inside `Cell.transaction` and starts one supervised task per job.
  @spec run(atom, Cell.address(), integer | nil) :: :ok | {:error, term}
  def run(instance, cell, alarm_at) do
    config = Registry.config(instance)
    now = Alarms.now(config)

    with {:ok, {listed, fired}} <- claim_candidates(instance, cell, config, now),
         candidates =
           Enum.filter(listed, fn [_, worker | _] -> match?({:ok, _}, Registry.deployment(instance, worker)) end),
         {:ok, claimed} <- claim(instance, cell, candidates, config) do
      for {job, lease} <- claimed do
        deployment = deployment!(instance, job.worker)
        start(instance, cell, {job, lease}, deployment, config)
      end

      _ = fired

      delay =
        if (listed != [] and candidates == []) or (candidates != [] and claimed == []), do: config.jobs.wait_ms, else: 0

      case rearm(instance, cell, alarm_at, delay) do
        :ok -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @doc false
  # Makes the jobs that `node` claimed in the cell `id` claimable at once, after this node raised the
  # cell's epoch from `epoch - 1` to `epoch` by taking it over from `node` (design §15.11). The
  # transaction runs on the owner and releases only while the lease still reads `epoch` and names that
  # owner: the node that died is fenced at `epoch`, so every claim of it is older and cannot be live.
  @spec release_claims(atom, String.t(), node, non_neg_integer) ::
          {:ok, non_neg_integer} | :stale | {:error, term}
  def release_claims(instance, id, node, epoch) do
    config = Registry.config(instance)
    by = Atom.to_string(node)

    with {:ok, cell} <- Cell.parse(id),
         {:ok, result} <-
           Alambique.transaction(config.alambique, id, fn tx -> release_tx(tx, instance, cell, id, by, epoch) end) do
      case result do
        {:released, 0, _} ->
          {:ok, 0}

        {:released, count, rearm_result} ->
          apply_rearm(instance, cell, rearm_result)

          :telemetry.execute([:atanor, :job, :released], %{count: count}, %{
            instance: instance,
            cell: cell,
            from: node,
            epoch: epoch,
            node: node()
          })

          # Claim them now instead of at the next scan.
          _ = Dispatch.internal(instance, cell, {:jobs, nil})
          {:ok, count}

        :stale ->
          :stale
      end
    end
  end

  defp release_tx(tx, instance, cell, id, by, epoch) do
    running = "FROM #{@table} WHERE state = 'running' AND claimed_by = ? AND claimed_until_ms > ?"
    now = Alarms.now(Registry.config(instance))

    case Tx.query(tx, "SELECT count(*) " <> running, [by, now]) do
      {:ok, %{rows: [[0]]}} ->
        {:released, 0, :unchanged}

      {:ok, _} ->
        # Read inside the owner's transaction, so a later owner cannot be mistaken for this one.
        case Alambique.lease(Registry.config(instance).alambique, id) do
          {:ok, %{epoch: ^epoch, owner: owner}} when owner == node() ->
            {:ok, %{rows: rows}} =
              Tx.execute(
                tx,
                "UPDATE #{@table} SET claimed_until_ms = ? WHERE id IN (SELECT id " <> running <> ") RETURNING id",
                [
                  now,
                  by,
                  now
                ]
              )

            {:released, length(rows), rearm_tx(tx, instance, cell, nil, 0)}

          _ ->
            :stale
        end

      {:error, reason} ->
        if no_table?(reason), do: {:released, 0, :unchanged}, else: Tx.rollback(tx, reason)
    end
  end

  @doc "The runner's slot counts on this node."
  def stats(instance), do: Slots.stats(instance)

  @doc false
  def page(instance, cell, opts) do
    limit = Keyword.get(opts, :limit, 100)
    state = Keyword.get(opts, :state)
    after_id = Keyword.get(opts, :after)

    {where, params} =
      case state do
        nil -> {"", []}
        state -> {"WHERE state = ?", [to_string(state)]}
      end

    {after_sql, after_params} =
      if is_binary(after_id) do
        {"#{if where == "", do: "WHERE", else: "AND"} id > ?", [after_id]}
      else
        {"", []}
      end

    sql =
      "SELECT id, worker, kind, payload, state, due_at_ms, inserted_at_ms, attempts, max_attempts, last_error, operation_id " <>
        "FROM #{@table} #{where} #{after_sql} ORDER BY id LIMIT ?"

    case Cell.query(instance, cell, sql, params ++ after_params ++ [limit + 1]) do
      {:ok, %{rows: rows}} ->
        {page, rest} = Enum.split(rows, limit)
        {:ok, %{jobs: Enum.map(page, &row/1), next: if(rest == [], do: nil, else: page |> List.last() |> hd())}}

      {:error, reason} ->
        if no_table?(reason), do: {:ok, %{jobs: [], next: nil}}, else: {:error, reason}
    end
  end

  @doc false
  def get(instance, cell, id) do
    sql =
      "SELECT id, worker, kind, payload, state, due_at_ms, inserted_at_ms, attempts, max_attempts, last_error, operation_id " <>
        "FROM #{@table} WHERE id = ?"

    case Cell.query(instance, cell, sql, [id]) do
      {:ok, %{rows: [row]}} -> {:ok, row(row)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> if no_table?(reason), do: {:error, :not_found}, else: {:error, reason}
    end
  end

  @doc "Retries a dead job, resetting its attempts."
  def retry(instance, cell, id) do
    case Cell.transaction(instance, cell, fn tx ->
           case Tx.execute(
                  tx,
                  "UPDATE #{@table} SET state = 'pending', attempts = 0, due_at_ms = ?, claimed_until_ms = NULL, " <>
                    "claimed_by = NULL, last_error = NULL, completed_at_ms = NULL WHERE id = ? AND state = 'dead' RETURNING worker",
                  [Alarms.now(Registry.config(instance)), id]
                ) do
             {:ok, %{rows: [[worker]]}} -> {:ok, worker}
             {:ok, %{rows: []}} -> {:error, :not_dead}
             {:error, reason} -> if no_table?(reason), do: {:error, :not_found}, else: Tx.rollback(tx, reason)
           end
         end) do
      {:ok, {:ok, worker}} ->
        delete_dead_index(instance, cell, id)
        _ = rearm(instance, cell, nil, 0)
        _ = worker
        :ok

      {:ok, {:error, _} = error} ->
        error

      {:error, _} = error ->
        error
    end
  end

  @doc "Discards a dead job (kept as cancelled)."
  def discard(instance, cell, id) do
    case Cell.transaction(instance, cell, fn tx ->
           case Tx.execute(
                  tx,
                  "UPDATE #{@table} SET state = 'cancelled', unique_key = NULL, payload = x'', completed_at_ms = ? WHERE id = ? AND state = 'dead' RETURNING id",
                  [Alarms.now(Registry.config(instance)), id]
                ) do
             {:ok, %{rows: [_ | _]}} -> :ok
             {:ok, %{rows: []}} -> {:error, :not_dead}
             {:error, reason} -> if(no_table?(reason), do: {:error, :not_found}, else: Tx.rollback(tx, reason))
           end
         end) do
      {:ok, :ok} ->
        delete_dead_index(instance, cell, id)
        _ = rearm(instance, cell, nil, 0)
        :ok

      {:ok, {:error, _} = error} ->
        error

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def dead_index_key(cell, id), do: "jobs/dead/#{cell_id!(cell)}/#{id}"

  @doc false
  def cell_id!(cell) do
    {:ok, id} = Cell.id(cell)
    id
  end

  # -- claiming and running --------------------------------------------------

  defp claim_candidates(instance, cell, config, now) do
    Cell.transaction(instance, cell, fn tx ->
      Schema.ensure!(tx, [:indexes])
      cron!(tx, config, now)
      purge!(tx, instance, cell, config, now)
      cell_limit = config.jobs.cell_concurrency

      {:ok, %{rows: [[running]]}} =
        Tx.query(tx, "SELECT count(*) FROM #{@table} WHERE state = 'running' AND claimed_until_ms > ?", [now])

      take = max(cell_limit - running, 0)

      rows =
        if take == 0 do
          []
        else
          sql =
            "SELECT id, worker, kind, payload, due_at_ms, inserted_at_ms, attempts, max_attempts, idempotency_key, operation_id " <>
              "FROM #{@table} WHERE (state = 'pending' AND due_at_ms <= ?) OR (state = 'running' AND claimed_until_ms <= ?) " <>
              "ORDER BY due_at_ms, id LIMIT ?"

          {:ok, %{rows: rows}} = Tx.query(tx, sql, [now, now, min(take, config.jobs.batch_size)])
          rows
        end

      {rows, 0}
    end)
  end

  defp claim(instance, cell, candidates, config) do
    # The node that runs the claim, which awaits the attempt: not the cell owner whose transaction records it.
    by = Atom.to_string(node())

    selected =
      Enum.flat_map(candidates, fn [id, worker | _] = row ->
        case Slots.checkout(instance, worker) do
          :ok -> [{id, worker, row}]
          :none -> []
        end
      end)

    case Cell.transaction(instance, cell, fn tx ->
           # The claim lasts from the moment it is written, not from the start of the scan: a slow cell
           # must not shorten it below the attempt it has to outlast (`jobs.timeout_ms`).
           now = Alarms.now(config)
           lease = now + config.jobs.claim_ms

           # A cell taken over before the old lease ended starts no handler yet (design §8.13).
           selected = if Fence.held?(instance, cell_id!(cell)), do: [], else: selected

           # Runs of one cell can overlap (an alarm and a finishing job): the bound is checked here, where it is serialized.
           {:ok, %{rows: [[running]]}} =
             Tx.query(tx, "SELECT count(*) FROM #{@table} WHERE state = 'running' AND claimed_until_ms > ?", [now])

           room = max(config.jobs.cell_concurrency - running, 0)

           {claimed, _room} =
             Enum.reduce_while(selected, {[], room}, fn
               _, {claimed, 0} ->
                 {:halt, {claimed, 0}}

               {id, _worker, _row}, {claimed, room} ->
                 case Tx.execute(
                        tx,
                        "UPDATE #{@table} SET state = 'running', claimed_until_ms = ?, claimed_by = ?, attempts = attempts + 1 " <>
                          "WHERE id = ? AND ((state = 'pending' AND due_at_ms <= ?) OR (state = 'running' AND claimed_until_ms <= ?)) " <>
                          "RETURNING id, worker, kind, payload, due_at_ms, inserted_at_ms, attempts, max_attempts, idempotency_key, operation_id",
                        [lease, by, id, now, now]
                      ) do
                   {:ok, %{rows: [job]}} -> {:cont, {[{job, lease} | claimed], room - 1}}
                   _ -> {:cont, {claimed, room}}
                 end
             end)

           Enum.reverse(claimed)
         end) do
      {:ok, claimed} ->
        claimed_ids = MapSet.new(claimed, fn {[id | _], _} -> id end)
        for {id, worker, _row} <- selected, not MapSet.member?(claimed_ids, id), do: Slots.release(instance, worker)
        jobs = for {row, lease} <- claimed, do: {job_from_row(row, cell), lease}
        {:ok, jobs}

      {:error, reason} ->
        for {_id, worker, _row} <- selected, do: Slots.release(instance, worker)
        {:error, reason}
    end
  end

  defp start(instance, cell, {job, lease}, deployment, config) do
    started = System.monotonic_time()

    :telemetry.execute([:atanor, :job, :started], %{count: 1}, %{
      instance: instance,
      worker: job.worker,
      deployment: deployment.id,
      cell: cell,
      id: job.id,
      kind: job.kind,
      attempt: job.attempt,
      operation_id: job.operation_id,
      claimed_until_ms: lease,
      node: node()
    })

    # The task takes over the slot the caller holds and gives it back by exiting, however it ends.
    {:ok, pid} =
      Task.Supervisor.start_child(Atanor.Tasks.name(instance), fn ->
        chain? = config.jobs.claim_on_finish and not Slots.closed?(instance)

        outcome =
          case attempt(instance, cell, job, deployment, config) do
            # The node lost the cell: the new owner decides what the job does next.
            :fenced -> :lost
            result -> finished(instance, cell, job, lease, result, started, chain?)
          end

        # The finish transaction claimed the cell's next due job, which takes over this job's slot (design §15.5).
        with {:ok, {row, next_lease}} <- outcome do
          start(instance, cell, {job_from_row(row, cell), next_lease}, deployment, config)
        end
      end)

    Slots.transfer(instance, job.worker, pid)
  end

  defp attempt(instance, cell, job, deployment, config) do
    env = Env.new(instance, deployment)
    task = Task.Supervisor.async_nolink(Atanor.Tasks.name(instance), fn -> Dispatch.execute(env, cell, {:job, job}) end)

    case Task.yield(task, config.jobs.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, :ok}} -> :ok
      {:ok, {:ok, {:error, reason}}} -> {:error, reason}
      {:ok, {:error, :handler_fenced}} -> :fenced
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:bad_return, other}}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp finished(instance, cell, job, lease, result, started, chain?) do
    config = Registry.config(instance)
    now = Alarms.now(config)

    outcome =
      case result do
        :ok -> {"done", nil, nil, now}
        {:error, reason} when job.attempt >= job.max_attempts -> {"dead", error_text(reason), nil, now}
        {:error, reason} -> {"pending", error_text(reason), now + backoff(job.attempt, config), nil}
      end

    {state, error, due, completed} = outcome
    by = Atom.to_string(node())

    case Cell.transaction(instance, cell, fn tx ->
           sql =
             case state do
               "pending" ->
                 "UPDATE #{@table} SET state = 'pending', claimed_until_ms = NULL, claimed_by = NULL, due_at_ms = ?, last_error = ? " <>
                   "WHERE id = ? AND state = 'running' AND claimed_until_ms = ? RETURNING id"

               _ ->
                 "UPDATE #{@table} SET state = ?, claimed_until_ms = NULL, claimed_by = NULL, last_error = ?, completed_at_ms = ?, " <>
                   if(state == "done", do: "payload = x'', ", else: "") <>
                   "unique_key = CASE WHEN unique_period = 'until_done' THEN NULL ELSE unique_key END " <>
                   "WHERE id = ? AND state = 'running' AND claimed_until_ms = ? RETURNING id"
             end

           params =
             case state do
               "pending" -> [due, error, job.id, lease]
               _ -> [state, error, completed, job.id, lease]
             end

           {:ok, result} = Tx.execute(tx, sql, params)
           rows = length(result.rows)
           next = if rows > 0 and chain?, do: claim_next(tx, config, job.worker, now, by)
           rearm_result = if rows > 0, do: rearm_tx(tx, instance, cell, nil, 0), else: :unchanged
           {rows, rearm_result, next}
         end) do
      {:ok, {rows, rearm_result, next}} when rows > 0 ->
        apply_rearm(instance, cell, rearm_result)

        if state == "dead" do
          write_dead_index(instance, cell, job, error, now)

          :telemetry.execute([:atanor, :job, :dead], %{count: 1}, %{
            instance: instance,
            worker: job.worker,
            cell: cell,
            id: job.id,
            kind: job.kind,
            reason: error,
            node: node()
          })
        end

        :telemetry.execute([:atanor, :job, :finished], %{duration: System.monotonic_time() - started}, %{
          instance: instance,
          worker: job.worker,
          cell: cell,
          id: job.id,
          kind: job.kind,
          attempt: job.attempt,
          result: if(state == "done", do: :ok, else: :error),
          reason: error,
          final: state == "dead",
          node: node()
        })

        {:ok, next}

      # The write may have been applied and answered too late: the job may already be pending again.
      {:error, reason} ->
        :telemetry.execute([:atanor, :job, :unconfirmed], %{count: 1}, %{
          instance: instance,
          worker: job.worker,
          cell: cell,
          id: job.id,
          attempt: job.attempt,
          reason: reason,
          node: node()
        })

        :lost

      _ ->
        :lost
    end
  end

  # In the finish transaction: the next due job of the cell, when it is the finished job's worker's (whose
  # slot is handed over) and the cell has room under `cell_concurrency`. Same order as a scan.
  defp claim_next(tx, config, worker, now, by) do
    {:ok, %{rows: [[running]]}} =
      Tx.query(tx, "SELECT count(*) FROM #{@table} WHERE state = 'running' AND claimed_until_ms > ?", [now])

    with true <- running < config.jobs.cell_concurrency,
         {:ok, %{rows: [[id, ^worker]]}} <-
           Tx.query(
             tx,
             "SELECT id, worker FROM #{@table} WHERE (state = 'pending' AND due_at_ms <= ?) OR (state = 'running' AND claimed_until_ms <= ?) " <>
               "ORDER BY due_at_ms, id LIMIT 1",
             [now, now]
           ) do
      lease = now + config.jobs.claim_ms

      {:ok, %{rows: [row]}} =
        Tx.execute(
          tx,
          "UPDATE #{@table} SET state = 'running', claimed_until_ms = ?, claimed_by = ?, attempts = attempts + 1 WHERE id = ? " <>
            "RETURNING id, worker, kind, payload, due_at_ms, inserted_at_ms, attempts, max_attempts, idempotency_key, operation_id",
          [lease, by, id]
        )

      {row, lease}
    else
      _ -> nil
    end
  end

  # -- cron -----------------------------------------------------------------

  defp cron!(tx, config, now) do
    sql =
      "SELECT id, worker, kind, payload, expression, next_at_ms, max_attempts, idempotency_key " <>
        "FROM _atanor_cron WHERE enabled = 1 AND next_at_ms <= ? ORDER BY next_at_ms LIMIT ?"

    rows =
      if Schema.feature?(tx, :cron) do
        {:ok, %{rows: rows}} = Tx.query(tx, sql, [now, config.jobs.batch_size])
        rows
      else
        []
      end

    for [id, worker, kind, payload, expression, next_at, max, key] <- rows do
      case Cron.next_after(expression, now) do
        {:ok, following} ->
          # A fire into a full queue is skipped: the schedule moves on.
          next_id = if not full?(tx, config.jobs, byte_size(payload)), do: new_id(now)

          if next_id do
            {:ok, _} =
              Tx.execute(
                tx,
                "INSERT INTO #{@table} (id, worker, kind, payload, state, due_at_ms, inserted_at_ms, attempts, max_attempts, idempotency_key) " <>
                  "VALUES (?, ?, ?, ?, 'pending', ?, ?, 0, ?, ?)",
                [next_id, worker, kind, {:blob, payload}, now, now, max, "#{key}:#{next_at}"]
              )
          end

          {:ok, _} =
            Tx.execute(
              tx,
              "UPDATE _atanor_cron SET next_at_ms = ?, last_job_id = coalesce(?, last_job_id) WHERE id = ?",
              [following, next_id, id]
            )

          :ok

        {:error, reason} ->
          Logger.warning("atanor: cron #{id} is invalid and is disabled: #{inspect(reason)}")
          {:ok, _} = Tx.execute(tx, "UPDATE _atanor_cron SET enabled = 0 WHERE id = ?", [id])
      end
    end
  end

  # Terminal rows are kept for listing and retry, then removed in bounded
  # batches. A `:forever` unique row is a tombstone and is never purged.
  defp purge!(tx, instance, cell, config, now) do
    done_before = now - config.jobs.retention_ms

    {:ok, _} =
      Tx.execute(
        tx,
        "DELETE FROM #{@table} WHERE id IN (SELECT id FROM #{@table} " <>
          "WHERE state IN ('done','cancelled') AND completed_at_ms < ? AND (unique_period IS NULL OR unique_period != 'forever') LIMIT ?)",
        [done_before, config.jobs.purge_limit]
      )

    if config.jobs.dead_retention_ms != :infinity do
      {:ok, %{rows: purged}} =
        Tx.execute(
          tx,
          "DELETE FROM #{@table} WHERE id IN (SELECT id FROM #{@table} " <>
            "WHERE state = 'dead' AND completed_at_ms < ? AND (unique_period IS NULL OR unique_period != 'forever') LIMIT ?) " <>
            "RETURNING id",
          [now - config.jobs.dead_retention_ms, config.jobs.purge_limit]
        )

      # The index object of a dead job goes with its row; a rolled back purge repeats it, and a delete is idempotent.
      for [id] <- purged, do: delete_dead_index(instance, cell, id)
    end

    :ok
  end

  # -- the internal @jobs alarm ----------------------------------------------

  defp arm!(tx, instance, cell, due) do
    config = Registry.config(instance)
    id = cell_id!(cell)
    current = current_alarm(tx)

    cond do
      current == nil or due < elem(current, 0) ->
        nonce = put_index!(tx, instance, config, due, id)

        {:ok, _} =
          Tx.execute(
            tx,
            "INSERT INTO _atanor_alarms (worker, at_ms, payload, attempts) VALUES (?, ?, ?, 0) " <>
              "ON CONFLICT(worker) DO UPDATE SET at_ms = excluded.at_ms, payload = excluded.payload, attempts = 0",
            [@jobs_worker, due, {:blob, nonce}]
          )

        current

      true ->
        nil
    end
  end

  @doc false
  # Re-arms the @jobs row to the next wake, conditional on `from` when given.
  # Called after a wake, after a retry/discard, and by `finished/6` inside its
  # own transaction so a completed job does not pay a second cell transaction.
  def rearm(instance, cell, from \\ nil, delay \\ 0) do
    result =
      Cell.transaction(instance, cell, fn tx ->
        Schema.ensure!(tx)
        rearm_tx(tx, instance, cell, from, delay)
      end)

    case result do
      {:ok, rearm_result} -> apply_rearm(instance, cell, rearm_result)
      {:error, _} = error -> error
    end
  end

  defp rearm_tx(tx, instance, cell, from, delay) do
    config = Registry.config(instance)
    now = Alarms.now(config)
    id = cell_id!(cell)
    current = current_alarm(tx)
    {current_at, current_nonce} = current || {nil, nil}
    next = next_wake(tx, config, now, delay)
    expected = from || current_at

    cond do
      next == current_at ->
        :unchanged

      # A wake not later than the next one still covers every job, and its entry exists: a scan that claims
      # the entry moves the row first, so a row still at `current_at` is unclaimed (design §12.13).
      from == nil and current_at != nil and next != nil and current_at <= next ->
        :unchanged

      next == nil ->
        {:ok, result} =
          Tx.execute(tx, "DELETE FROM _atanor_alarms WHERE worker = ? AND at_ms = ? RETURNING at_ms", [
            @jobs_worker,
            expected
          ])

        {:deleted, current_at, current_nonce, length(result.rows)}

      current == nil ->
        nonce = put_index!(tx, instance, config, next, id)

        {:ok, _} =
          Tx.execute(
            tx,
            "INSERT INTO _atanor_alarms (worker, at_ms, payload, attempts) VALUES (?, ?, ?, 0)",
            [@jobs_worker, next, {:blob, nonce}]
          )

        {:inserted, next}

      true ->
        nonce = put_index!(tx, instance, config, next, id)

        {:ok, %{rows: rows}} =
          Tx.execute(
            tx,
            "UPDATE _atanor_alarms SET at_ms = ?, attempts = 0, payload = ? WHERE worker = ? AND at_ms = ? RETURNING at_ms",
            [next, {:blob, nonce}, @jobs_worker, expected]
          )

        {:moved, current_at, current_nonce, {next, nonce}, length(rows)}
    end
  end

  defp apply_rearm(instance, cell, result) do
    config = Registry.config(instance)
    id = cell_id!(cell)

    case result do
      :unchanged ->
        :ok

      {:deleted, current, nonce, rows} ->
        if rows > 0 and current,
          do: Alarms.delete_index(Store.handle(instance), config, current, @jobs_worker, id, nonce)

        :ok

      {:inserted, _next} ->
        :ok

      {:moved, current, nonce, {next, new_nonce}, rows} ->
        if rows > 0 do
          if current, do: Alarms.delete_index(Store.handle(instance), config, current, @jobs_worker, id, nonce)
        else
          # Another writer moved the row first and its row names its own entry: the one written here, under
          # a nonce of its own, is referenced by no row.
          Alarms.delete_index(Store.handle(instance), config, next, @jobs_worker, id, new_nonce)
        end

        :ok
    end
  end

  defp current_alarm(tx) do
    case Tx.query(tx, "SELECT at_ms, payload FROM _atanor_alarms WHERE worker = ?", [@jobs_worker]) do
      {:ok, %{rows: [[at, nonce]]}} -> {at, if(nonce in [nil, ""], do: nil, else: nonce)}
      {:ok, %{rows: []}} -> nil
      {:error, reason} -> if no_table?(reason), do: nil, else: Tx.rollback(tx, reason)
    end
  end

  defp next_wake(tx, _config, now, delay) do
    {:ok, %{rows: [[pending]]}} =
      Tx.query(tx, "SELECT min(due_at_ms) FROM #{@table} WHERE state = 'pending'", [])

    {:ok, %{rows: [[running]]}} =
      Tx.query(tx, "SELECT min(claimed_until_ms) FROM #{@table} WHERE state = 'running' AND claimed_until_ms > ?", [now])

    {:ok, %{rows: [[expired]]}} =
      Tx.query(tx, "SELECT count(*) FROM #{@table} WHERE state = 'running' AND claimed_until_ms <= ?", [now])

    cron =
      if Schema.feature?(tx, :cron) do
        {:ok, %{rows: [[at]]}} = Tx.query(tx, "SELECT min(next_at_ms) FROM _atanor_cron WHERE enabled = 1", [])
        at
      end

    due = if expired > 0 or (pending != nil and pending <= now), do: now + delay
    future = if pending != nil and pending > now, do: pending
    candidates = Enum.reject([due, future, running, cron], &is_nil/1)
    if candidates == [], do: nil, else: Enum.min(candidates)
  end

  defp put_index!(tx, instance, config, at_ms, id) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    case Alarms.put_index(Store.handle(instance), config, at_ms, @jobs_worker, id, nonce) do
      :ok -> nonce
      {:error, reason} -> Tx.rollback(tx, {:store, reason})
    end
  end

  # -- rows and validation ---------------------------------------------------

  defp insert!(tx, id, worker, spec, now) do
    {:ok, _} =
      Tx.execute(
        tx,
        "INSERT INTO #{@table} (id, worker, kind, payload, state, due_at_ms, inserted_at_ms, attempts, max_attempts, " <>
          "unique_key, unique_period, unique_until_ms, idempotency_key, operation_id) " <>
          "VALUES (?, ?, ?, ?, 'pending', ?, ?, 0, ?, ?, ?, ?, ?, ?)",
        [
          id,
          worker,
          spec.kind,
          {:blob, spec.payload},
          spec.due_at_ms,
          now,
          spec.max_attempts,
          spec.unique_key,
          spec.unique_period,
          spec.unique_until_ms,
          spec.idempotency_key || id,
          spec.operation_id
        ]
      )

    :ok
  end

  defp operation_marker(_tx, %{operation_id: nil}, _worker, _id, _now), do: :ok

  defp operation_marker(tx, spec, _worker, _id, _now) do
    case Tx.query(tx, "SELECT id FROM #{@table} WHERE operation_id = ? LIMIT 1", [spec.operation_id]) do
      {:ok, %{rows: [[existing]]}} -> {:duplicate, existing}
      {:ok, %{rows: []}} -> :ok
      {:error, reason} -> Tx.rollback(tx, reason)
    end
  end

  defp unique_conflict(_tx, _worker, %{unique_key: nil}, _now), do: :ok

  defp unique_conflict(tx, worker, spec, now) do
    {:ok, %{rows: rows}} =
      Tx.query(tx, "SELECT id, state, unique_until_ms FROM #{@table} WHERE worker = ? AND unique_key = ?", [
        worker,
        spec.unique_key
      ])

    case rows do
      [] ->
        :ok

      [[id, state, until_ms]] ->
        if state in ["done", "cancelled"] or (until_ms != nil and until_ms <= now) do
          {:ok, _} = Tx.execute(tx, "UPDATE #{@table} SET unique_key = NULL WHERE id = ?", [id])
          :ok
        else
          {:duplicate, id}
        end
    end
  end

  defp unique_cron(tx, worker, spec, _now) do
    if spec.unique_key == nil do
      :ok
    else
      case Tx.query(tx, "SELECT id FROM _atanor_cron WHERE worker = ? AND unique_key = ? AND enabled = 1", [
             worker,
             spec.unique_key
           ]) do
        {:ok, %{rows: [[id]]}} -> {:duplicate, id}
        {:ok, %{rows: []}} -> :ok
      end
    end
  end

  # The pending and running jobs are at `max_pending`, or adding `size` bytes of payload passes `max_cell_bytes`.
  defp full?(tx, config, size) do
    {:ok, %{rows: [[count, bytes]]}} =
      Tx.query(
        tx,
        "SELECT count(*), coalesce(sum(length(payload)), 0) FROM #{@table} WHERE state IN ('pending','running')",
        []
      )

    count >= config.max_pending or bytes + size > config.max_cell_bytes
  end

  defp check_cron!(tx, config) do
    {:ok, %{rows: [[count]]}} = Tx.query(tx, "SELECT count(*) FROM _atanor_cron", [])
    if count >= config.max_cron, do: Tx.rollback(tx, :too_many_crons)
  end

  # A `:forever` row is never purged, so the cell holds at most `max_tombstones` of them.
  defp check_tombstones!(tx, config, %{unique_period: "forever"}) do
    {:ok, %{rows: [[count]]}} = Tx.query(tx, "SELECT count(*) FROM #{@table} WHERE unique_period = 'forever'", [])
    if count >= config.max_tombstones, do: Tx.rollback(tx, :too_many_tombstones)
  end

  defp check_tombstones!(_tx, _config, _spec), do: :ok

  defp normalize!(spec, config, now) do
    kind = spec[:kind] || spec["kind"]
    payload = spec[:payload] || spec["payload"] || ""
    scheduled = spec[:scheduled_at_ms] || spec["scheduled_at_ms"] || now
    max_attempts = spec[:max_attempts] || spec["max_attempts"] || config.max_attempts
    unique_key = spec[:unique_key] || spec["unique_key"]
    period = spec[:unique_period] || spec["unique_period"] || :until_done
    idempotency = spec[:idempotency_key] || spec["idempotency_key"]
    operation = spec[:operation_id] || spec["operation_id"]

    unless is_binary(kind) and kind != "" and byte_size(kind) <= 100,
      do: raise(ArgumentError, "a job kind is a non-empty string of at most 100 bytes")

    unless is_binary(payload) and byte_size(payload) <= config.max_payload_bytes,
      do: raise(ArgumentError, "a job payload must be a binary of at most #{config.max_payload_bytes} bytes")

    unless is_integer(scheduled), do: raise(ArgumentError, "a job's scheduled_at_ms must be an integer")

    unless is_integer(max_attempts) and max_attempts in 1..config.max_attempts//1,
      do: raise(ArgumentError, "invalid job max_attempts")

    unless unique_key == nil or (is_binary(unique_key) and byte_size(unique_key) <= 200),
      do: raise(ArgumentError, "invalid unique_key")

    unless idempotency == nil or (is_binary(idempotency) and byte_size(idempotency) <= 200),
      do: raise(ArgumentError, "invalid idempotency_key")

    unless operation == nil or (is_binary(operation) and byte_size(operation) <= 100),
      do: raise(ArgumentError, "invalid operation_id")

    {period, until_ms} = period!(period, now)

    %{
      kind: kind,
      payload: payload,
      due_at_ms: scheduled,
      max_attempts: max_attempts,
      unique_key: unique_key,
      unique_period: period,
      unique_until_ms: until_ms,
      idempotency_key: idempotency || nil,
      operation_id: operation
    }
  end

  defp normalize_cron!(spec, config, now) do
    base = normalize!(spec, config, now)
    expression = spec[:expression] || spec["expression"]

    unless is_binary(expression), do: raise(ArgumentError, "a cron job needs an expression")

    case Cron.next_after(expression, now) do
      {:ok, next} -> Map.merge(base, %{expression: expression, next_at_ms: next})
      {:error, reason} -> raise ArgumentError, "invalid cron expression: #{inspect(reason)}"
    end
  end

  defp period!(:until_done, _now), do: {"until_done", nil}
  defp period!("until_done", _now), do: {"until_done", nil}
  defp period!(:forever, _now), do: {"forever", nil}
  defp period!("forever", _now), do: {"forever", nil}
  defp period!({:seconds, n}, now) when is_integer(n) and n > 0, do: {"seconds", now + n * 1000}
  defp period!([:seconds, n], now) when is_integer(n) and n > 0, do: {"seconds", now + n * 1000}
  defp period!(%{"seconds" => n}, now) when is_integer(n) and n > 0, do: {"seconds", now + n * 1000}
  defp period!(other, _now), do: raise(ArgumentError, "invalid unique_period: #{inspect(other)}")

  defp backoff(attempt, config),
    do: min(config.jobs.backoff_ms * Integer.pow(2, attempt - 1), config.jobs.max_backoff_ms)

  defp error_text(nil), do: nil
  defp error_text(reason) when is_binary(reason), do: String.slice(reason, 0, 1000)
  defp error_text(reason), do: String.slice(inspect(reason), 0, 1000)

  defp new_id(now) do
    Integer.to_string(now, 36)
    |> String.pad_leading(9, "0")
    |> Kernel.<>(Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
  end

  defp job_from_row([id, worker, kind, payload, due, inserted, attempts, max, key, operation], cell) do
    %Job{
      id: id,
      cell: cell,
      worker: worker,
      kind: kind,
      payload: payload,
      attempt: attempts,
      max_attempts: max,
      idempotency_key: key || id,
      operation_id: operation,
      due_at_ms: due,
      inserted_at_ms: inserted
    }
  end

  defp deployment!(instance, worker) do
    {:ok, deployment} = Registry.deployment(instance, worker)
    deployment
  end

  defp row([id, worker, kind, payload, state, due, inserted, attempts, max, error, operation]) do
    %{
      id: id,
      worker: worker,
      kind: kind,
      payload: payload,
      state: state,
      due_at_ms: due,
      inserted_at_ms: inserted,
      attempts: attempts,
      max_attempts: max,
      last_error: error,
      operation_id: operation
    }
  end

  defp write_dead_index(instance, cell, job, error, now) do
    body =
      Jason.encode!(%{
        id: job.id,
        cell: cell_id!(cell),
        worker: job.worker,
        kind: job.kind,
        reason: error,
        at_ms: now
      })

    _ = Store.put(Store.handle(instance), dead_index_key(cell, job.id), body)
    :ok
  end

  defp delete_dead_index(instance, cell, id), do: Store.delete(Store.handle(instance), dead_index_key(cell, id))

  defp no_table?(reason) when is_binary(reason), do: String.contains?(reason, "no such table")
  defp no_table?(_), do: false

  defp granted(%Env{deployment: %{manifest: manifest}}, {ns, _}) do
    cond do
      not manifest.jobs -> {:error, {:not_granted, :jobs}}
      not is_map_key(manifest.cells, ns) -> {:error, {:not_granted, {:cell, ns}}}
      true -> :ok
    end
  end
end
