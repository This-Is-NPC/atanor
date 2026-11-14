# How to use jobs in a cell

**The question:** How do I run work later, retry it, and keep the work inside
the cell's transaction, instead of running it in the request?

This guide stands alone. It uses the native worker API; the WASM equivalent is
in step 6.

## Prerequisites

- A worker with a cell namespace, as in
  [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md).
- Its manifest grants jobs:

  ```json
  "bindings": {
    "cells": {"mail": {"migrations": [[1, "CREATE TABLE mailbox (id INTEGER PRIMARY KEY, dirty INTEGER NOT NULL)"]]}},
    "jobs": true
  }
  ```

- A node started with the usual `{Atanor, ...}` options. The defaults of the
  runner are in [design.md §15](design.md#15-jobs-per-cell-and-bulk-operations);
  change them with the `jobs:` option.

## Steps

1. Implement `handle_job/2`. It runs on the cell owner and gets an
   `Atanor.Jobs.Job` and an `Atanor.Env`:

   ```elixir
   @impl true
   def handle_job(job, env) do
     {:ok, _} = Atanor.Env.execute(env, job.cell, "UPDATE mailbox SET dirty = 0 WHERE id = ?", [job.payload])
     :ok
   end
   ```

   A return of `{:error, reason}` (or a raise) is retried with exponential
   backoff; after `jobs.max_attempts` the job is dead. Only these failures count
   as attempts. An error of the store or the cell (a partition, `store_unavailable`,
   a cell that is overloaded or has no owner) does not: the job waits and runs
   again with the same backoff, up to `jobs.infrastructure_timeout_ms` (one hour
   by default), and then it is dead too.

2. Enqueue in the same transaction as the data. Use
   `Atanor.Jobs.enqueue/4` with the `Alambique.Tx` from `Env.transaction/4`:

   ```elixir
   Atanor.Env.transaction(env, cell, fn tx ->
     {:ok, _} = Alambique.Tx.execute(tx, "UPDATE mailbox SET dirty = 1 WHERE id = ?", [mailbox])
     Atanor.Jobs.enqueue(tx, env, cell, %{kind: "sync", payload: mailbox})
   end)
   ```

   If the transaction rolls back, neither the data nor the job exists. If the
   job cannot be written (for example the cell is full), the transaction rolls
   back too.

3. Enqueue on its own when there is no other write:

   ```elixir
   {:ok, id} = Atanor.Env.enqueue(env, cell, %{kind: "sync", payload: mailbox})
   ```

   A past or omitted `scheduled_at_ms` is due now. A future one is the cell's
   wake-up time; the cell sleeps until then.

4. Choose uniqueness when a second enqueue must not add another job:

   ```elixir
   Atanor.Env.enqueue(env, cell, %{
     kind: "sync",
     payload: mailbox,
     unique_key: "sync:" <> mailbox
   })
   ```

   The default period is `:until_done`: a pending, running or dead job with the
   same `(cell, worker, unique_key)` makes the call return
   `{:ok, {:duplicate, id}}`. Use `unique_period: :forever` or
   `unique_period: {:seconds, 60}` for a longer scope.

5. Make effects outside the cell idempotent. The job id is stable across
   retries and takeovers, and is the default `idempotency_key`:

   ```elixir
   def handle_job(job, env) do
     request = %Atanor.Request{
       method: "POST",
       scheme: "https",
       host: "api.example.com",
       port: 443,
       path: "/sync",
       headers: [{"idempotency-key", job.idempotency_key}],
       body: job.payload
     }

     case Atanor.Env.fetch(env, request) do
       {:ok, _} -> :ok
       {:error, reason} -> {:error, reason}
     end
   end
   ```

6. For WASM, declare `"jobs": true`, import `atanor:cell/jobs@0.1.0` and
   export `atanor:worker/job-handler@0.1.0`. `enqueue` is the direct call;
   `enqueue-batch` takes `sql` statements and the job in one transaction. See
   [how-to-write-a-wasm-worker.md](how-to-write-a-wasm-worker.md).

7. Recurring work uses a five-field UTC cron expression:

   ```elixir
   Atanor.Env.cron(env, cell, %{
     kind: "cleanup",
     payload: "",
     expression: "0 3 * * *"
   })
   ```

   Each fire inserts a normal job; the cron row itself is the schedule. Times
   are UTC and there are no time zones yet (see
   [design §15.4](design.md#154-execution-retries-cron-and-timeouts)).

8. Observe and recover. With the admin API:

   ```sh
   curl -s -H "authorization: Bearer $TOKEN" localhost:5001/jobs
   curl -s -H "authorization: Bearer $TOKEN" localhost:5001/jobs/mail/alice
   curl -s -X POST -H "authorization: Bearer $TOKEN" localhost:5001/jobs/mail/alice/JOB/retry
   ```

   The dashboard's Jobs page shows the same per cell; the Metrics page charts
   `[:atanor, :job, :finished]` and the dead letters.

## Expected results

- The request that enqueues returns without running the job. The job runs
  after the transaction commits, on the cell owner.
- A sleeping cell is woken at the earliest due job time, not on every tick.
- A handler error retries with backoff; a permanently failing job becomes dead
  and remains visible until retried or discarded. An error of the store or the
  cell does not use up attempts; a job that waits longer than
  `jobs.infrastructure_timeout_ms` is dead with a `last_error` that starts with
  `infrastructure: ` (the `dead` telemetry event has `cause: :infrastructure`;
  `:max_attempts` for a failing handler).
- A retried or takeover-repeated job has the same id and idempotency key.

## Troubleshooting

- **`handle_job/2` is missing at activation.** The manifest grants `jobs: true`
  but the module does not export it; the activation is refused with
  `{:missing_callback, module, {:handle_job, 2}}`.
- **`{:error, {:not_granted, :jobs}}`.** The manifest does not grant jobs, or
  the cell's namespace is not under `cells`.
- **`{:error, :queue_full}`, `{:error, :too_many_crons}` or
  `{:error, :too_many_tombstones}`.** A cell is bounded, so one key cannot fill
  the store: `jobs.max_pending` (10 000 pending and running jobs) and
  `jobs.max_cell_bytes` (64 MiB of their payloads) for `queue_full`,
  `jobs.max_cron` (100 schedules) and `jobs.max_tombstones` (10 000 `:forever`
  unique jobs, which nothing purges). Finished jobs drop their payload at once.
  A cron fire into a full queue is skipped and the schedule moves on. Prefer
  `{:seconds, n}` to `:forever` for a unique key built from a request.
- **A job is due now but does not run.** Check `/jobs?cell=namespace.key`; if
  the state is `pending`, the runner has no free slot or the cell owner is
  being taken over. The wake-up is retried; see the `jobs:` options.
- **A job runs more than once.** Delivery is at least once across crashes and
  takeovers. Use the job id or idempotency key at the receiver.
- **A burst of jobs in one cell drains slowly.** A cell runs at most
  `jobs.cell_concurrency` jobs at once (default 1). Raise it, with
  `jobs.worker_concurrency` and `jobs.concurrency` at least as high. When one
  job finishes, the next due job of its cell is claimed in the same
  transaction (`jobs.claim_on_finish`, default true) instead of at the next scan
  (`alarms.tick_ms`): 100 jobs at four at a time drain in about 1 s instead of
  25 s. The cost: while a cell's jobs run, enqueues into that cell share the
  cell's one writer with them and are about 3 times slower (1 460 against 4 500
  jobs/s in the bench), though the jobs complete about 3 times sooner overall
  ([design §12.9](design.md#129-jobs-and-bulk-operations)). Set it to `false`
  to favour enqueue speed.
- **A node was replaced (drained) and its job waited a minute.** A draining node releases the claims of the
  jobs it did not finish when `jobs.release_claims` is true (default), so the node that takes the cell runs
  them within one `alarms.tick_ms`. A job still running when the drain ends (`stop.jobs_ms`) is not
  released: its claim expires at `jobs.claim_ms`. Give each node its own name
  ([design §15.12](design.md#1512-the-claims-of-a-node-that-hands-its-cells-back)).
- **A node died and its job did not run again for minutes.** The jobs a node
  had claimed run again on the node that takes the cell over, once the old lease has ended
  (`jobs.release_claims`, default true), when the cell is used: a request, an
  enqueue or an alarm takes it over. A cell nobody uses waits for the claim
  (`jobs.claim_ms`). A node that comes back after a freeze stops its running
  attempt within `routing.fence_check_ms`, and a node that is cut off from the
  store and its peers stops it when its lease on the cell ends (minus
  Alambique's `skew_margin_ms`), whatever `jobs.release_claims` is. The job may
  have repeated its effects until then. A cell taken over early starts no job
  until the old lease has ended plus the margin, so a released job can wait up
  to `lease_ttl_ms` (30 s by default) before it runs again; set
  `routing.fence_defer_after_takeover: false` to run it at once and accept an
  overlap bounded by the lease left ([design §8.13](design.md#813-a-handler-that-outlives-its-cell),
  [§15.11](design.md#1511-the-claims-of-a-node-confirmed-down)). Each stop emits
  `[:atanor, :handler, :fenced]` ([telemetry.md](telemetry.md)).

## Next steps

- [how-to-run-a-bulk-operation.md](how-to-run-a-bulk-operation.md) runs one job
  across many cells.
- [telemetry.md](telemetry.md) lists the job events.
- [design.md §15](design.md#15-jobs-per-cell-and-bulk-operations) has the
  schema, retry formula, limits and measurements.
