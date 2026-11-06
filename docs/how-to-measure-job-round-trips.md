# How to measure the store round trips of a job

**The question:** How many requests does the store receive for each job, of
which kind, and how many jobs a second does one cell finish when every store
request is slow?

This guide stands alone. It is for contributors who change the job path
(claim, finish, alarms, fencing). The results of the baseline are in
[design §12.13](design.md#1213-store-round-trips-of-a-job).

## Prerequisites

- Docker, for the disposable SeaweedFS of `mise run seaweedfs:up` (the task
  below starts it; `mise run seaweedfs:down` removes it).
- `mise` and the pinned toolchain, as for the other benchmarks.

## Steps

1. Run the measurement with the defaults (100 jobs, 25 and 100 ms of added
   latency, claim concurrency 1 and 16, both handlers; about ten minutes):

   ```sh
   mise run bench:job-trips
   ```

   Expected: for each case a block like the one below. Jobs a second is the
   drain of the jobs, from the first claim to the last finish.

   ```
   == store latency +25 ms, cell_concurrency 16
     host at the end of the case: load average: 8.91, 7.20, 7.68
     enqueue: 100 jobs in 271 ms (369.0 jobs/s, 16 at a time)
     drain:   100 jobs in 6424 ms (15.6 jobs/s in one cell, 64.2 ms of cell time per job)
     requests, drain (… in all, … per job):
       PUT segment (.ltx)  …
   ```

2. Change the case with options after `--`:

   | Option | Default | Meaning |
   | --- | --- | --- |
   | `--jobs N` | 100 | jobs enqueued in one cell |
   | `--latency a,b` | 25,100 | milliseconds added to every store request |
   | `--concurrency a,b` | 1,16 | `jobs.cell_concurrency` (jobs claimed at once) |
   | `--enqueuers N` | 16 | producers that enqueue at the same time |
   | `--tick-ms N` | 1000 | `alarms.tick_ms`, the alarm scan interval |
   | `--timeout-s N` | 600 | limit for the drain of one case |
   | `--handler a,b` | writes,none | `writes`: the test handler writes two rows per job; `none`: it writes nothing, so the run is the job path alone. With both, the bench prints the split below |
   | `--feed a/b,c/d` | 1/0 | `object_batches/linger_ms` of the feed (`1/0`, Atanor's default, is one object per batch), one run of every case for each pair |
   | `--raw` | off | also list every method and path seen |
   | `--trace` | off | also list which Atanor and Alambique functions issued each kind |

   ```sh
   mise run bench:job-trips -- --jobs 50 --latency 100 --concurrency 4 --trace
   ```

3. Read the split. With both handlers each case ends with a table of requests
   per job: `total` (the writing handler), `job path` (the handler that writes
   nothing) and `handler` (their difference per kind of request). The job path
   is enqueue, claim, finish, the `@jobs` alarm, the lease and the fence; the
   handler is the application's own transactions, their change feed objects and
   the compaction they trigger. The difference carries the noise of two runs.

4. Read the result. Requests are counted per phase: `setup` (waking the cell),
   `enqueue` and `drain`. The drain counts everything the store receives while
   the jobs run: the cell's segment uploads, the change feed, the lease, the
   `@jobs` alarm index and the polls of the node (alarm scan, deployments,
   operations), so those that depend on time and not on jobs show up too. Divide
   by the drain time to tell them apart.

## How it measures

A TCP proxy in the benchmark (`bench/store_proxy.exs`) sits between the node and
SeaweedFS. It waits the added latency once per request and counts requests by
method and path, so the count is what the store received and does not depend on
the client. `--trace` uses Erlang call tracing of `Alambique.Store.S3`, which
costs time: do not read jobs a second from a traced run.

The jobs are enqueued first, due about a second after the last enqueue, so none
runs while the others are enqueued. The first job is enqueued alone and the rest
are due one millisecond later each, which is what a steady producer does and
keeps one `@jobs` alarm entry in the index.

## Troubleshooting

- *"the enqueue outlasted its due time"*: raise `--enqueuers` or lower `--jobs`.
- *`bench timed out`*: the drain took longer than `--timeout-s`; raise it.
- *Jobs a second changes much between runs*: the host is shared. The output
  prints the load average at the end of each case; compare runs at a similar
  load.

## Next steps

- [design §15](design.md#15-jobs-per-cell-and-bulk-operations) for the job path
  that the requests belong to.
- [how-to-use-jobs.md](how-to-use-jobs.md) for `cell_concurrency` and
  `claim_on_finish`.
