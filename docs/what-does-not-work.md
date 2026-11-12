# What does not work

Defects that are still open. Each entry says what happens, what to do about it,
and where the evidence is. Entries are removed when they are fixed. Limits that
are choices of the design are in the "Limits" paragraphs of
[design.md](design.md) and in the README's
[Limitations](../README.md#limitations).

## Alambique has no node WAL budget

**What happens.** An awake cell checkpoints its `-wal` only when the file passes
`wal: [checkpoint_bytes:]`, and a hibernation is the only other thing that
removes it. There is no budget for the WALs of the whole node and no call that
checkpoints an awake cell, so Atanor derives a low `checkpoint_bytes` from the
disk budget and its monitor hibernates cells to free WALs (design §4.4). A
hibernation costs more than a checkpoint (an upload, then a wake with a restore
on the next call), and it can only choose by the size of the files it sees under
`data_dir`: there is no call that lists the awake cells by use or by WAL size.
With the default `max_cells` the mark is 1 MiB for every cell, which checkpoints
about every 40 writes.

**Workaround.** Set `disk: [max_bytes:]` for the disk the node has, lower
`awake: [max_cells:]` to give fewer cells a higher mark, and set
`disk: [sample_ms:]` for the write rate: the use can pass the refuse mark by what
is written between two samples.

**Evidence.** `test/atanor/disk_budget_test.exs`: 12 writers on 20 cells for 8 s
made `data_dir` 1.34 GB with Alambique's 64 MiB mark; 17 to 20 MiB with a 32 MiB
budget (the 1 MiB marks alone); and 14 to 15 MiB with a 16 MiB budget
(`sample_ms: 20`), where the monitor hibernated cells. What Alambique would need
to offer:

- A node-wide `wal: [max_bytes:]`: when the WALs of the awake cells add up to it,
  the cell with the biggest WAL checkpoints (the same TRUNCATE checkpoint, after
  its uploads are acknowledged).
- `Alambique.checkpoint(instance, cell)`: checkpoint one awake cell now, without
  hibernating it, answering `:ok`, `{:error, :busy}` or `:asleep`.
- A listing of the awake cells with their last use and the size of their WAL
  (for example `Alambique.cells/2` with `:details`), so that a caller chooses
  the idle ones without reading the directory.
- A disk-full error of its own (`{:error, :disk_full}`) instead of SQLite's
  message `"database or disk is full"`, which Atanor matches as text.

## WASM throughput is about 5% below 0.2.0 after the admission change

**What happens.** The hello guest over HTTP serves about 5% fewer requests/s
than 0.2.0 with 32 clients on 12 threads, because each request costs about 9%
more CPU (about 405 us against 372 us, VM and clients together) and about 0.5
more voluntary context switches (4.1 against 3.6). One worker is also refused
with 503 `overloaded` above `worker_calls` where 0.2.0 queued, about 0.1% of
the requests of a 64-client burst (design §14.2).

**Workaround.** None is needed for correctness. For the most throughput keep
`threads` at the core count and raise `worker_calls` and `max_calls` for
bursts of one worker; a smaller `max_calls` refuses more and was not faster.

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
