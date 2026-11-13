# How to run the load tests

**The question:** How many requests per second, idle WebSocket connections and hot cells does one Atanor
node hold in 1 CPU and 512 MB (scenario A) or 2 CPUs and 2 GB (scenario B), what does each unit cost in
CPU, memory and store trips, and what does a node swap cost at the load that node holds?

This guide stands alone. The scenario is the container cluster of
[how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md) with one node and no peers;
the swap is the one of [how-to-replace-a-node.md](how-to-replace-a-node.md). Numbers from a development
machine say how the harness works, not what a release holds: run the real ramps on the pinned build.

## What is measured

| Measure (task) | Ramp | A step fails when | Cost per unit |
| --- | --- | --- | --- |
| `load:http-native`, `load:http-wasm`: reads and writes in cells | requests per second | p99 > 250 ms, a 5xx other than 503 with `Retry-After`, or any error | req/s per vCPU, fixed MB, MB per req/s, S3 trips and bytes per request |
| `load:ws`: open idle WebSockets, one message per socket every 30 s | connections | memory at 90% of the limit, or file descriptors at 90% of the limit (or a socket that cannot connect or is dropped) | MB and descriptors per connection |
| `load:cells`: cells written once every 10 s, all awake together | cells | memory at 90% of the limit, or p99 > 250 ms | MB per hot cell |
| `load:swap`: node A replaced by B under load | none (one run at the last approved `http-wasm` rate) | an acknowledged write lost or duplicated, or an answer other than 503 with `Retry-After` | swap duration and p99 peak |

## How the environment is built

One container per service, all of the project `atanor-cluster` (`scripts/cluster-*`), plus the throwaway
`atanor-load-tc`. Nothing else on the host is touched.

| Piece | How |
| --- | --- |
| Node | One container, `cpus` and `mem_limit` from the scenario (A: 1 and 512 MB; B: 2 and 2 GB), no peers. |
| Service data | The node's data directory is a tmpfs (`ATANOR_LOAD_TMPFS_SIZE`, 256 MB). A tmpfs counts against its container's memory limit, so the container's limit (`mem_limit` and `memswap_limit`) is the scenario memory **plus** the tmpfs size (scenario A: 512 + 256 = 768 MB); the tmpfs is a lab artifact and does not take memory from the service. Service memory is `memory.current - shmem` from the container's cgroup `memory.stat`, and the 90% criterion compares it with the scenario memory, not the container limit. `shmem`, the tmpfs, is reported apart. |
| No swap | Every measured container has `memswap_limit` equal to `mem_limit`, so it cannot swap (zram or disk swap on the host would void the memory numbers). `load-run` checks `docker inspect` (`Memory` set and `MemorySwap` equal to it) and, when readable, the cgroup's `memory.swap.max` (0) before the first step, and refuses to run otherwise (`scripts/load-env check-swap`). Recreate a cluster started before this limit existed with `load:down` and `load:up`. |
| Store | SeaweedFS in its own container (2 CPUs, 2 GB plus its tmpfs of 1 GB, outside the node's limit), data in tmpfs. |
| Store latency | `tc netem delay 25ms` on the store's network interface, so every answer the store sends waits 25 ms: each trip costs 25 ms more. The node image has `tc`; `atanor-load-tc` joins the store's network namespace with `NET_ADMIN`, applies the qdisc and exits. The qdisc needs no root on the host. A request on a warm connection pays the latency once; a `curl` that opens a connection pays it twice, because the handshake answer waits too. `load:up` checks that the round trip from the node to the store grew by at least 80% of the added latency (observed: 1.0 ms to 51.1 ms for a new connection) and every step records it (`store_rtt_ms`). |
| Balancer | HAProxy (2 CPUs) is in the path only for `load:swap`. The other measures send to the node's address. |
| Generator | `scripts/load-gen`, outside the node's limit: Python `asyncio`, open loop, keep-alive connections, one process per about 600 req/s. Latency counts from the scheduled time of a request. |
| Workers | `AtanorLoad.Worker` (native, [cluster/load/lib/atanor_load/worker.ex](../cluster/load/lib/atanor_load/worker.ex); `load:up` builds the image `atanor-cluster-load:local` from [cluster/load/Dockerfile](../cluster/load/Dockerfile), a [derived image](how-to-build-a-derived-image.md) of the release with the tools of the harness target, because a native module must be loaded in the node) and the scoreboard example (WASM). Both are deployed by `load:up`. |

## How a step is judged

Every sample (default every 5 s) reads the node's cgroup (`memory.current`, `memory.stat`, `memory.peak`,
`cpu.stat`), its descriptors (`/proc/PID/fd` of the BEAM, through `docker exec`), the store's
Prometheus counters (`SeaweedFS_s3_request_seconds_count` and bucket traffic, for trips and bytes), `/proc/stat`
and `/proc/meminfo`. Per step, in this order:

