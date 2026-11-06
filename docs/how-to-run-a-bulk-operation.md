# How to run a bulk operation across cells

**The question:** How do I run the same job in many cells, slowly enough not
to overload them, and resume it after a node failure?

This guide stands alone. It uses the admin API, so the node needs `admin:` and
its token ([how-to-use-the-admin-api.md](how-to-use-the-admin-api.md)).

## Prerequisites

- A worker whose manifest grants `jobs: true`, as in
  [how-to-use-jobs.md](how-to-use-jobs.md).
- Its cells exist at least once. A cell enters Alambique's schema index when it
  first wakes; a cell that has never woken is not listed by a sweep.
- The namespace is active on the node that creates the operation, and the
  action worker is active and grants both `jobs` and every namespace the
  selector reads (for a `prefix` selector, the part before the first `.`).

## Steps

**Behaviour change for existing automation:** by default an operation now
dispatches its first 10 cells, then waits `canary_window_ms` (60 s) before it
continues, and it halts if more than 10% of those jobs failed. An operation of
10 cells or fewer is not delayed. To keep the old timing, create it with
`"canary_size": 0`, or set `canary_size: 0` (or a shorter `canary_window_ms`)
under `sweeps:` on the node. Step 4 describes the canary.

1. Start a namespace sweep. It enqueues `kind: "reindex"` in every cell of
   `mail`, at most 25 per second, 8 at a time:

   ```sh
   curl -s -X POST -H "authorization: Bearer $TOKEN" \
     -H "content-type: application/json" \
     -d '{
       "selector": {"kind": "namespace", "namespace": "mail"},
       "action": {
         "worker": "mail",
         "kind": "reindex",
         "payload_base64": ""
       },
       "rate_per_s": 25,
       "concurrency": 8,
       "page_size": 100
     }' \
     localhost:5001/operations
   ```

   The answer is the operation record, including its `id` and `state:
   "running"`. The per-operation `rate_per_s`, `concurrency` and `page_size`
   must not exceed the instance's `sweeps:` values. The instance defaults are
   50 cells/s and 8 in flight; raise `sweeps: [rate_per_s: ..., concurrency:
   ...]` on the nodes before a large sweep (the implementation benchmarks
   10,000 and 32 and reaches about 700 cells/s on a laptop).

2. Use a prefix selector for part of the keys, or an index cell for a list
   owned by the application:

   ```json
   {"selector": {"kind": "prefix", "prefix": "mail.alice."}}
   ```

   ```json
   {
     "selector": {
       "kind": "index",
       "cell": {"namespace": "domains", "key": "example.com"},
       "namespace": "mail",
       "sql": "SELECT key FROM mailboxes WHERE key > ? ORDER BY key LIMIT ?"
     },
     "action": {"worker": "mail", "kind": "reindex", "payload_base64": ""}
   }
   ```

   The index query receives the cursor (empty on the first page) and the page
   size as its two `?` parameters and must return one target key per row.

3. Follow the progress. The counters are saved with each page:

   ```sh
   curl -s -H "authorization: Bearer $TOKEN" localhost:5001/operations/OP_ID
   curl -s -H "authorization: Bearer $TOKEN" localhost:5001/operations
   ```

   The record's `cursor` is the last fully processed cell id (or index key),
   `counters.dispatched` and `counters.skipped` count the cells, and `driver`
   names the node that is currently driving it. The dashboard's Jobs page
   shows the same.

4. Watch the canary. The first 10 cells are a canary. After them the driver
   waits `canary_window_ms` (60 s), reads the job outcomes of those cells
   without waking them, and continues if no more than 10% failed (at least
   `guard_min_cells`, 10, outcomes, or all of a smaller canary). While it
   waits the record shows `canary.until_ms`; when it passes,
   `canary.passed` is `true`. Options of `POST /operations`, with their
   defaults:

   | Option | Default | Meaning |
   | --- | --- | --- |
   | `canary_size` | 10 | cells in the canary; 0 disables it |
   | `canary_gate` | `"auto"` | `"auto"` continues by itself; `"pause"` waits for you |
   | `canary_window_ms` | 60000 | observation after the canary |
   | `canary_timeout_ms` | 300000 | longest wait for the canary's jobs to finish before halting |
   | `guard_window_cells` | 50 | most recent cells whose outcomes are judged |
   | `guard_error_rate` | 0.1 | halt above this share of failed jobs |
   | `guard_min_cells` | 10 | finished jobs needed before the rate counts |
   | `guard_poll_ms` | 5000 | least time between samples |
   | `guard_attempts` | 3 | failed samples in a row before halting |

   Set the same names under `sweeps:` on the node to change the defaults for
   every operation. To judge the canary yourself, create the operation with
   `"canary_gate": "pause"`. After the canary it is `awaiting_confirmation`
   with no driver. Inspect the canary cells (step 7), then:

   ```sh
   curl -s -X POST -H "authorization: Bearer $TOKEN" localhost:5001/operations/OP_ID/continue
   ```

