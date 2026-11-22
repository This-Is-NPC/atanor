# Known limitations

**The question:** what does Atanor not do, or not do well yet, and what do I do about it? This page stands alone.
It has three parts:

- the limits of the design;
- what the load rounds found, with the conditions of the lab;
- the defects that are still open.

Each entry says what happens, what to do about it, and where the evidence is. Entries are removed when they are
fixed. The "Limits" paragraphs of [design.md](design.md) have more limits of the design, each with its workaround.
The numbers to plan with are in [capacity.md](capacity.md).

## Limits of the design

- **WASM workers cannot serve TCP yet, and cannot read the change feed**
  ([design §14.8](design.md#148-alarms-sockets-and-what-is-left-out)).
- **Discovery trusts the bucket.** Whoever can write `<prefix>/nodes/` decides whom the nodes dial, so write access
  to the bucket must be as trusted as the cluster ([discovery](configuration.md#discovery)).
- **Cluster behavior was measured on one machine.** The lab is three nodes and one SeaweedFS process in VMs on one
  host, with injected latency and loss. It is not a real network or a replicated bucket
  ([the lab](how-to-run-the-cluster-lab.md)). Run the scenarios on your own network before sizing.
- **The memory of a node grows with its awake cells**
  ([configuration](configuration.md#cells-limits-memory-and-store-requests)). Plan with [capacity.md](capacity.md).
- **A file system that stalls writes slows the cells and the store**
  ([the container cluster guide](how-to-run-a-cluster-in-containers.md#keeping-the-data-in-memory)).
- **A new build of the nodes replaces the whole cluster at once.** Atanor has no canary for node releases yet. One
  returns once compatibility between releases is designed.
- **Upgrade from 0.8 through 0.9.** 0.9 changed the layout of the alarm index keys and reads both layouts. A 0.8 node
  does not fire the alarms that 0.9 nodes set ([upgrades](how-to-operate-atanor.md#upgrade-to-a-new-version)).

## What the load rounds found

The go-live numbers of [capacity.md](capacity.md) come from rounds 018f, 026r, 027 and 028 (`load/rounds/`).

**The lab:**

- One VM with 4 vCPUs and about 5 GB of RAM ran the node, the load generator and the store.
- Scenario A is a node limited to 1 CPU and 512 MB, and scenario B one limited to 2 CPUs and 2 GB.
- The store is SeaweedFS on the same VM, with 25 ms added to every store trip:
  - on the VM's disk in 018f;
  - on a btrfs directory without copy-on-write (`nodatacow`) in 027.
- Each step holds its rate for 180 s, and a value counts only if it passes twice.

**What happens:**

- **The values vary from round to round.** The same value passed once and failed its repeat minutes later in 5 of
  the 7 ramps of round 027. Examples:
  - A cells passed 397, then failed its repeat with p99 257 ms;
  - B http-native passed 1406, then failed with 287 ms.
  The highest values that passed varied, for example:
  - A cells: 353 to 426;
  - B cells: 1938 to 2438;
  - B http-native: 1406 to 1641, and none in round 028, where the first step, 1125, failed with p99 307 ms while
    79 store writes took 1 s or more;
  - A http-wasm: 375 to 450;
  - A http-wasm-jobs: 54 to 68.
  In round 028 the confirmation descent found A cells at 353: 426 passed once and failed its repeat, then 412 failed
  its repeat, and 353 passed twice.
- **The lab store stalls.** In some steps, store answers take 1 to 1.3 s for a few seconds, and a step that
  falls on that window fails its p99. In round 027 this happened at 570 in A http-native, which still passed, and at
  1500 in B http-native, where p99 reached 995 ms.
- **A job-heavy app makes slow listings of the alarm index.** With `http-wasm-jobs`, the node lists `alarms/` on every
  tick, and on the lab's SeaweedFS that listing took 1 to 3.2 s, one at a time, every 3 to 5 s, growing longer over
  the measure. Round 028's node log names them: 249 of the 272 store requests of 1 s or more in one step were
  `LIST store:8333/atanor/?prefix=atanor/alarms/`, and the rest were writes of cells. The other loads had no slow
  listing. It was seen only on SeaweedFS; a store without folders was not measured.
- **Refusals near the WASM ceiling.** A WASM node near its ceiling answers about 1% of requests with 503 `overloaded`
  (`worker_queue`). B http-wasm refused 1.0% at 1300 requests per second in round 027 and 1.6% in round
  028; A refused 1.3% and 1.6% at 400.
  Clients must retry a 503 that carries `Retry-After`.
- **Answers held elsewhere during a node swap.** Replacing a node under load answers some requests with 503
  `held_elsewhere` while the cells move: 212 answers in A at 68 requests per second, and 366 in B at 109, where the
  swap took 11.8 s and p99 peaked at 593 ms. In round 028, A at 54 requests per second swapped in 4.5 s with 190 such
  answers and a p99 peak of 391 ms. No acknowledged write was lost or duplicated.

**Workaround.** Plan with the go-live numbers, which are 50% of the lowest value that passed. Retry the 503s that
carry `Retry-After`. Run a round on your own hardware and store before you size above them
([how-to-run-the-load-tests.md](how-to-run-the-load-tests.md)).

**Evidence.**

- The round files are in `load/rounds/`, and the measured values in
  [how-to-run-the-load-tests.md](how-to-run-the-load-tests.md#measured-results).
- Round 027 ran Atanor 0.9.0 and Alambique 0.15.0, on 2026-11-21. Round 028 ran master `431e255` (0.9.0 with the
  confirmation descent and the store log), on 2026-11-21 and 22, as a check that may only lower a number.
- A load round may lower a number of [capacity.md](capacity.md) and adds what it finds here.

## Open defects

### WASM throughput is about 5% below 0.2.0 after the admission change

**What happens.** The hello guest over HTTP serves about 5% fewer requests/s
than 0.2.0 with 32 clients on 12 threads, because each request costs about 9%
more CPU (about 405 us against 372 us, VM and clients together) and about 0.5
more voluntary context switches (4.1 against 3.6). One worker's calls above
`worker_calls` busy now wait in the queue (since round 018; they were refused before), which
adds a little queueing under a burst (design §14.2).

**Workaround.** None is needed for correctness. For the most throughput keep
`threads` at the core count and raise `worker_calls` and `max_calls` for
bursts of one worker; a smaller `max_calls` was not faster.

**Evidence.** Fuel mode, 32 clients, 8 s, ABBA order, `mise run bench:wasm --
8` with `ATANOR_BENCH_CPU=fuel`, 1-minute load 2.4 to 3.0 at the start of each
run (the benchmark's own load raises it to 3.5 to 6 by the end):

| Build | Requests/s | CPU per request | Voluntary switches |
|---|---|---|---|
| `v0.2.0` (4 runs) | 23,736, 25,616, 27,330, 27,068 | 364 to 391 us | 3.6 |
| `c9b5281`, before the admission change (4 runs) | 23,458, 26,405, 27,298, 26,973 | 366 to 385 us | 3.6 |
| master at `28c8290` (4 runs) | 24,153, 23,952, 24,831, 25,021 | 400 to 413 us | 4.1 |

Throughput varies by 15% between runs of one build on this host, so the CPU
per request and the switches per request are the figures to compare: they
separate the builds in every run.

Bisect of the commits between `c9b5281` and master, ABBA over 3 rounds, 8 s
runs, 1-minute load 2.4 to 3.0 at each start (CPU per request in us, voluntary
switches per request; the first two rounds of `36dc2e5` and `3c15a15` had no
CPU figure printed and are left out):

| Commit | CPU per request | Voluntary switches |
|---|---|---|
| `c9b5281`, before the admission change | 366, 367, 371 | 3.6 to 3.7 |
| `36dc2e5`, right to run | 385, 392, 393 | 4.3 |
| `3c15a15`, wake one idle pool thread | 392, 395, 401 | 3.9 to 4.0 |
| `89360b9`, Alambique 0.3.0 | 389, 391, 392, 402 | 3.9 to 4.0 |
| master at `28c8290`, `max_waiting` | 398, 399, 403, 408 | 4.1 |

The step is `36dc2e5` (about +20 us, +0.65 switches); `3c15a15` removes 0.35
switches but no CPU, and `max_waiting` adds about 10 us. Alambique 0.3.0 adds
nothing.

Ruled out, each measured by changing one thing on the master of that time:

- The number of instance slots of the pooling allocator (1-minute load 10 to
  20, so CPU per request only): forcing 12 instead of 60 gave 460 to 472 us
  against 456 to 473 us with 60.
- The right-to-run semaphore on master `28c8290` (load 2.5 to 3.0): skipping
  it gave 394 to 410 us and 3.9 switches against 398 to 408 us and 4.1. It is
  about 0.2 switches and no CPU, so it is not the cost (that run breaks the
  guarantee that a waiting guest holds no right to run; it was an experiment
  only).
- The compile pool, the batch and message caps, the pinning of nested calls
  and the host reply split are in `c9b5281` and cost nothing in this path.

Cause, tested on master `28c8290` with a temporary local patch that starts
`threads` (12) pool threads instead of `max_calls + max_waiting` (60) and
changes nothing else (ABBA, 3 rounds, 8 s, load 1.6 to 3.0 at each start):

| Pool threads | CPU per request | Voluntary switches | Requests/s |
|---|---|---|---|
| 60 (master) | 434, 407, 405, 408, 403, 408 us | 4.1 | 22,496 to 24,799 |
| 12 (patch) | 393, 384, 391, 389, 386, 391 us | 3.6 | 25,484 to 26,270 |

With 12 pool threads the CPU per request (384 to 393 us) and the switches (3.6)
are in the range of v0.2.0 (364 to 391 us, 3.6), and the throughput is about
26,000 requests/s. So the extra runnable pool threads cost about 17 us per
request (4%) and all of the extra voluntary switches: with 32 clients, 32
threads wake and park for the 12 permits where 0.2.0 kept 20 calls in the
channel. The patch is not a fix: the pool has one thread per call in flight so
that a waiting guest can give up its permit while its thread stays with its
call (order 017, design §14.3), and with 12 threads a waiting guest would again
hold a thread. The rest of the gap to `c9b5281` (about 20 us) is the per-call
wrapper, gate and slot of `36dc2e5` and `max_waiting`; it was not split
further. To reproduce, build each commit in its own worktree and run the
command above alternately; the benchmark prints the CPU and switches per
request.

### The store breaker opened once for 5 seconds at 100 req/s in scenario A

**What happens.** In one official load round (scenario A, node 1 CPU and 512 MB,
store latency 25 ms), the step at 100 req/s for 180 s failed with p99 5,904.9 ms
and 50 `503`s with `Retry-After`. The node log has `store_unavailable` in
compaction, feed publish and the node registry for 5 s (17:54:37 to 17:54:42
UTC, 74 s into the step): Alambique's store breaker (5 failures in a row, 5 s
cool-down) was open. The first failure is not in that log, so the trigger is
unknown. The store counted no 5xx, ran at 0.23 of its 1.5 cores and its tmpfs
was 5% full, and the VM was quiet.

**Workaround.** Rerun the step; it passed in 14 of 14 steps (90 minutes at 100
req/s or less) in later runs of the same build. A breaker that opens under
overload is expected: at 800 req/s the node is out of CPU and the breaker opened 4 times in 60 s
with a clean store (see Evidence).

**Evidence.** The node now logs the breaker opening and closing and the HTTP
errors behind it (`Atanor.StoreLog`, design §10.2), and a failed load step keeps
the store log, the store metrics, `store_breaker_open` and `node_throttled_ms`
next to the node log (how-to-run-the-load-tests.md). Since Alambique v0.10.0 the
log also has one line per store failure with its reason and whether the breaker
counted it. v0.10.0 fixed one candidate cause: the HEAD check of the frozen marker
had a 50 ms timeout that counted as a store failure; it now has 1 s
(`check_timeout_ms`). In the test suite, the `:crashed` failures seen on a loaded laptop most likely came from the
testkit MemoryStore's 5 s `GenServer` timeout, which v0.10.1 removed; the failure line now also has the crash `kind`
and `detail`. The next load round will confirm whether that was the trigger;
this entry stays open until then. The next occurrence names its cause. Until then: stall seen once between 72.3 s and 73.8 s of the step,
requests in flight 2 to 50, generator lag p99 5,523.9 ms, node 0.31 and store 0.23 cores.

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

**Evidence.** Before the fix, two restores of a copy taken with a writer running: `{"last_seq":86,"ranked_through":83}` with
jobs `{"done":82,"pending":3,"running":1}` after more than 3 minutes, and `{"last_seq":50,"ranked_through":44}`
when `alarms/` was copied last. The cell file held `@jobs|1794809947744|6b0c7899|0` and the bucket had no such
index object. Writing the object made `ranked_through` equal `last_seq` within 8 s. A copy taken after `POST
/drain` restored with every job run.

### Dirty IO threads are not sized to the CPU quota on cgroup v1 hosts

**What happens.** `rel/env.sh.eex` reads the CPU quota from cgroup v2 only. On a cgroup v1 host the node keeps the
BEAM's 10 dirty IO threads whatever its quota, and Alambique's statement slots follow them (8). On a small quota their
bursts can use up the CPU quota of each period: the node is throttled and its p99 grows.

**Workaround.** Set the number yourself, for example `ERL_ZFLAGS="+SDio 1"` for a quota of 1 CPU
([configuration.md](configuration.md#dirty-io-threads-and-the-cpu-quota)).

**Evidence.** `daemon/rel/env.sh.eex` (`atanor_dio_flag`) and `test/scripts/node_env_test.exs`: a cgroup v1 line
gives no flag. Under cgroup v2 with a quota of 1 CPU, the default 10 threads left the node throttled 150 to 173 s of
180 s at 490 req/s; with 1 thread, about 40 s.
