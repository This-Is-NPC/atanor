# How to rehearse a migration on copies of real cells

**The question:** I published a new version of a worker with new cell
migrations. How do I find out, before I activate it, whether they apply to my
real data?

This guide builds on [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md):
you publish the package, rehearse it, and only then activate it. It needs the
admin API ([how-to-use-the-admin-api.md](how-to-use-the-admin-api.md)).

A rehearsal restores copies of a sample of cells into a temporary directory,
applies the package's migrations to the copies, and reports what happened. It
does not wake, lease, migrate or write a live cell, and publishes nothing to
the change feed. It is a check on a sample, not a proof for every cell.

## Prerequisites

- A node started with the `admin:` option, as in the admin API guide. The
  examples use the token `demo-token` and the admin port 5010.
- Cells in the store. The rehearsal reads what the store holds, not what is
  in a running cell's memory, and samples the cells that have woken at least
  once.
- The new package published but not activated:

  ```sh
  atanor deploy --manifest atanor-v2.json
  ```

  ```text
  package 4ae1c188910b5e3ab17f95a39ef6125f50f255fde6c14fa402516fc24f4dc3df (notes, native, N bytes)
  ```

## Steps

1. Start the rehearsal with the worker name and the package id. The node that
   answers runs it.

   ```sh
   curl -s -X POST -H "authorization: Bearer demo-token" -H "content-type: application/json" \
     -d '{"worker":"notes","id":"4ae1c188910b5e3ab17f95a39ef6125f50f255fde6c14fa402516fc24f4dc3df"}' \
     localhost:5010/rehearsals
   ```

   ```json
   {"id":"h-1793475888683-13754174","package":"4ae1c188910b5e3ab17f95a39ef6125f50f255fde6c14fa402516fc24f4dc3df","state":"running","worker":"notes"}
   ```

   The answer is 202. The package must be in the store and belong to the
   worker (404 `package_not_found`, 400 `wrong_worker`). Only one rehearsal runs
   at a time (409 `already_running`).

2. Read the report until `state` is no longer `running`. `progress` says how
   many cells are done.

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/rehearsals/h-1793475888683-13754174
   ```

   The `summary` of a rehearsal of three cells (shortened):

   ```json
   {"namespaces":1,"scanned":3,"sampled":3,"ok":3,"failed":0,"skipped":0,
    "schema_consistent":true,"max_duration_ms":42,
    "versions":{"notes":{"from_min":1,"from_max":1,"to":2}},
    "sampling":{"notes":{"scanned":3,"sampled":3,"max_scan_reached":false}}}
   ```

   `state` is `done` when every sampled cell migrated, `failed` when one did
   not (or `strict_schema` found different schemas), `cancelled` after step 4,
   and `stale` when the node died (see below).

3. Read the cells. Each entry of `cells` has:

   | Field | Meaning |
   | --- | --- |
   | `outcome` | `migrated`, `nothing_pending` (already at the candidate's version), `empty` (nothing to restore) or `failed` |
   | `from_version`, `to_version`, `applied` | the versions the copy went through |
   | `row_counts_before`, `row_counts_after` | rows per user table; `row_count_decreased` lists tables that lost rows (reported, not a failure: a migration may delete on purpose) |
   | `schema_hash` | a hash of the schema after the migrations; the `summary` says whether the cells of a namespace agree (`schema_groups` counts them) |
   | `integrity` | `ok`, or what SQLite's `quick_check` (or `integrity_check`) found |
   | `duration_ms`, `version_durations_ms` | time of the cell and of each version |
   | `error` | the `stage` (`restore`, `open`, `migration`, `check`, `timeout`), the `version` and the SQLite message |
   | `frozen` | whether Alambique's quarantine froze the cell |

   Look first at `summary.failed` and at `error` of the failed cells, then at
   `row_count_decreased` and `schema_consistent`. A `schema_consistent: false`
   means cells of one namespace end with different schemas, for example
   because a worker created a table at run time; `schema_groups` shows how many
   cells have each hash. Ask for `"strict_schema": true` to make that a
   failure.

4. To stop a rehearsal, cancel it. It stops before the next cell; the cells
   already done stay in the report.

   ```sh
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/rehearsals/ID/cancel
   ```

   A rehearsal that is not running answers 409 `invalid_state`.

5. List the recent reports, newest first (`?limit=` as for the other lists).

   ```sh
   curl -s -H "authorization: Bearer demo-token" 'localhost:5010/rehearsals?limit=5'
   ```

6. If the report is clean, activate the package
   ([how-to-deploy-a-worker.md](how-to-deploy-a-worker.md), step 5).

## What you can change

The body of the request can add `sample_size`, `max_cells`, `timeout_ms`,
`seed`, `strict_schema` and `integrity_check` (`"quick_check"` or
`"integrity_check"`). A request can lower `sample_size`, `max_cells` and
`timeout_ms`, not raise them: the node's `rehearsal:` option sets the bounds.
A bound that is exceeded is 400 `invalid_rehearsal`.

```sh
curl -s -X POST -H "authorization: Bearer demo-token" \
  -d '{"worker":"notes","id":"4ae1c188...","sample_size":5,"seed":7}' localhost:5010/rehearsals
