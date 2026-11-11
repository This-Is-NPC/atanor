# Configuring an Atanor instance

**The question:** Which options does an Atanor instance take, what do they
bound, and where is each one explained?

This page is a map. The full list of options, with defaults, is the
documentation of the `Atanor` module (`h Atanor` in IEx); an invalid option
raises `ArgumentError` when the instance starts. Contributors find the reasons
in [design.md](design.md).

## The instance

Add one instance to your supervision tree:

```elixir
children = [
  {Atanor,
   name: MyApp.Atanor,
   store: {Alambique.Store.S3, s3_config},
   prefix: "myapp",
   data_dir: "/var/lib/myapp/cells",
   port: 4000,
   hosts: %{"notes" => ["notes.example.com"]}}
]
```

| Option | What it sets |
| --- | --- |
| `store:`, `prefix:` | The S3-compatible store that holds both the cells and Atanor's own metadata under `prefix:`. `placement:` with `meta_store:` replaces it when cells live in several places. |
| `data_dir:` | The directory of the local copies of cells. One instance holds it (a lock on `data_dir/lock`) on a case-sensitive file system; a second instance, or another file system, fails to start with `data_dir_in_use` or `data_dir_case_insensitive`, logged by the node. |
| `secrets:` | The values of the secrets the workers are granted. |
| `hosts:`, `listeners:` | The routes a manifest may activate. `listeners: %{"smtp" => 2525}` opens that port while a worker claims it. The long form adds `tls_mode:` and `tls:`, `protocol: :ranch` and `ip:` (the address to bind); a Ranch protocol gets the listener name as `:atanor_listener`. |
| `allow_private_hosts:` | Which private addresses outbound HTTP may reach. |
| `package:` | The size limits of `atanor.json` (`max_manifest_bytes`, 262,144) and of a WASM component (`max_component_bytes`, 8,388,608). |
| `auth:` | The issuer, audience and scopes per route ([OIDC guide](how-to-protect-a-route-with-oidc.md)). |
| `detector:`, `takeover:`, `routing:` | Failure detection, takeover and routing ([design §8.6 to §8.12](design.md#86-classifying-failures)). |
| `stop:` | The drain: `drain_timeout_ms` 15 000 (one cell hibernating and releasing its lease), `drain_concurrency` 64 (cells at once), `shutdown_ms` 75 000 (the whole drain, not below `drain_timeout_ms`) and `exit` true (`atanor drain` and `POST /drain` stop the node when the cells are back; false leaves it running, drained) and `sigterm` `:drain` (SIGTERM drains with the listeners open, then stops the VM; `:stop` stops at once). `jobs_ms` 15 000, `connections_ms` 15 000, `sweeps_ms` 5 000 and `tasks_ms` 5 000 bound the other steps of a stop ([design §8.11](design.md#811-draining-and-stopping-gracefully)). |
| `http:` | `retry_after_s` 1 is the `Retry-After` of every 503, `held_elsewhere` included ([design §8.4](design.md#84-when-the-node-is-lost)). |
| `hot_cells:`, `tags:`, `affinity:` | The opt-in placement of hot cells ([guide](how-to-place-hot-cells.md)). |
| `diagnostics:` | Crash breadcrumbs and reports ([guide](how-to-diagnose-a-crash.md)). |
| `:dashboard` | The read-only dashboard ([guide](how-to-open-the-dashboard.md)). |

The node holds no workers of its own. It applies the *heads* it finds in the
store: each worker's head names the package, identified by its hash, that is
active. The `atanor` command moves heads through the admin API with a scoped
token, so deployers never hold the bucket credentials
([how to deploy a worker](how-to-deploy-a-worker.md)).

## What a manifest may grant

What a manifest grants is bounded by the other side's consent
([design §3.3](design.md#33-what-a-manifest-may-grant)). A cell namespace
belongs to the first worker that activated it (`namespaces:` shares or
reassigns it). A worker can be called only by the callers its manifest
(`callable_by`) or `callers:` lists. `http_allow:`, `modules:` and a listener's
`workers:` bound what a deploy token can grant itself; without them the
packages are trusted for those grants.

## Cells: limits, memory and store requests

The limits that bound a statement, an awake cell and the local files
(`alambique: [sql:, awake:, wal:, local_cache:]`) keep Alambique's defaults.
They are in [design §4.3](design.md#43-limits-on-cell-calls-and-their-errors).

- `sql: [max_concurrent_statements:]` is the most reads that run on a node at
  once (default: the dirty IO schedulers minus two, at least 1). A read over it
  is a 503 `overloaded`.
- `sql: [script_timeout_ms:]` (60,000) bounds a migration, a script and
  Alambique's own statements.
- `compaction: [moved_scan_ms:, moved_scan_page:]` (60,000 and 100) set how
  often the store is scanned for the cleanups of moved cells, and the page of
  that scan.
- `replicas: [poll_max_ms:]` (5,000) and `query: [reflink:]` (`true`) pass
  through to Alambique unchecked.

**Memory.** The memory of a node grows with its awake cells. Atanor keeps
512 KiB of SQLite page cache per cell. When the node has a memory limit (a
cgroup v2 limit, or `memory: [limit_bytes:]`), the awake cells may use half of
it (`memory: [awake_fraction: 0.5]`), and the least used cells hibernate past
that.

**Store requests.** Two options cut the requests a busy cell sends:

- `compaction: [hold_bytes:, hold_object_bytes:]` keeps Alambique's defaults (on).
- `feed: [object_batches:, linger_ms:]` defaults to 16 and 250: one feed object
  carries up to 16 batches, and a lone change is delivered up to 250 ms later.
  A cell that stops publishes what it holds first, for up to
  `feed: [stop_publish_ms: 5_000]`. `linger_ms` must be at most a tenth of
  `feed: [window_ms:]` (10,000 by default), or the instance refuses to start.
  To write one object per batch, set `object_batches: 1`. A reader of the
  change feed outside the instance must use the same Alambique as the nodes.

**The change feed.** Feed objects are deleted after seven days
(`feed: [retention_ms:]`); a worker that is away longer misses what was pruned.
The feed cannot be turned off (`feed: false` is refused).
`feed: [tables:, other_tables:]` leaves tables or columns out of the feed
(`Atanor.Change.row` then lacks them; [how to follow
changes](how-to-follow-cell-changes.md#leave-columns-out-of-the-feed)).

**Snapshots and restores.** `compaction: [snapshot_ratio:, snapshot_keep_ms:, ...]`,
`restore:` and `lazy_restore: [min_bytes:]` keep Alambique's defaults.

**Commits.** A cell's commits are pipelined (`alambique: [pipeline_depth: 8]`
by default).

## WASM engine

`wasm: [max_batch_bytes: ..., max_cell_message_bytes: ...]` caps what a guest
can make the node hold: the total size of the results of one `batch` (default
64 MiB) and the size of one `send-to-cell` message (default 1 MiB). Both are
positive integers in bytes; see
[design §4.3](design.md#43-limits-on-cell-calls-and-their-errors). Native workers
are not limited by them.

The node settings of the WASM engine (threads, calls in flight, queue, CPU limit) are in the
`:atanor, :wasm` application environment, documented in `Atanor.Wasm`. The pooling allocator reserves address space for
`max_calls + max_nested_calls` calls (about 2 TiB for 12 threads at the defaults). On a host with `ulimit -v`,
`vm.overcommit_memory=2` or a container memory policy that refuses it, the node fails to start with an error
naming those settings: lower them or set `pooling: false` (design §14.9).
Component compiles run on their own pool: `compile_threads` (default 2) at
once and `compile_queue` (default 16) waiting; a deployment that finds the
queue full fails at once. `compile_timeout_ms` (default 60,000) is how long a
deployment waits for one.
`host_reply_dirty_bytes` (default 262,144, a positive integer) is the size from
which the reply to a guest's host call is copied into the native side on a
dirty scheduler; smaller replies use a normal one
([design §14.7](design.md#147-host-calls-and-outbound-http)).

## Local node settings

`mix atanor.dev` and the options of the `atanor` command are in
[how-to-build-and-test.md](how-to-build-and-test.md#run-a-local-node) and
[cli.md](cli.md).
