# What does not work

Defects that are still open. Each entry says what happens, what to do about it,
and where the evidence is. Entries are removed when they are fixed. Limits that
are choices of the design are in the "Limits" paragraphs of
[design.md](design.md) and in the README's
[Limitations](../README.md#limitations).

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
separate the builds in every run. The change is therefore in the commits from
`36dc2e5` (admission) to master, not before.

Ruled out, each measured by changing one thing on the master of that time
(1-minute load 10 to 20, so CPU per request only):

- The number of instance slots of the pooling allocator: forcing 12 instead of
  60 gave 460 to 472 us per request against 456 to 473 us with 60.
- The right-to-run semaphore: skipping it removed about 0.3 of the 0.5 extra
  switches and none of the extra CPU (456 to 475 us against 475 to 485 us).
- The compile pool, the batch and message caps, the pinning of nested calls
  and the host reply split are in `c9b5281` and cost nothing in this path.

Not yet isolated: the remaining extra CPU, between `36dc2e5` and master. The
candidates are the per-call gate and slot, the condition-variable queue, and
the update to Alambique 0.3.0. To reproduce, build each tag or commit in its
own worktree and run the command above alternately; the benchmark prints the
CPU and switches per request.