```

| Option of `rehearsal:` | Default | Meaning |
| --- | --- | --- |
| `sample_size` | 10 | cells sampled per namespace |
| `max_cells` | 100 | cells sampled in total |
| `max_scan` | 10 000 | ids scanned per namespace before the sample is taken from what was seen |
| `page_size` | 1 000 | ids per page of the cell list |
| `concurrency` | 2 | cells restored and migrated at once |
| `timeout_ms` | 120 000 | one cell's restore, migrations and check |
| `integrity_check` | `:quick_check` | `:quick_check` or `:integrity_check` (slower, checks more) |
| `strict_schema` | `false` | different schemas in a namespace fail the rehearsal |
| `seed` | `nil` | sampling seed; `nil` picks one and records it in `options.seed` |
| `dir` | `nil` | temporary directory; `nil` is `data_dir/rehearsals` |
| `stale_ms` | 600 000 | a `running` record not updated for this long reads as `stale` |
| `retention_ms` | 604 800 000 | reports older than this are removed (7 days) |

The sample takes `sample_size` cells at random from each namespace of the
package that has migrations, in order, until `max_cells`. Rehearse again with
the `seed` of a report to get the same cells. The sample is not a snapshot:
cells created after the listing are missed.

## What the rehearsal does not touch

The report is one object under `<prefix>/rehearsals/<id>` in the metadata
store, so any node reads it. The cells are restored with Alambique's
point-in-time restore at the latest state, into `dir/<id>/`, which is removed
when the task ends (a directory a killed node left behind is removed by the
next rehearsal on that node once it is older than `stale_ms`). The live cells
keep no lease from it, are not woken, and the change feed does not move.

## Troubleshooting

- **400 `invalid_rehearsal`.** The message says which field. You asked for
  more than the node's bound, or sent a field that does not exist.
- **404 `package_not_found`.** Publish the package first; the id is the
  SHA-256 that `atanor deploy` printed.
- **409 `already_running`.** Another rehearsal is running, here or on another
  node. Wait, cancel it, or wait `stale_ms` if its node died.
- **503 `store_unavailable`.** The node cannot reach the metadata store. The
  rehearsal did not start; try again when the store answers.
- **`state: "stale"`.** The node that ran the rehearsal stopped or lost the
  store before it wrote the result. Nothing resumes it. Start another one.
- **`nothing_to_rehearse`.** The package has no namespace with migrations.
- **`sampled: 0` for a namespace you expect.** Only cells that have woken
  since Alambique's schema index exists are listed. A namespace with few cells
  is read completely; check `scanned`.
- **A failed cell with `stage: "timeout"`.** The cell took longer than
  `timeout_ms`. A large cell or a heavy migration may need a higher bound on
  the node.

## Next steps

- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) to activate the
  package and roll back.
- [design.md §17.3](design.md#173-migration-rehearsal) for how it works and
  what it does not cover.
- [what-does-not-work.md](what-does-not-work.md) for the limits of the sample.
