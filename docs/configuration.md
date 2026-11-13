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
| `disk:` | The disk budget of `data_dir` ([below](#cells-limits-memory-and-store-requests)). |
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
The wakes in flight have a share too: `memory: [wake_fraction: 0.5]` of the headroom
between the refuse mark and the limit derives `awake: [max_wakes:]` and
`restore: [fetch_concurrency:, max_inflight_bytes:]` unless you give them (a 512 MiB
node gets 14 wakes, 1 request and 2.4 MiB in flight; a 2 GiB node 15, 4 and
9.6 MiB; formula in [design §4.3](design.md)), so a store that fails cannot make
every queued request restore a cell at once.

**Refusing requests before the node dies.** The ingress refuses with 503
`overloaded` and `Retry-After`, before it reads the route, the token or the
body, when either gate is closed:

- `memory: [refuse_fraction: 0.85]`: the working set of the cgroup (`memory.current`
  minus the `inactive_file` of `memory.stat`, so page cache the kernel can drop
  never counts) is at least that share of the memory limit. The gate opens again
  below `refuse_fraction - 0.05`. `nil` turns it off, as does a node with no
  limit. The sampler reads the files every `memory: [sample_ms: 100]`
  (`current_path` and `stat_path` default to
  `/sys/fs/cgroup/memory.current` and `memory.stat`). A sample older than ten
  periods is ignored. While it is closed, a call for a cell that is not awake on
  the node (it would wake it) is refused the same way.
- `http: [max_in_flight: 1_024]`: requests served at once on the node. A WebSocket
  holds no slot after the upgrade. The memory gate is the main guard; this one
  bounds the handlers when the limit is high or unknown.

Open WebSockets are not closed by either gate. Refusals count in
`Atanor.Admission.stats/1` and `[:atanor, :http, :reject]` (reasons `:memory` and
`:in_flight`, [telemetry](telemetry.md)).

**Disk budget.** `data_dir` is bounded too. An awake cell's `-wal` file grows
about 17 to 32 KiB a write and is moved into the database only when it passes
`alambique: [wal: [checkpoint_bytes:]]`, so without a bound a node fills its disk
under continuous writes. The budget is `disk: [max_bytes:]`, or by default
`disk: [fraction: 0.8]` of the size of the file system that holds `data_dir` (read
with `df -Pk` at start; the node logs the budget and its source, for example
`atanor: data_dir limited to 1073741824 bytes (option)`). When the size cannot be
read there is no budget, a warning is logged and Alambique's defaults apply.

- Unless you set them, `wal: [checkpoint_bytes:]` is `budget / max_cells / 2` between
  1 MiB and 64 MiB (`max_cells` is `awake: [max_cells:]`, 20 000 by default, so
  1 MiB below about 39 GiB), `wal: [max_bytes:]` is what the WALs of all awake cells
  may hold (at most half of the budget; Alambique checkpoints the biggest WALs past it,
  checked every `wal: [budget_interval_ms:]`, `disk: [sample_ms:]` at most 1 000), and
  `local_cache: [max_bytes:]` is the budget minus that. `local_cache: [interval_ms:]`
  follows `disk: [sample_ms:]`. An option you give wins.
- Every `disk: [sample_ms: 5_000]` the node adds up the files of `data_dir`. At
  `disk: [evict_fraction: 0.7]` of the budget it hibernates the idle cells used
  longest ago. At `disk: [refuse_fraction: 0.95]` the ingress refuses every
  new request with 503 `overloaded` and `Retry-After` (reasons `:disk` in
  `[:atanor, :http, :reject]`), and resumes 5 points below. `refuse_fraction: nil`
  turns the refusal off. The node can pass the mark by what is written between two
  samples: lower `sample_ms` for a fast disk.
- A write that fails because the disk is full is a 503 `overloaded`, never a 500.
- `disk: [probe:]` replaces the reading of the file system size (a function of
  the path, `{:ok, bytes}` or `:error`), for tests.
- `diagnostics: [max_bytes: 33_554_432]` caps the crash reports kept on disk while
  the store is down, the oldest removed first.

Design §4.4 has the reasons and the measurements.

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
`:atanor, :wasm` application environment, documented in `Atanor.Wasm`. `threads` defaults to the
logical processors, at most the CPU quota of the container (cgroup `cpu.max`, rounded up). The pooling allocator reserves address space for
`max_calls + max_waiting + max_nested_calls` calls (about 2.8 TiB for 12 threads at the defaults).
`max_waiting` (default 2 per thread) is how many guests that wait (a sleep, a host call, an outbound response, a
worker they called) stop counting against `max_calls` and `worker_calls` (design §14.2). On a host with `ulimit -v`,
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