1. **Host memory.** `MemAvailable` below 6 GB: the round stops cleanly.
2. **Host load.** Net host load is the cores busy on the host minus the cores the test itself used (node,
   store, balancer, generator), averaged over the step. Above 6, the step is invalid and is repeated (twice,
   after 30 s); then the round stops.
3. **Swap.** The step is INVALID (not a failure of the node; the round stops) when any of these holds:
   - a measured container (node, store or balancer) swapped: its cgroup `memory.swap.current` was above 0 at any sample. It is read from the host through the cgroup of the container's init PID, with the other cgroup reads. When it is unreadable it is recorded as null and not judged;
   - the `VmSwap` of the load generators (`/proc/PID/status`, summed over the processes `load-run` started and their children) grew by more than 16 MB (`ATANOR_LOAD_MAX_GENERATOR_SWAP_MB`);
   - the host's swap used (`SwapTotal - SwapFree`) grew by more than 256 MB during the step: the largest sample minus the value at the start (`ATANOR_LOAD_MAX_HOST_SWAP_GROWTH_MB`).

   The level of host swap is only recorded, never judged: a host may hold gigabytes of old swap that the step does not touch. Each step file records host swap start, max and growth, generator swap start, max and growth, and the largest swap of each measured container; the report shows the generator swap growth and the largest host swap. `load:swap` applies the same rule (the node A container is removed during that run, so its swap reads as null afterwards).
4. **Node stopped.** A node that breaks at its limit is a result, not a crash of the runner. After the
   step, and when the generator fails, `load-run` runs `docker inspect` on the node container and compares
   it with its state at the start of the step. The step FAILS, and the ramp bisects or stops as for any other
   failure, with the reason `node OOM-killed`, `node exited CODE` (for example 137), `node restarted` (same
   container started again, or a new one) or `node container gone`. It is judged before the invalid checks
   (host load, swap, delivery). It saves `NAME.node-state.txt` (the container state) and `NAME.node.log` (the
   whole log since the container started, the last 5 MB of it when longer) next to the step file, before `load:down` removes the container. A step that fails on a criterion with the node still running saves the same two files. A node that is fine
   while a side measurement fails (the store round trip, the awake cells, the descriptors) keeps its step as
   measured: the value is null and `notes` in the step file says what was not measured.
   The nodes do not restart (`restart: "no"`), so the round ends at a node stop: no bisection and no
   confirmation. The summary has `node_stopped: true`, `first_failure` and `stopped_by` from that step, and
   `approved` is the last good value (no confirmation repeat); `load-run` still exits 0. A step that finds the
   node not running at its start runs no generator: it is INVALID ("node not running at step start") and ends
   the round the same way.
5. **Store tmpfs.** The step is INVALID (the round stops) when the store's tmpfs passed 90% of its size at any
   sample (`ATANOR_LOAD_MAX_STORE_TMPFS_PCT`), for example `store tmpfs 93% > 90%`. A full tmpfs makes the store
   answer S3 500s, which measure the lab, not the node, so this verdict wins over the criteria: a p99 or 5xx
   failure on a full store is not recorded as a failure of the node. It applies to ramp, refine and confirm steps
   and to `load:swap`. A node that stopped (step 4) is still judged first; the store's share is then added to the
   `notes` of the step. The step file records it as `store.tmpfs_max_pct` of `store.tmpfs_size_mb`. Size the
   tmpfs with `ATANOR_LOAD_STORE_TMPFS_SIZE`.
