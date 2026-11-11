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
| Service data | The node's data directory is a tmpfs inside its limit (`ATANOR_LOAD_TMPFS_SIZE`, 256 MB). Memory is reported as `memory.current - shmem` from the container's cgroup `memory.stat`; the tmpfs size is `shmem`, reported apart. The 90% criterion uses `memory.current`, the number the kernel enforces. |
| No swap | Every measured container has `memswap_limit` equal to `mem_limit`, so it cannot swap (zram or disk swap on the host would void the memory numbers). `load-run` checks `docker inspect` (`Memory` set and `MemorySwap` equal to it) and, when readable, the cgroup's `memory.swap.max` (0) before the first step, and refuses to run otherwise (`scripts/load-env check-swap`). Recreate a cluster started before this limit existed with `load:down` and `load:up`. |
| Store | SeaweedFS in its own container (2 CPUs, 2 GB, outside the node's limit), data in tmpfs. |
| Store latency | `tc netem delay 25ms` on the store's network interface, so every answer the store sends waits 25 ms: each trip costs 25 ms more. The node image has `tc`; `atanor-load-tc` joins the store's network namespace with `NET_ADMIN`, applies the qdisc and exits. The qdisc needs no root on the host. A request on a warm connection pays the latency once; a `curl` that opens a connection pays it twice, because the handshake answer waits too. `load:up` checks that the round trip from the node to the store grew by at least 80% of the added latency (observed: 1.0 ms to 51.1 ms for a new connection) and every step records it (`store_rtt_ms`). |
| Balancer | HAProxy (2 CPUs) is in the path only for `load:swap`. The other measures send to the node's address. |
| Generator | `scripts/load-gen`, outside the node's limit: Python `asyncio`, open loop, keep-alive connections, one process per about 600 req/s. Latency counts from the scheduled time of a request. |
| Workers | `AtanorNode.LoadWorker` (native; it is in the node image because a native module must be in the release) and the scoreboard example (WASM). Both are deployed by `load:up`. |

## How a step is judged

Every sample (default every 5 s) reads the node's cgroup (`memory.current`, `memory.stat`, `memory.peak`,
`cpu.stat`), its descriptors (`/proc/PID/fd` of the BEAM, through `docker exec`), the store's
Prometheus counters (`SeaweedFS_s3_request_seconds_count` and bucket traffic, for trips and bytes), `/proc/stat`
and `/proc/meminfo`. Per step, in this order:

1. **Host memory.** `MemAvailable` below 6 GB: the round stops cleanly.
2. **Host load.** Net host load is the cores busy on the host minus the cores the test itself used (node,
   store, balancer, generator), averaged over the step. Above 6, the step is invalid and is repeated (twice,
   after 30 s); then the round stops.
3. **Host swap.** The host's swap used (`SwapTotal - SwapFree`) grew by more than 16 MB during the step (`ATANOR_LOAD_MAX_SWAP_GROWTH_MB`): the step is INVALID, not a failure of the node, and the round stops. The report shows the swap used at the start and the largest sampled value.
4. **Criteria.** The step fails when any criterion of the table above broke.
5. **Delivery.** Achieved below 95% of planned: the step is INVALID and the round stops. This is not a
   failure of the node. A saturated node breaks p99 first, so it is a failure, not an invalid step.

The ramp multiplies the value by 2 from a start (`--start`, `--factor`, or `--steps`) until a step fails;
it then bisects `--refine` times (3) between the last good and the failing value and repeats the best good
value once to confirm it. Every step writes one JSON file, atomically (temporary file, then rename), named
`SCENARIO_MEASURE_NN-PHASE-VALUE.json`, with: scenario and limits, measure, value, planned and achieved,
p50/p95/p99/max, status counts (503 with and without `Retry-After`), node CPU cores, memory (service,
tmpfs, peak since the container started), descriptors, S3 bytes and trips, host load, validity and the
criterion that stopped it.

## Settings

Every option has a flag (`--help` on `scripts/load-run`) and an environment variable.

| Setting | Default | Meaning |
| --- | --- | --- |
| `ATANOR_LOAD_SCENARIO` | `A` | `A`: 1 CPU, 512 MB; `B`: 2 CPUs, 2 GB. `ATANOR_LOAD_CPUS`, `ATANOR_LOAD_MEMORY` override the limits. |
| `ATANOR_LOAD_STORE_LATENCY_MS` | 25 | Latency added per trip to the store; 0 removes it. |
| `ATANOR_LOAD_TMPFS_SIZE`, `ATANOR_LOAD_STORE_TMPFS_SIZE` | 256m, 1g | Size of the node's and the store's tmpfs. |
| `ATANOR_LOAD_STORE_CPUS`, `_STORE_MEMORY`, `_LB_CPUS`, `_LB_MEMORY` | 2, 2g, 2, 512m | Limits of the store and the balancer. |
| `ATANOR_LOAD_OUT` | `load/results/STAMP` | Results directory (git-ignored). |
| `ATANOR_LOAD_STEP_S` | 180 | Seconds of load per step. |
| `ATANOR_LOAD_FACTOR`, `_REFINE` | 2, 3 | Growth of the ramp, bisections. |
| `ATANOR_LOAD_P99_MS` | 250 | p99 that fails an http or cells step. |
| `ATANOR_LOAD_MEMORY_PCT`, `_FD_PCT` | 90, 90 | Share of the limits that fails a ws or cells step. |
| `ATANOR_LOAD_DELIVERY` | 0.95 | Achieved/planned below which a step is invalid. |
| `ATANOR_LOAD_HOST_LOAD_MAX`, `_MIN_AVAILABLE_GB` | 6, 6 | Net host load and free host memory limits. |
| `ATANOR_LOAD_MAX_SWAP_GROWTH_MB` | 16 | Growth of host swap used during a step above which the step is invalid. |
| `ATANOR_LOAD_WRITE_RATIO`, `_CELLS` | 0.5, 64 | http: share of writes, cells the requests spread over. |
| `ATANOR_LOAD_CELL_PERIOD` | 10 | cells: seconds between the writes to one cell. |
| `ATANOR_LOAD_OPEN_RATE`, `_WS_INTERVAL` | 100, 30 | Sockets opened or cells touched per second; seconds between messages of a socket (the node closes a silent socket after 60 s). |

## Prerequisites

- Docker with Compose (the host needs no `tc`), `jq`, `curl`, Python 3 and the tools of the
  [README](../README.md#requirements) (`mise install`).
- About 4 GB of free memory for the containers and the generator, and an idle host: the harness measures
  the host load and refuses a busy one.
- The first `load:up` builds the node image (several minutes: two Rust NIFs) and the CLI and the scoreboard.

## Steps

1. Start scenario A (or `ATANOR_LOAD_SCENARIO=B`). It builds, starts the node, the store and the balancer,
   applies and checks the latency, and deploys both workers.

   ```sh
   mise run load:up
   ```

2. Run a ramp. The first run of a measure on a fresh node gives its fixed (idle) memory; start each measure
   from a fresh `load:up` when you need that number. Use one results directory for the whole session.

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