5. Know when the guard stops it. If, during the run, more than
   `guard_error_rate` of the recent finished jobs are `dead`, the state
   becomes `halted` with `halt_reason: "error_rate"`, and `guard` holds the
   last sample (`samples`, `done`, `failed`, `rate`). Jobs already enqueued
   still run; no new cell is dispatched. `halt_reason` can also be
   `canary_timeout` (jobs still pending after `canary_timeout_ms`) or
   `guard_unavailable` (the outcomes could not be read `guard_attempts`
   times). Fix the cause, then `resume` (it forgets the window and accepts
   the canary) or `cancel`.

6. Pause, resume or cancel:

   ```sh
   curl -s -X POST -H "authorization: Bearer $TOKEN" localhost:5001/operations/OP_ID/pause
   curl -s -X POST -H "authorization: Bearer $TOKEN" localhost:5001/operations/OP_ID/resume
   curl -s -X POST -H "authorization: Bearer $TOKEN" localhost:5001/operations/OP_ID/cancel
   ```

   Pause saves the cursor and releases the driver lease; resume starts a new
   driver at that cursor (also for a `halted` operation). Cancel stops
   dispatching, also in `halted` and `awaiting_confirmation`. A job already enqueued in
   a cell stays and runs; the per-cell marker prevents another one.

7. Check one cell's result. Each target cell records the operation id, the
   job id and the outcome:

   ```sh
   curl -s -H "authorization: Bearer $TOKEN" localhost:5001/jobs/mail/alice
   ```

   A completed cell has one job with the operation id and a marker `done`; a
   failed job has `failed` and its last error. `Atanor.Sweeps.sample_outcomes/3`
   returns counts from a sample of those markers; with `cells: [...]` and
   `at: :latest` it reads named cells without waking them, as the guard does.

## Undo and the undo report

**The question this section answers:** how do I put the cells of an operation
back as they were before it?

Atanor can show what an operation changed, and rewind the cells to just before
it. Decide before you start: if you may want to look back, create the
operation with `"undo": true`. A rewind drops the operation **and every write
to the cell after it**, from users and other jobs, so Atanor makes you read a
report first and refuses a cell that was written since.

8. Record positions. Add `"undo": true` to the body of `POST /operations`, or
   set `undo: true` under `sweeps:` on the node and `"undo": false` on the
   operations that do not need it. In each target cell, in the same
   transaction as the job, Atanor stores where the cell stood just before the
   operation: the TXID of the state before it (`before_txid`) and the time
   (`before_at_ms`), in the cell's `_atanor_undo` table. The transaction owns
   its replicated batch, so the position is exact: a write committed before
   the operation is kept by a rewind, and a write after it is dropped. The
   price is one more upload per cell. The table is created in a cell only by
   an operation that asks for undo. A cell that the driver replays after a
   crash keeps its first position. The record shows
   `"undo": {"enabled": true, "positions": 120}`.

9. Ask for the report once the jobs have run (it can run earlier, but then
   the copy at the latest point may not include the job yet):

   ```sh
   curl -s -X POST -H "authorization: Bearer $TOKEN" \
     -H "content-type: application/json" -d '{"mode":"report"}' \
     localhost:5001/operations/OP_ID/undo
   curl -s -H "authorization: Bearer $TOKEN" localhost:5001/operations/OP_ID/undo
   ```

   The first call answers `202` with `{"undo_id": "u-...", "state": "running"}`
   and works in the background on the node that received it. The second
   returns the report, from any node, once `state` is `done`. For each cell
   with a position, the node restores two copies from the store into
   temporary files under `data_dir/undos/OP_ID/`, one at `before_txid` and one
   at the latest uploaded point, compares them, and deletes the copies, also
   when it fails. It reads the live cell only for its position, job state,
   frozen flag and head (`head_txid`), and never writes it.