6. **Criteria.** The step fails when any criterion of the table above broke.
7. **Delivery.** Achieved below 95% of planned: the step is INVALID and the round stops. This is not a
   failure of the node. A saturated node breaks p99 first, so it is a failure, not an invalid step.
   A saturated node that answers too slowly leaves a backlog in the generator. The generator keeps the
   backlog bounded: a request picked up more than `--timeout` (10 s) after it was due, and any request
   still queued or in flight `--timeout + 5` s after the last one was due, is counted as
   `error: not completed`. That is an error, so the step fails (step 6), as a measured saturation; the
   generator still writes its document. INVALID stays for real generator problems: a crash, no file
   descriptors, CPU or swap.

The ramp multiplies the value by 2 from a start (`--start`, `--factor`, or `--steps`) until a step fails;
it then bisects `--refine` times (3) between the last good and the failing value and repeats the best good
value once to confirm it. Every step writes one JSON file, atomically (temporary file, then rename), named
`SCENARIO_MEASURE_NN-PHASE-VALUE.json`, with: scenario and limits, measure, value, planned and achieved,
p50/p95/p99/max, status counts (503 with and without `Retry-After`), node CPU cores, memory (service,
tmpfs, peak since the container started, and the largest `memory.current` of the node's cgroup,
`current_max_mb`; `service_max_mb` and `max_pct_of_limit` are `memory.current - shmem` and its share of the scenario
memory; `tmpfs_start_mb`, `tmpfs_max_mb` and `tmpfs_growth_mb` are the tmpfs at the first sample, its largest size and the growth in the step), descriptors, S3 bytes and trips, host load, validity and the criterion that stopped it.

The ramp steps before the first failure share one node and one store: the tmpfs is not reset between them, the
criterion already excludes it (`memory.current - shmem`), and the container limit has room for the whole tmpfs,
so data left by earlier steps can fill the tmpfs (writes then fail with a full disk) but cannot get the node
OOM-killed. Restarting the node between those steps would lose the warm state they are meant to measure. Each
step records the tmpfs at its start and its growth.

After a failing step, every refine step and the confirmation start on a fresh node: `load-run` runs
`scripts/load-env reset` (`load:down`, then `load:up` without the build: a new node and store with empty data, the
latency applied again, the workers deployed again). A refine on the node that just collapsed would measure the
collapse (memory not given back, a full store, retries), not the rate. Each step file records `fresh_node`
(`true` for those steps) and `reset_s`, the seconds the reset took. A confirmation after a ramp that never failed
keeps the warm node. A node that stopped still ends the round.

Each sample also reads the node's `GET /runtime` ([admin API](how-to-use-the-admin-api.md)) with a 3 second
timeout. The step file keeps `runtime`: the largest of each VM memory type (`memory_max_bytes`), of the
process count and of the cgroup `anon`, `shmem`, `file` and `sock`; `oom_kill` at the end; and, in `at_peak`,
the top processes (by memory and by message queue) and ETS tables of the sample where `memory.current` was
highest. It is `null` when no sample answered (a saturated or dead node), and the step is judged as before.
The report shows the largest cgroup memory and the oom kills of each step.

Every step file also keeps the evidence to tell what the admission gate did, one entry per sample (every `--sample-s`):

