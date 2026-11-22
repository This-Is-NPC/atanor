# Known limitations

**The question:** what does Atanor not do, or not do well yet, and what do I do about it? This page stands alone.
It has two parts:

- the limits of the design;
- the defects that are still open.

Each entry says what happens, what to do about it, and where the evidence is. Entries are removed when they are
fixed. The "Limits" paragraphs of [design.md](design.md) have more limits of the design, each with its workaround.
The cost of one cell is in [cell-cost.md](cell-cost.md).

## Limits of the design

- **WASM workers cannot serve TCP yet, and cannot read the change feed**
  ([design §14.8](design.md#148-alarms-sockets-and-what-is-left-out)).
- **Discovery trusts the bucket.** Whoever can write `<prefix>/nodes/` decides whom the nodes dial, so write access
  to the bucket must be as trusted as the cluster ([discovery](configuration.md#discovery)).
- **The cluster lab runs on one machine.** The lab is three nodes and one SeaweedFS process in VMs on one host, with
  injected latency and loss. It is not a real network or a replicated bucket
  ([the lab](how-to-run-the-cluster-lab.md)). Test the failures you care about on your own network before you rely on
  them.
- **The memory of a node grows with its awake cells**
  ([configuration](configuration.md#cells-limits-memory-and-store-requests)). Each awake cell adds to the memory of its
  node. [cell-cost.md](cell-cost.md) gives the cost of one awake cell.
- **A file system that stalls writes slows the cells and the store**
  ([the container cluster guide](how-to-run-a-cluster-in-containers.md#keeping-the-data-in-memory)).
- **A new build of the nodes replaces the whole cluster at once.** Atanor has no canary for node releases yet.
- **WebSocket compression can use much more memory than `max_frame_bytes`.** **What happens.** With compression on,
  `max_frame_bytes` bounds the frame as received. A small compressed frame can inflate to a much larger message in
  memory, and `max_frames_per_s` does not count the inflated size. **Workaround.** Keep `permessage-deflate` off, the
  default. If you turn it on, keep `max_frame_bytes` low enough that the inflated size fits the memory of each
  socket, and size `http: [max_connections:]` for it. **Evidence.** `websocket.compress` in `lib/atanor.ex` and the
  help of `ATANOR_WEBSOCKET_COMPRESS` in `lib/atanor/daemon.ex`; [how-to-use-websockets.md](how-to-use-websockets.md).
- **A whole-machine crash can lose the breadcrumbs.** **What happens.** Breadcrumb files are not fsynced, and
  Alambique's markers can be lost too. After such a crash only the store's own records remain. **Workaround.** None
  in Atanor. Reproduce an HTTP crash with `diagnostics: [breadcrumbs: :all]`, which writes one file per request and
  costs throughput. **Evidence.** [how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md).
- **Slow clients are not limited per client address.** **What happens.** `http: [read_timeout_ms]` bounds each read.
  The HTTP/1 header and body deadlines are absolute, but the headers of HTTP/2 and the dashboard listener have no
  total deadline, and no limit applies per client address. **Workaround.** Put a proxy with its own per-client limits
  in front of the node ([TLS at the proxy](how-to-run-in-production.md#tls-at-the-proxy)). **Evidence.**
  [configuration.md](configuration.md#slow-clients).
- **Behind a proxy, all clients share the failed-token limit of the admin API.** **What happens.** The limit counts
  failed tokens per peer address of the connection (`admin.max_failures` in `admin.failure_window_ms`). Behind a
  proxy every client has the proxy's address, so one client's failures block all of them, the right token included,
  until the window ends. **Workaround.** Reach the admin listener without the shared proxy path, or wait for the window
  (60 seconds by default). **Evidence.** [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md).
- **WASM guests in languages other than Rust are not tested.** **What happens.** The examples are in Rust, and only Rust
  was run. Other languages that produce `wasi:http` components (JavaScript with `jco`, Go with TinyGo, Python with
  `componentize-py`) should work, but were not run. **Workaround.** Build a small guest in your language and run it
  before you rely on it. **Evidence.** [how-to-write-a-wasm-worker.md](how-to-write-a-wasm-worker.md).
- **WASM job errors all count as attempts.** **What happens.** A WASM job cannot tell Atanor which error it passes on.
  Every error of the guest counts as an attempt, including a cell call that failed for an infrastructure reason, until
  the host interface marks it. **Workaround.** None yet. **Evidence.** [how-to-use-jobs.md](how-to-use-jobs.md).
- **Schedules are UTC only.** **What happens.** A cron expression runs at UTC times, and time zones are not supported.
  **Workaround.** Convert the local time to UTC and write the expression in UTC. **Evidence.**
  [how-to-use-jobs.md](how-to-use-jobs.md) and [design §15.4](design.md#154-execution-retries-cron-and-timeouts).
- **Partitions cannot be resharded.** **What happens.** The number of partitions `n` is fixed for the life of the data.
  **Workaround.** Pick `n` for the growth you expect, a few times the number of nodes you will have. **Evidence.**
  [how-to-partition-a-cell.md](how-to-partition-a-cell.md).
- **Partitions do not always write faster.** **What happens.** Each partition replicates its own batches, so many small
  writers cost the store more than one writer that groups. Partitions can spread the writes and the CPU over the nodes,
  but they do not always write faster than one cell. **Workaround.** Measure with your store and your nodes before you
  rely on partitions for write speed. **Evidence.** [how-to-partition-a-cell.md](how-to-partition-a-cell.md).
- **A plain read can answer from a former owner after a takeover.** **What happens.** After another node takes a cell
  over, the old owner can keep answering a plain query from its own copy until it learns of the new epoch. If it is
  alive (for example, a node that was frozen and thawed), the answer can miss writes that the new owner has
  acknowledged. The old owner learns at once if its node runs the cell, at its next lease renewal otherwise, and at
  the latest when its lease ends (`lease_ttl_ms` minus `skew_margin_ms`). **Workaround.** Pass `verify_lease: true`
  to a read that must see every acknowledged write. It costs one store `GET` per read, or per batch of reads that wait
  behind a write, and it is off by default. A WASM guest has no such flag. **Evidence.**
  [how-to-read-from-replicas.md](how-to-read-from-replicas.md#read-your-own-writes-after-a-change-of-owner),
  `test/cluster/takeover_test.exs`, and `verify_lease` in `lib/atanor/env.ex`.
- **The replica switch counts only the reads that go through `Atanor.Cell`.** **What happens.** The switch turns on only
  when the cell is read `replica_enter` times a second in the cluster for `sustain_ms`. Only reads through
  `Atanor.Cell` (`Atanor.Env.query/5`) are counted: a read that calls Alambique directly is not seen. **Workaround.**
  Read through `Atanor.Env.query/5`, or turn the replicas on yourself with `Atanor.Cell.replicas/3`. **Evidence.**
  [how-to-read-from-replicas.md](how-to-read-from-replicas.md#errors).
- **A hot-cell move interrupts the cell.** **What happens.** A move hibernates the cell and wakes it on another node.
  Calls for the cell wait up to `move_timeout_ms` and then go to the new owner. The move is held while the cell
  compacts, and the compaction competes with traffic for the store. The thresholds depend on your hardware.
  **Workaround.** Keep `move: false` and use replicas for the reads, or measure your own hardware before you turn moves
  on. **Evidence.** [how-to-place-hot-cells.md](how-to-place-hot-cells.md#what-to-expect).
- **A cluster of two nodes waits for the lease after a silent failure.** **What happens.** A node takes cells over only
  when it and the peers it reaches are a majority of the nodes it knows (`takeover: [quorum: true]`, the default). With
  two nodes, a silent failure waits for the lease of each cell to end (30 seconds by default). **Workaround.** Run
  three nodes, or accept the wait. **Evidence.** [how-to-run-a-cluster.md](how-to-run-a-cluster.md) and
  [design §8.10](design.md#810-acting-on-a-confirmed-failure).
- **A rollback may not read the cells that a newer Alambique wrote.** **What happens.** A node that wrote cells with a
  newer Alambique may not be readable by an older one. A rolling upgrade of three or more nodes in one group was not
  tested. **Workaround.** Keep the backup from before the upgrade until the new version has run longer than your
  rollback window. Workers roll back with `atanor rollback`. **Evidence.**
  [how-to-operate-atanor.md](how-to-operate-atanor.md#upgrade-to-a-new-version).
- **Backups were tested only on SeaweedFS.** **What happens.** Atanor documents no backup of the bucket, and the copy
  is made with an S3 tool. A real S3, bucket versioning and lifecycle rules were not tested. **Workaround.** Test a
  restore on a schedule. **Evidence.** [how-to-operate-atanor.md](how-to-operate-atanor.md#back-up-and-restore).
- **Enqueues into a cell slow down while its jobs run.** **What happens.** With `jobs.claim_on_finish` on, the next due
  job of a cell is claimed when one finishes. The cell has one writer, so enqueues into it are slower while its jobs
  run, though the jobs finish sooner. **Workaround.** Set `jobs.claim_on_finish: false` to favour enqueue speed.
  **Evidence.** `claim_on_finish` in `lib/atanor/config.ex` and [how-to-use-jobs.md](how-to-use-jobs.md).
- **A released job can wait up to `lease_ttl_ms` before it runs again.** **What happens.** A cell taken over early starts
  no job until the old lease has ended plus the margin. A job released by a dead node can wait up to `lease_ttl_ms`
  (30 seconds by default). A cell nobody uses waits for its claim to expire (`jobs.claim_ms`). **Workaround.** Set
  `routing.fence_defer_after_takeover: false` to run the job at once, and accept an overlap bounded by the lease left.
  **Evidence.** `fence_defer_after_takeover` in `lib/atanor/fence.ex` and `lib/atanor/config.ex`, and
  [how-to-use-jobs.md](how-to-use-jobs.md).

## Open defects

### WASM calls cost more CPU and context switches than a fixed pool

**What happens.** The pool keeps one thread per call in flight (design §14.2), so under load more threads than cores
compete for the permits. The extra threads cost CPU and voluntary context switches per request, and the hello guest
over HTTP serves fewer requests per second than it would with `threads` pool threads. Calls above `worker_calls` busy
wait in the queue instead of being refused, which adds a little queueing under a burst.

**Workaround.** None is needed for correctness. For the most throughput keep `threads` at the core count and raise
`worker_calls` and `max_calls` for bursts of one worker.

**Evidence.** The WASM benchmark (`bench/wasm.exs`, listed in [how-to-build-and-test.md](how-to-build-and-test.md))
prints the requests per second, the CPU per request and the voluntary switches of each run. Compare the CPU per request
and the switches: throughput varies between runs on a shared host, and these two figures separate the builds in every
run.

### The store breaker can open under overload

**What happens.** When the node is out of CPU, store calls can fail, and Alambique's store breaker (5 failures in a
row, 5 s cool-down) opens. Some requests then answer 503 `store_unavailable` with `Retry-After`. The node log has `store_unavailable` in
compaction, feed publish and the node registry while the breaker is open. The cause of the first failure is not known.

**Workaround.** A breaker that opens under overload is expected, and it can open again and again while the node is out
of CPU. Retry the 503s that carry `Retry-After`.

**Evidence.** The node logs the breaker opening and closing and one line per store failure with its reason and
whether the breaker counted it (`Atanor.StoreLog`, design §10.2). This entry stays open until the cause of the first
failure is known.

### Pending jobs stay stuck in a restored cell that gets no new job

**What happens.** A bucket copied while nodes serve (for example `mc mirror`) can hold a cell whose `@jobs` wake
row names an index object under `alarms/` that the copy lacks, because the index and the cells are copied at
different moments. A restored cell like that with `pending` jobs, or a `running` job whose claim has expired,
does not run them until the next enqueue or re-arm of that cell: that call finds the wake overdue by more than
`alarms.timeout_ms`, checks the index object and puts it back (`Atanor.Jobs`, `heal_index`). A cell that gets
no new enqueue stays stuck, across node restarts.

**Workaround.** Take the copy after every node drained (`POST /drain`), enqueue a job to the cell, or write the
missing index object by hand
([how-to-operate-atanor.md](how-to-operate-atanor.md#restore-from-a-copy-of-a-live-bucket)). `set_alarm` alarms use
the same index and were not tested.

**Evidence.** `heal_index` in `lib/atanor/jobs.ex`, which the wake check calls, and the restore steps in
[how-to-operate-atanor.md](how-to-operate-atanor.md#restore-from-a-copy-of-a-live-bucket).

### Dirty IO threads are not sized to the CPU quota on cgroup v1 hosts

**What happens.** `rel/env.sh.eex` reads the CPU quota from cgroup v2 only. On a cgroup v1 host the node keeps the
BEAM's 10 dirty IO threads whatever its quota, and Alambique's statement slots follow them (8). On a small quota their
bursts can use up the CPU quota of each period: the node is throttled and its latency grows.

**Workaround.** Set the number yourself, for example `ERL_ZFLAGS="+SDio 1"` for a quota of 1 CPU
([configuration.md](configuration.md#dirty-io-threads-and-the-cpu-quota)).

**Evidence.** `daemon/rel/env.sh.eex` (`atanor_dio_flag`) and `test/scripts/node_env_test.exs`: a cgroup v1 line
gives no flag.

### A read of an awake cell can answer 503 during a store outage

**What happens.** While the store is down, a read of an awake cell can answer 503. The design expects awake cells to
keep answering. The likely cause is the lease check, which reads the store. This is an inference, not a confirmed
cause: the body of the answer is not recorded.

**Workaround.** Fix the store first. The breaker closes after one good probe, and then the reads answer again. Retry
the 503s that carry `Retry-After`.

**Evidence.** The store breaker check in [how-to-operate-atanor.md](how-to-operate-atanor.md#the-store-breaker-is-open),
and `verify_lease` in `lib/atanor/alarms.ex` and `lib/atanor/dispatch.ex`, which read the store.