10. Read the report. One cell:

    ```json
    {"cell": "mail.alice", "before_txid": 411, "before_at_ms": 1790000000000,
     "head_txid": 415, "current_txid": 415,
     "job_state": "done", "frozen": false,
     "restorable": true, "error": null,
     "tables": [{"name": "messages", "before": 120, "current": 121, "changed": true}],
     "host_tables": [{"name": "_atanor_jobs", "before": null, "current": 1, "changed": true}],
     "schema_changed": false}
    ```

    - `tables` are the worker's tables. `before` and `current` are row counts
      (`null` when the table does not exist in that copy). `changed` compares a
      hash of all rows ordered by their columns, so an update that keeps the
      count is `changed: true`, and so is a new column.
    - `host_tables` are Atanor's `_atanor_*` tables, reported apart: they change
      with every job, so a difference there is expected. A rewind keeps them.
    - `schema_changed` compares the normalized definitions of the worker's
      tables and indexes. A cell whose schema version changed since the
      operation cannot be rewound (`schema_differs`).
    - **The `current` side is not the operation alone.** It includes every
      write after the operation, by anyone, up to the last upload
      (`current_txid`). A table that changed is what a rewind would drop,
      with the operation's own rows.
    - `job_state` is the operation's job in that cell. A `pending` or
      `running` job means the cell has not finished changing; the summary
      counts them in `pending_jobs`, and the apply is refused while there are
      any. Ask for a new report later; a finished report is replaced.
    - `restorable: false` has an `error` with a `stage` (`before`, `latest`,
      `timeout`, `locate`, `position` or `task`) and a message. The usual
      reasons are a history that retention removed (`target_not_reached`) and
      a cell whose copies took longer than `sweeps.undo_timeout_ms`. The other
      cells still report.
    - `summary` has `cells` (all the cells the selector lists now),
      `with_position`, `restorable`, `unrestorable`, `pending_jobs` and
      `truncated`. A cell created after the operation has no position and is
      not listed. At most `sweeps.undo_max_cells` (1 000) cells with a
      position are reported; `truncated: true` says there were more, and an
      apply is refused.

11. Rewind the cells. Do it soon after the report: a cell that is written in
    between is left alone.

    ```sh
    curl -s -X POST -H "authorization: Bearer $TOKEN" \
      -H "content-type: application/json" -d '{"mode":"apply"}' \
      localhost:5001/operations/OP_ID/undo
    curl -s -H "authorization: Bearer $TOKEN" localhost:5001/operations/OP_ID/undo
    ```

    The operation must be `done` or `cancelled`. The answer is `202` and the
    same record now has `"mode": "apply"`. For each cell Atanor rewinds it to
    `before_txid` and keeps the `_atanor_*` tables, so the operation's job
    stays `done`, a replay of the operation does not run it again, and the
    cell's other jobs and alarms are untouched. External effects of the jobs
    (mail sent, calls made) are not taken back. While a cell is rewound, calls
    for it get 503 `owner_unreachable`; retry them. Each cell gets an `apply`
    entry:

    ```json
    {"cell": "mail.alice", "apply": {"state": "rewound", "txid": 417, "from": 416, "to": 411,
                                     "kept": ["_atanor_alarms", "_atanor_jobs", "_atanor_undo"]}}
    ```

    | `apply.state` | What happened | What to do |
    | --- | --- | --- |
    | `rewound` | The cell is back at `to`. | Nothing. |
    | `data_written` | Data was written to the cell since the report: `data` is the TXID of its last data commit, `expected` the report's head. A wake is not a write. It was not touched. | Look at it. To rewind it anyway, ask for a new report and apply again. |
    | `failed` | Alambique refused: `behind_retention`, `schema_differs`, `too_large`, `owned`, `mixed_cluster`, or a store error (`error`). | Fix the cause and apply again. |
    | `unknown` | The rewind may have landed (a lost answer, a timeout, a node that died). It is not repeated blindly. | Read the cell, then decide. |

    The `summary` counts the states (`rewound`, `data_written`, `failed`,
    `unknown`, `rewinding`, `skipped`, `waiting`). `state: "done"` means the
    pass ended; the record is the ledger. Call `apply` again after a `failed`
    or `stale` record: it skips the cells already rewound and tries the
    others, so a retry never rewinds a cell twice. A new report keeps the
    entries of the cells already rewound.