- `series`: a list of integer entries, `null` where a source did not answer. `t` is the seconds since the first sample; `memory_current`, `shmem`, `anon` and `inactive_file` come from the node's cgroup; `working_set`, `refusing` (0 or 1), `in_flight`, `refused_memory`, `refused_in_flight` and `refused_disk` from the node's admission (`runtime.admission`, counters since the node started); `beam_total`, `beam_processes`, `beam_binary`, `process_count` and `oom_kill` from the VM and the cgroup events; `store_memory_current`, `store_shmem` (the store's tmpfs use), `store_limit` and `store_s3_errors` (S3 requests the store answered 5xx, from its metrics, since it started) from the store.
- `admission`: the thresholds the node judged against (`limit_bytes`, `refuse_at_bytes`, `max_in_flight`, `disk_budget_bytes`), the refusals counted in the step by reason (`refused`, last sample minus first), `refusing_seen`, and the largest `in_flight` and `working_set_max_bytes`. `null` without `/runtime`.
- `runtime.cgroup_memory_max_bytes`: `memory.max` as the node sees it.
- `store`: `memory_max_mb`, `limit_mb`, `tmpfs_max_mb`, `tmpfs_size_mb`, `tmpfs_max_pct` (the store's tmpfs fill, `ATANOR_LOAD_STORE_TMPFS_SIZE`) and `s3_errors` in the step.

The report adds, per measure, the refusals by reason, whether the gate was refusing, the largest in-flight count, the store tmpfs fill and the store 5xx at the approved step and at the first failing one.

## Settings

Every option has a flag (`--help` on `scripts/load-run`) and an environment variable.

| Setting | Default | Meaning |
| --- | --- | --- |
| `ATANOR_LOAD_SCENARIO` | `A` | `A`: 1 CPU, 512 MB; `B`: 2 CPUs, 2 GB. `ATANOR_LOAD_CPUS`, `ATANOR_LOAD_MEMORY` override the limits. |
| `ATANOR_LOAD_STORE_LATENCY_MS` | 25 | Latency added per trip to the store; 0 removes it. |
| `ATANOR_LOAD_TMPFS_SIZE`, `ATANOR_LOAD_STORE_TMPFS_SIZE` | 256m, 1g | Size of the node's and the store's tmpfs. Added to the memory limit of its container: `ATANOR_LOAD_MEMORY` (and `_STORE_MEMORY`) stay the scenario's memory. |
| `ATANOR_LOAD_STORE_CPUS`, `_STORE_MEMORY`, `_LB_CPUS`, `_LB_MEMORY` | 2, 2g, 2, 512m | Limits of the store and the balancer. |
| `ATANOR_LOAD_OUT` | `load/results/STAMP` | Results directory (git-ignored). |
| `ATANOR_LOAD_STEP_S` | 180 | Seconds of load per step. |
| `ATANOR_LOAD_FACTOR`, `_REFINE` | 2, 3 | Growth of the ramp, bisections. |
| `ATANOR_LOAD_P99_MS` | 250 | p99 that fails an http or cells step. |
| `ATANOR_LOAD_MEMORY_PCT`, `_FD_PCT` | 90, 90 | Share of the limits that fails a ws or cells step. |
| `ATANOR_LOAD_DELIVERY` | 0.95 | Achieved/planned below which a step is invalid. |
| `ATANOR_LOAD_HOST_LOAD_MAX`, `_MIN_AVAILABLE_GB` | 6, 6 | Net host load and free host memory limits. |
| `ATANOR_LOAD_MAX_GENERATOR_SWAP_MB` | 16 | Growth of the load generators' `VmSwap` during a step above which the step is invalid. |
| `ATANOR_LOAD_MAX_HOST_SWAP_GROWTH_MB` | 256 | Growth of the host swap used during a step above which the step is invalid; its level is only recorded. |
| `ATANOR_LOAD_MAX_STORE_TMPFS_PCT` | 90 | Share of the store's tmpfs size, at any sample, above which the step is invalid (before the criteria). |
| `ATANOR_LOAD_WRITE_RATIO`, `_CELLS` | 0.5, 64 | http: share of writes, cells the requests spread over. |
| `ATANOR_LOAD_CELL_PERIOD` | 10 | cells: seconds between the writes to one cell. |
| `ATANOR_LOAD_OPEN_RATE`, `_WS_INTERVAL` | 100, 30 | Sockets opened or cells touched per second; seconds between messages of a socket (the node closes a silent socket after 60 s). |

## Prerequisites

- Docker with Compose (the host needs no `tc`), `jq`, `curl`, Python 3 and the tools of the
  [README](../README.md#requirements) (`mise install`).
- About 4 GB of free memory for the containers and the generator, and an idle host: the harness measures
  the host load and refuses a busy one.
- The first `load:up` builds the node image (several minutes: two Rust NIFs) and the scoreboard. Both workers are deployed with the `atanor` command of that image, so no host CLI is needed.

## Steps

1. Start scenario A (or `ATANOR_LOAD_SCENARIO=B`). It builds, starts the node, the store and the balancer,
   applies and checks the latency, and deploys both workers.

   ```sh
   mise run load:up
   ```

2. Run a ramp. The first run of a measure on a fresh node gives its fixed (idle) memory. Rerunning `load:up`
   on a running cluster is safe, but it keeps the node container (same tmpfs, same BEAM): it reapplies the
   latency and redeploys the workers only. For a fresh node, run `mise run load:down` and then
   `mise run load:up` before each measure. Use one results directory for the whole session.

   ```sh
   export ATANOR_LOAD_OUT=load/results/$(date +%Y%m%d-%H%M%S)
   mise run load:http-native
   mise run load:http-wasm
   mise run load:ws
   mise run load:cells
   ```

   Each task prints one line per step and writes the step files and a summary into `ATANOR_LOAD_OUT`.

3. Swap the node at the last approved WASM rate. This removes node A: it is the last run of a session.

   ```sh
   mise run load:swap
   ```

4. Write the report and remove the containers.

   ```sh
   mise run load:report -- "$ATANOR_LOAD_OUT"
   mise run load:down
   ```

   The report is `ATANOR_LOAD_OUT/report.md`: per scenario and measure, the steps, the cost per unit at the
   approved step, the criterion that stopped the ramp and the command to reproduce it.

## Smoke test

To check the harness without loading anything, run each measure for a few seconds at a low value:

```sh
export ATANOR_LOAD_OUT=/tmp/atanor-load-smoke ATANOR_LOAD_STEP_S=15 ATANOR_LOAD_SAMPLE_S=3
mise run load:up
mise run load:http-native -- --steps 10,20 --refine 0
mise run load:ws -- --steps 20,40 --refine 0 --ws-interval 10
mise run load:cells -- --steps 20,40 --refine 0 --cell-period 5
mise run load:http-wasm -- --steps 10 --refine 0
mise run load:swap -- --rate 10 --swap-warmup 5 --swap-overlap 3 --swap-settle 8
mise run load:report -- "$ATANOR_LOAD_OUT"
mise run load:down
```

Observed on a busy development machine in scenario A (one line per step; a step repeated for host load is
not shown):

```text
http-native 20 req/s: ok; planned 300, achieved 300, p99 192.5 ms -> A_http-native_02-ramp-20.json
ws 40 connections: ok; planned 40, achieved 40, p99 1.3 ms -> A_ws_02-ramp-40.json
cells 40 cells: ok; planned 160, achieved 160, p99 189.6 ms -> A_cells_02-ramp-40.json
swap at 10.0 req/s: ok; swap 3.7 s, p99 peak 320 ms
```

## Troubleshooting

- **`the added latency is not visible`.** The store's qdisc was not applied: the host kernel lacks `sch_netem`
  (`modprobe sch_netem`) or Docker refused `NET_ADMIN`. Run `scripts/load-env latency` to see the round trips.
- **Every step is invalid with `host load`.** Another job keeps the host busy; wait or raise
  `ATANOR_LOAD_HOST_LOAD_MAX` and say so in the result.
- **A ramp ends at the first step.** Read `stop_reason` in its JSON. A 404 or an error on the first request
  means a worker is not deployed: run `scripts/load-env deploy`.
- **`delivery ... < 95%` on a quiet node.** The generator is the limit. Lower `--rate-per-proc` so that more
  processes share the rate, or stop other work on the host.
- **A ws ramp past about 28,000 connections.** One generator address has about 28,000 ephemeral ports towards
  one node address; the generator reports connection errors before the node does.

## Limits

- `memory.peak` is the peak since the container started; the step also records the largest sampled value.
- One generator host: its own CPU is reported (`generator.cpu_cores`) and counted out of the host load.
- Hot cells below the memory policy (`memory: awake_fraction`) may hibernate and wake again; the step records
  the cells awake from the admin API at its end.

Next: [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md),
[how-to-replace-a-node.md](how-to-replace-a-node.md), [design.md](design.md) section 12 for the benchmarks that
run in one VM.