12. Tell the workers that follow the cell. A rewind publishes a marker in the
    change feed ([how-to-follow-cell-changes.md](how-to-follow-cell-changes.md#when-a-cell-is-rewound)).

13. For an operation you cannot rewind (a cell written since, a cell too large,
    an operation created without `undo`) repair with an inverse job. Enqueue a
    second operation whose job removes exactly what the first added. The first
    operation's id is in each cell's job (`/jobs/mail/alice`), so the inverse
    job can find its own rows. Run it like any operation, with a canary, and
    check the result with the report's `tables` counts. For a destructive
    operation, restore a copy of the cell with `mix alambique.restore` at the
    `before_txid` of the report, read the earlier rows, and write the repair
    through the worker.

## Expected results

- A cell is dispatched once even if the driver crashes mid-page and the page
  is replayed: the marker makes the second insert a skip, and a replayed cell
  keeps its first position.
- A driver that dies loses its lease; another node claims it after
  `sweeps.lease_ttl_ms` and resumes from the saved cursor.
- Pausing and resuming does not lose a page; the cursor moves only after a
  page finishes.
- An operation of at most `canary_size` cells has no canary check: it is
  dispatched in one go and finishes `done`.
- A `pause` gate stays `awaiting_confirmation` until `continue` or `cancel`,
  also across a node restart.
- `state: "done"` means every listed cell was dispatched. `dispatched +
  skipped` is the number of selected cells; `failed` counts dispatch errors.

## Troubleshooting

- **`400 invalid_operation`.** The selector namespace is not granted on the
  node, the action worker is not active or lacks `jobs` or the namespace in
  its manifest, the action kind is missing, or a per-operation value is
  above the instance's `sweeps:` bound, or a canary or guard option is invalid
  (for example `canary_gate` other than `auto` or `pause`).
- **The operation is `halted`.** Read `halt_reason` and `guard`. List the
  failed jobs with `/jobs/mail/KEY`, fix the worker, and `resume`.
- **The operation is `running` but dispatches nothing for a minute.** It is
  in the canary window (`canary.until_ms` is set). Lower `canary_window_ms`
  or set `canary_size: 0` for small, safe operations.
- **The operation stays `running` with the same cursor.** A cell is
  unavailable while its owner is being taken over; the driver retries the
  page. Check `/jobs?cell=...` and `/nodes`.
- **A cell is missing.** The selector lists stored cells through Alambique's
  schema index; a cell that has not woken since the index exists is missed.
  Wake it first, or run the operation again.
- **`409 undo_not_enabled`.** The operation was created without `undo`. It
  has no positions; they cannot be added afterwards.
- **`409` on `apply`.** `operation_active`: the operation is not `done` or
  `cancelled`. `report_required`: ask for a report and wait for `done`.
  `report_truncated`: raise `sweeps.undo_max_cells`, then make a new report.
  `jobs_active`: a job of the operation is still `pending` or `running`; wait
  for it and make a new report. `already_running`: wait for the record to end.
- **Cells are `data_written` that nobody wrote.** Alambique ignores wakes but
  not a worker that writes in an alarm or a request, nor a migration. Make the
  report and the apply close together, or stop the writer. Right after an
  upgrade of Alambique, a cell whose history predates its data marker can read
  as written once.
- **The report stays `running`.** Each cell has `sweeps.undo_timeout_ms`
  (120 s) and `undo_concurrency` (2) run at once, so a thousand large cells
  take a while. A report not updated for `sweeps.undo_stale_ms` (10 minutes)
  reads `stale`: its node died. Ask again from another node.
- **Every cell is `restorable: false` with `latest`.** The store holds the
  cell only up to a point before the position. The cell has not uploaded yet,
  or its history was removed. Ask again later.
- **Jobs are dispatched but do not run.** This is the job runner, not the
  sweep: see [how-to-use-jobs.md](how-to-use-jobs.md#troubleshooting).

## Next steps

- [how-to-use-jobs.md](how-to-use-jobs.md) for the job handler and retries.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) for the token and
  the other endpoints.
- [design.md §15.6](design.md#156-bulk-operations-sweeps) for the record,
  lease and idempotency model,
  [design.md §15.8](design.md#158-canary-and-error-rate-guard) for the canary and guard, and
  [§15.9](design.md#159-undo-positions) and
  [§15.10](design.md#1510-the-undo-report-and-the-undo) for
  positions, the report and the undo.
