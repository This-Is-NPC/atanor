# How to run the load tests

**The question:** How many requests per second, idle WebSocket connections and hot cells does one Atanor
node hold in 1 CPU and 512 MB (scenario A) or 2 CPUs and 2 GB (scenario B), what does each unit cost in
CPU, memory and store trips, and what does a node swap cost at the load that node holds?

This guide stands alone. There is one way to run a round: `mise run load -- --config FILE`. Everything a
round does, from the scenarios to the criteria and the output directory, is a key of that TOML file. The
scenario is the container cluster of [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md)
with one node and no peers; the swap is the one of [how-to-replace-a-node.md](how-to-replace-a-node.md).
Numbers from a development machine say how the harness works, not what a release holds: run the real
rounds on the pinned build.

[Alambique](https://github.com/This-Is-NPC/alambique) uses the same round format (`scenarios`, `judging`,
`host`, `output`, the step plans) with `round.step_timeout_s` at 1800, because its load generator runs inside
its driver; Atanor's default of 600 covers only the separate generator processes. The names of the keys
that both have mean the same in both.

## What is measured

| Measure | Ramp | A step fails when | Cost per unit |
| --- | --- | --- | --- |
| `http-native`, `http-wasm`: reads and writes in cells; same work in both (see [the workers](#the-workers-of-the-http-measures)) | requests per second | p99 > 250 ms, 503 answers over 1% of all answers (stop reason `refused N% > 1%`), any other 5xx, or any error | req/s per vCPU, fixed MB, MB per req/s, S3 trips and bytes per request |
| `ws`: open idle WebSockets, one message per socket every 30 s | connections | working set at 90% of the limit (see [the memory criterion](#the-memory-criterion)), or file descriptors at 90% of the limit, 503 answers over 1% of all answers, or a socket that cannot connect or is dropped | MB and descriptors per connection |
| `http-wasm-jobs`: writes and reads of the scoreboard, a job-heavy WASM app (not comparable with native) | requests per second | the criteria of `http-native` | req/s per vCPU, fixed MB, MB per req/s (its S3 trips and bytes per request are not comparable with native) |
| `cells`: cells written once every 10 s, all awake together | cells | working set at 90% of the limit, p99 > 250 ms, or 503 answers over 1% of all answers; the last two are judged on the hold, after the opening (see [the opening](#the-opening-of-the-cells-measure)) | MB per hot cell |
| `scale`: `http-native` and `cells` on 1, 2 and 3 nodes behind the balancer, then a node joining under load (see [the scale measure](#the-scale-measure)) | requests per second and cells, per node count | the criteria of `http-native` and `cells`, per configuration; the join has no verdict, it records | the ceiling of each configuration, the gain over 1 node, requests and awake cells per node, the time until the load spreads after a join |
| `swap`: node A replaced by B under load | none (one run at `swap.rate`, or at the last approved `http-wasm-jobs` rate of the results directory) | an acknowledged write lost or duplicated, or an answer other than 503 with `Retry-After` (503 with `Retry-After` stays accepted: the refused criterion does not apply) | swap duration and p99 peak |

### The workers of the http measures

| Measure | Worker | Work per request |
| --- | --- | --- |
| `http-native` | `AtanorLoad.Worker` (native) | A write: `INSERT INTO log (v) VALUES (?)`. A read: `SELECT count(*) FROM log`. One cell per key. |
| `http-wasm` | `load-plain`, [examples/load-plain](../examples/load-plain) (WASM, the twin of the native worker) | The same statements on the same keying, on `/plain/CELL`. |
| `http-wasm-jobs` | `scoreboard`, [examples/scoreboard](../examples/scoreboard/README.md) (WASM app) | A write records a score and enqueues a ranking job that runs in the same cell; a read counts and ranks. |

`http-wasm` and `http-native` do the same work, so their numbers compare the runtimes. The scoreboard is an app
workload with a job per write: it makes about 4.7 segment uploads and 14.5 KB per request, against 1.1 uploads and
436 B for the native worker, so its S3 trips and bytes per request are not comparable with native. A triage found
a plain WASM guest at 1.16 puts and 410 B per request, so the runtime itself costs no more trips than native.
[test/atanor/load_plain_twin_test.exs](../test/atanor/load_plain_twin_test.exs) keeps the two within 25% of each other.
The scoreboard stays the swap's workload and its rate comes from `http-wasm-jobs`.

## Prerequisites

- Docker with Compose (the host needs no `tc`), `jq`, `curl`, Python 3.11 or later (for `tomllib`) and the
  tools of the [README](../README.md#requirements) (`mise install`).
- About 4 GB of free memory for the containers and the generator, and an idle host: the harness measures
  the host load: it waits for a quiet host before each step and stops when the host does not calm down.
- The first lab start builds the node image (several minutes: two Rust NIFs), the plain worker and the
  scoreboard. The three workers are deployed with the `atanor` command of that image, so no host CLI is needed.
- For `--remote`: `ssh` access to a host that has a clone of this repository with the same tools, and the
  round file committed in that clone.

## Steps

1. **Write a round file.** Copy [load/rounds/example.toml](../load/rounds/example.toml), which lists every key
   at its default, and keep only the keys that you change. [load/rounds/018f.toml](../load/rounds/018f.toml) is
   the official round 018f: scenarios A and B, the store on disk, fixed ladders.

   ```sh
   cp load/rounds/example.toml load/rounds/my-round.toml
   ```

2. **Check it and read the plan.** The file is validated first: a wrong key, type or range, or a plan that
   cannot run, refuses the round with every problem listed, before any container starts. `--dry-run` prints
   the plan and starts nothing.

   ```sh
   mise run load -- --config load/rounds/my-round.toml --dry-run
   ```

   The dry run of the official round starts like this:

   ```text
   Round load/rounds/018f.toml: 13 cases, results in .../load/results/018f
     skip-done on; each generator process is killed after 600 s (round.step_timeout_s); no round timeout
     1. A/http-native      ladder, values 490, 650, 810, 975 req/s; at most 8 steps (3 refine, 1 confirm), 180 s each
          lab    scenario A
          output A/http-native/
          hash   54fc3a5d2debb3a79e5d039f705c0cb17474a4feff0aa78a1ce007d4f6ae28c5
   ```

   `mise run load:config-check -- --check FILE` prints the resolved config and its hash.

3. **Run it.** For each scenario the command starts the lab, runs the measures, writes the report and, at the
   end, removes the lab, also after a failure.

   ```sh
   mise run load -- --config load/rounds/my-round.toml
   ```

   It prints one line per step. The exit status is 0 when every measure recorded a verdict, 1 when a measure
   ended INVALID or the round was stopped (`round.timeout_s`), and 2 when the file is refused.

4. **Run it on another host (optional).** With `host.ssh` and `host.repo` set in the file, `--remote` runs the
   round there, detached, so that it survives your session. It copies nothing: it runs
   `cd REPO && git fetch && git status` on the host and refuses when the clone has local changes, is not at the
   commit of your local `HEAD`, or does not have the round file (it prints both commits). Then it starts
   `setsid nohup timeout --kill-after=60 HOST.TIMEOUT_S mise run load -- --config FILE ...` there and writes
   `round.pid` and `round.log` in the results directory on the host (`host.results`, else `output.dir`, else
   `load/results/NAME` under the clone; set `output.name` or `output.dir` so that the next two commands find it).
   Nothing remote happens without one of these three flags.

   ```sh
   mise run load -- --config load/rounds/my-round.toml --remote   # check the clone, start the round there
   mise run load -- --config load/rounds/my-round.toml --status   # is it alive, and the end of its log
   mise run load -- --config load/rounds/my-round.toml --fetch    # copy the results to the local output dir
   ```

   `--status` prints whether the process of `round.pid` is alive and the last 20 lines of `round.log`, without
   the lines that match `token`, `secret`, `key`, `credential` or `password`. `--fetch` copies the results
   directory of the host (with `rsync` when there is one, else `scp -r`) into the local `output.dir`, which
   you can run again as often as you like while the round goes on. The round is killed after `host.timeout_s`
   (172800 s, 48 hours, by default).

5. **Rerun after a stop.** Run the same command again. With `--skip-done` (the default) the steps that have a
   file with the same hash are reused and the round goes on from the first step that has none, or that was
   INVALID. A case whose steps and summary are all done is reused without starting a lab. Changing a key that
   affects a case changes its hash, and the next run refuses until you set another `output.name` or pass
   `--no-skip-done`, which runs every step again and overwrites its file.

6. **Read the report.** `report.md` in the results directory has, per scenario and measure, the steps, the
   cost per unit at the approved step, the criterion that stopped the ramp and the command to reproduce it.
   `mise run load:report -- DIR` writes it again for a directory.

The other `load:` tasks are helpers, not ways to run a round: `load:up` and `load:down` (arguments
`--config FILE [--scenario S]`) start and remove the lab of one scenario for a manual look, `load:report`
writes a report, and `load:config-check` prints a resolved config.

## The config

Every key has a default in `scripts/load_config.py`; [load/rounds/example.toml](../load/rounds/example.toml)
shows them all with a comment and is the reference for the keys. A file needs only the keys it changes. An
unknown key, a wrong type or a value out of range is refused with a suggestion.

| Section | What it sets |
| --- | --- |
| `[round]` | `scenarios` and `measures` (each scenario runs the measures in order), or `cases`: `"A/http-native"` entries in the order to run (not with `run_on`); `step_timeout_s` (600), `timeout_s` (0: no limit). |
| `[output]` | `dir`, or `name` for `load/results/NAME`; without either, `load/results/` plus a time stamp. |
| `[host]` | `ssh`, `repo`, `results` and `timeout_s` of `--remote`, `--status` and `--fetch`. |
| `[scenarios.A]`, `[scenarios.B]` | The node: `cpus`, `memory`, `data_tmpfs` (the size of its data tmpfs) and `nodes`. |
| `[store]`, `[balancer]` | The store's `backing` (`tmpfs` or `disk`), `tmpfs_size`, `memory`, `cpus`, `latency_ms`; the balancer's `cpus` and `memory`. |
| `[node]` | `http_max_connections` (0 keeps the node's 16384). |
| `[measures.NAME]` | `run_on`; `steps` and `per_scenario.A/B` (the plan); `store` and `judging` overrides for that measure. |
| `[judging]` | The criteria and the INVALID rules (below). |
| `[generator]`, `[workload]` | The load generator (`rate_per_proc`, `conns_per_rate`, `timeout_s`, `grace_s`, `sample_s`) and the work (`write_ratio`, `cells`, `warmup`, `cell_period_s`, `cells_conns`, `open_rate`, `ws_interval_s`, `worker`). |
| `[swap]`, `[scale]` | The swap (`rate`, `trigger`, `workers`, `warmup_s`, `overlap_s`, `settle_s`, `timeout_s`) and the scale measure (`max_nodes`, `loads`, `factor`, `ceilings`, `ceiling_factors`, `per_scenario`, `join`, `spread`). |

**Step kinds.** `kind = "bisect"` grows from `start` by `factor` up to `max` and, after the first failing step,
bisects `refine` times between the last good and the failing value. `kind = "ladder"` runs the fixed `values`
(strictly growing). `kind = "ceiling"` runs a ladder of `factors` (75%, 100%, 125%, 150%) times `ceiling`, the
ceiling that an earlier round found: it is the exploration round, a short check of the steps around a known
ceiling (set `duration_s = 75`, `refine = 0` and `confirm = false` for the 75 s, no-refine, no-confirm
version). `confirm = true` repeats the best good step once on a fresh node. `per_scenario.A` or `.B`
overrides any key of `steps` for that scenario; the scale measure takes `ceilings` and `ceiling_factors`
per scenario with `[scale.per_scenario.A]`.

**Judging rules.** `[judging]` has one table per rule, each with `enabled` and its limits; a rule that is off is not
judged. A limit is exclusive: a step fails or is INVALID when it goes above it (below it, for a minimum).
`stall_repeats` (1) is how many times a step that was INVALID by a stall is repeated.

| Rule | Limit (default) | Effect when broken |
| --- | --- | --- |
| `errors` | none | FAIL: any 5xx answer other than a 503 refusal, or any request error (every measure but `ws`) |
| `p99` | `max_ms` (250) | FAIL: p99 latency, every measure but `ws` |
| `refused` | `max_pct` (1) | FAIL: share of 503 answers among all answers, every measure but `swap` |
| `memory` | `max_pct` (90) | FAIL: working set share of the scenario memory, `ws` and `cells` |
| `fds` | `max_pct` (90) | FAIL: open descriptors share of the limit, `ws` |
| `delivery` | `min_ratio` (0.95) | INVALID: achieved over planned, the generator or the host, not the node |
| `store_fill` | `max_tmpfs_pct`, `max_disk_pct` (90) | INVALID: the store's tmpfs (on disk: its filesystem) share used at any sample |
| `store_stall` | `min_ms` (1000), `min_requests` (10), `window_s` (5), `fail_on_repeat` (true) | INVALID `stall:` on a step that would fail: slow node-to-store requests in the node log; when both attempts stall the step FAILS with `store:` |
| `generator_lag` | `max_ms` (50) | INVALID `stall:`: the generator's own release lag p99 |
| `throttle` | `max_jump_ms` (5000), `jump_factor` (5) | INVALID `stall:`: growth of the node's CPU throttling between two samples, and this many times the median growth |
| `host_load` | `max` (1), `quiet_window_s` (60), `quiet_max_wait_s` (1800) | The foreign load of the host: a step waits for it; a step whose mean exceeds `max` is INVALID |
| `host_busy` | `max_share` (0.85) | INVALID: mean busy cores of the host over this share of its cores |
| `generator_swap` | `max_mb` (16) | INVALID: growth of the generators' `VmSwap` in a step |
| `host_swap` | `max_growth_mb` (256) | INVALID: growth of the host's swap used during a step |
| `host_memory` | `min_available_gib` (6) | The round stops when the host's `MemAvailable` is below this many GiB |

**One measure, other rules.** `[measures.NAME.judging.RULE]` overrides any key of `[judging.RULE]` for that
measure only (and `[measures.NAME.judging] stall_repeats`). It is merged over the general rule, enters the hash of
that measure's case and leaves the other measures alone. Example: `[measures.ws.judging.refused]` with
`max_pct = 5` lets `ws` pass with up to 5% refused. `[measures.NAME.store]` overrides `backing`, `tmpfs_size` and
`latency_ms` of `[store]` for that measure, which then gets a lab of its own; the next measure goes back to the
scenario's lab. The table `[measures.NAME.variant.V.store]` is reserved for variants and is refused for now: no
Atanor measure has one.

**Timeouts.** Every load generator process runs under `timeout --kill-after=10s`, killed after
`round.step_timeout_s`. A step whose generator was killed is INVALID, reason `timeout`. The file is refused
when `step_timeout_s` is below a plan's `duration_s` plus `generator.grace_s` (or the join of the scale
measure). `round.timeout_s` bounds the whole round: when it passes, the round stops (`STOP`, exit 1), and
what is done stays for `--skip-done`. The reset of the node and the store and the wait for a quiet host are not
under `step_timeout_s`.

## Results

Under the output directory:

```text
config.toml                                  the resolved config of the round
SCENARIO/MEASURE/step-VALUE.json             one step
SCENARIO/MEASURE/step-VALUE-2.json           the confirmation of a value that was already measured
SCENARIO/MEASURE/summary.json                the verdict of the measure
SCENARIO/MEASURE/baseline.json               the idle node, before the load
SCENARIO/scale/http-native-n2/step-998.json  scale: the load and the node count are the variant
SCENARIO/scale/join/step-RATE.json           the join
report.md                                    written by load:report
```

Besides each step file are the diagnostics of a node that stopped or a step that failed: `step-VALUE.node-state.txt`,
`.node.log`, `.store.log` and `.store-metrics.txt`. Each step file has its `phase` (`ramp`, `refine`, `confirm`) and
the `config_hash` of its case; a stall repeat keeps its `first_attempt` inside the same file. The hash is the hash
of the resolved config restricted to what affects the case: the scenario, the store with the measure's override, the
balancer, the node, the judging with the measure's overrides, the generator, the workload, the measure's plan and,
for the swap and the scale measure, their sections. It leaves out `output`, `host`, `round` and the other measures'
plans, so a change to one measure leaves the done steps of the others valid. `load:report` also reads the flat layout
of the older results.

### The verdicts

| `status` | `valid` | Meaning |
| --- | --- | --- |
| `ok` | true | Every criterion held. |
| `fail` | true | A criterion broke, or the node stopped: a result. The `stop_reason` names the criteria; `criteria` lists them. A step whose store stalled twice has `store: stalled at this step twice (EVIDENCE); failed on: CRITERIA`, so the criterion that made it fail is not lost. |
| `invalid` | false | The lab, not the node, broke: there is no verdict. |

The summary of a ramp has `approved` (the confirmed value, or the last good one when the node stopped), `good`,
`confirmed`, `first_failure`, `stopped_by`, `invalid`, `node_stopped` and `ceiling_reached`. A failed step of a
ramp, a stopped node and an approved value are results (exit 0); an INVALID step is exit 1. The swap, a single
check and not a ramp, also exits 1 when it failed. The swap starts node B from the image of the load environment
(`atanor-cluster-load:local`, set once in `scripts/load-common`); if B exits or turns unhealthy before it serves,
the swap stops at once with B's exit status and its last log lines. The reason is in `stop_reason` of the step file
and in `swap-TIME.log` next to it.

## Measured results

These are the values of the official round 018f ([load/rounds/018f.toml](../load/rounds/018f.toml)). They are
measurements of one lab host, not guarantees. The host was one VM with 4 vCPUs and about 5 GB of RAM. The store
was SeaweedFS on the disk of that VM. Alambique was the pin v0.11.0. The first four scenario A measures ran on
Atanor commit `3e32ed0` and the rest on `f853a15`. Run the round on your own hardware before you size.

Scenario A is a node limited to 1 CPU and 512 MB. Scenario B is 2 CPUs and 2 GB. The criteria are the ones of
[how a step is judged](#how-a-step-is-judged) at the defaults of the round file: p99 over 250 ms, 503 answers
over 1% of all answers, any other 5xx or any error, the working set at 90% of the memory limit. Each value
below was approved with the refine and confirm phases, unless a row says otherwise. Rates are requests per second.

| Measure | A (1 CPU, 512 MB) | B (2 CPUs, 2 GB) |
| --- | --- | --- |
| `http-native` | 590. Failed at 650 with p99 338 ms. | 1641. Failed at 1875 with p99 271 ms. |
| `http-wasm` | 450. Failed at 800: 3.2% of the answers were refused (`worker_queue`). | No approved value. The best step was 1300 with p99 139 ms. Its confirmation failed because the lab store stalled twice: a limit of the lab, not of the node. |
| `ws`, connections | 3300. Failed at 4000: working set at 90%. | 22500. Failed at 25000: 695 connections failed and the working set was at 93.6%. |
| `cells`, hot cells | 397. Failed at 470 with p99 475 ms. | 2438. Failed at 2500 with p99 515 ms. |
| `http-wasm-jobs` | 68, the top of the ladder: nothing failed. | 109. 112 failed because the lab store stalled twice: a limit of the lab. |
| `swap` | ok at 68 req/s. 212 responses were 503 `held_elsewhere` during the swap. | ok at 109 req/s. The swap took 11.8 s, the p99 peak was 593 ms and 366 responses were 503 `held_elsewhere`. |

A later run of the `cells` measure on the same code in A failed 397 at p99 267 ms and approved 372. Read the
ceiling of A cells as between about 370 and 400: that is the run-to-run noise of the lab.

The scale measure ran on scenario A, with one and two nodes behind the balancer:

| Configuration | One node | Two nodes | Gain |
| --- | --- | --- | --- |
| `http-native` | 600, confirmed | 998, confirmed | 1.66, an efficiency of 0.83 |
| `cells` | 372, confirmed | 695, the best step, not confirmed (the confirmation had p99 278 ms) | 1.87, not confirmed |

A node that joined at 900 req/s was judged ok. The requests spread over the nodes in 20.8 s and the cells in
199.5 s. The scale measure is described in [the scale measure](#the-scale-measure).

## How the environment is built

One container per service, all of the project `atanor-cluster` (`scripts/cluster-*`), plus the throwaway
`atanor-load-tc`. Nothing else on the host is touched. The lab's settings come from the round file only; the scripts
read them through `scripts/load_config.py --env`. The only environment variables left are those that depend on the
host (`ATANOR_CLUSTER_UP_TIMEOUT`, `ATANOR_CLUSTER_BUILD_JOBS`, `ATANOR_LAB_DIR`) and the internal ones between
`scripts/load` and the scripts it starts (`ATANOR_LOAD_CONFIG`, `ATANOR_LOAD_SCENARIO`, `ATANOR_LOAD_MEASURE`,
`ATANOR_LOAD_NODES`, `ATANOR_LOAD_HTTP_MAX_CONNECTIONS`); do not set those yourself.

| Piece | How |
| --- | --- |
| Node | One container, `cpus` and `mem_limit` from the scenario (A: 1 and 512 MB; B: 2 and 2 GB), no peers. |
| Service data | The node's data directory is a tmpfs (`scenarios.S.data_tmpfs`: 256 MB in scenario A, 1 GB in B). The node derives its disk budget from the size of that file system, and its disk reclaim puts idle cells to sleep at 70% of the budget; B's `cells` step grew the data by 191 MB, so a 256 MB tmpfs (a budget of 205 MB) made the reclaim hibernate cells (1315 awake of 1500) and the step was judged on wake churn. A tmpfs counts against its container's memory limit, so the container's limit (`mem_limit` and `memswap_limit`) is the scenario memory **plus** the tmpfs size (scenario A: 512 + 256 = 768 MB; B: 2048 + 1024 = 3072 MB), so that a full tmpfs cannot get the node OOM-killed. Every node of a cluster gets the same tmpfs, the ones `load-env add-node` starts for the join included. A step or join on 2 or more nodes records each node's `disk_budget_bytes` (`per_node`, and `disk_budget_bytes` in the join file) and adds the note `nodes differ in disk_budget_bytes: node-1 N, node-2 M` when they are not equal. The node itself is given the scenario memory as its limit (`ATANOR_MEMORY_LIMIT`), not the container limit, so its gates and the awake and WASM waiting limits it derives from the limit are those of a 512 MB (A) or 2 GB (B) machine. The tmpfs is a lab stand-in for the disk of a real machine; the node's working set counts it, so a tmpfs that fills takes memory from the 512 MB, which is conservative. `shmem`, the tmpfs, is reported apart. |
| No swap | Every measured container has `memswap_limit` equal to `mem_limit`, so it cannot swap (zram or disk swap on the host would void the memory numbers). `load-run` checks `docker inspect` (`Memory` set and `MemorySwap` equal to it) and, when readable, the cgroup's `memory.swap.max` (0) before the first step, and refuses to run otherwise (`scripts/load-env check-swap`). |
| Store | SeaweedFS in its own container (`store.cpus`, `store.memory` plus its tmpfs of `store.tmpfs_size`, outside the node's limit), data in tmpfs, or on the host's disk with `store.backing = "disk"` ([when to use it](#when-the-store-fills-its-tmpfs)). |
| Store latency | `tc netem delay` of `store.latency_ms` (25) on the store's network interface, so every answer the store sends waits that long: each trip costs 25 ms more. The node image has `tc`; `atanor-load-tc` joins the store's network namespace with `NET_ADMIN`, applies the qdisc and exits. The qdisc needs no root on the host. A request on a warm connection pays the latency once; a `curl` that opens a connection pays it twice, because the handshake answer waits too. The lab start checks that the round trip from the node to the store grew by at least 80% of the added latency and every step records it (`store_rtt_ms`). Both time the second of two requests of one `curl` run, on the reused connection, which is the cost of one trip as the node pays it; the line reads `store round trip from the node, on a reused connection: A ms -> B ms`. |
| Balancer | HAProxy (`balancer.cpus`) is in the path for `swap` and `scale`. The other measures send to the node's address. |
| Generator | `scripts/load-gen`, outside the node's limit: Python `asyncio`, open loop, keep-alive connections, one process per about 600 req/s (`generator.rate_per_proc`). Latency counts from the scheduled time of a request. |
| Workers | `AtanorLoad.Worker` (native, [cluster/load/lib/atanor_load/worker.ex](../cluster/load/lib/atanor_load/worker.ex); the lab start builds the image `atanor-cluster-load:local` from [cluster/load/Dockerfile](../cluster/load/Dockerfile), a [derived image](how-to-build-a-derived-image.md) of the release with the tools of the harness target, because a native module must be loaded in the node), the plain WASM worker `load-plain` (`mise run build:load-plain`, [examples/load-plain](../examples/load-plain)) and the scoreboard example (WASM). All three are deployed when the lab starts. |

## How a step is judged

Every sample (every `generator.sample_s`, 5 s) reads the node's cgroup (`memory.current`, `memory.stat`,
`memory.peak`, `cpu.stat`), its descriptors (`/proc/PID/fd` of the BEAM, through `docker exec`), the store's
Prometheus counters (`SeaweedFS_s3_request_seconds_count` and bucket traffic, for trips and bytes), `/proc/stat`
and `/proc/meminfo`. Per step, in this order (the limits are the `[judging]` rules above):

0. **Quiet host.** Other sessions on the machine (a `cargo test`, a build) run heavy jobs that nobody
   coordinates with the lab. Before every step (after the reset of a fresh node) and before the swap,
   `load-run` samples the net host load and waits until it stays below `host_load.max` for
   `quiet_window_s` in a row; a burst restarts the window. If that does not happen within `quiet_max_wait_s`
   the measure stops with `host busy: ...` and exits 1. The wait measures the same net load as the step, with
   the lab's own CPU (node, store, balancer, harness) counted out.
1. **Host memory.** `MemAvailable` below `host_memory.min_available_gib`: the round stops cleanly.
2. **Host load.** Net host load is the cores busy on the host minus the cores the test itself used (node,
   store, balancer, generator and the harness), averaged over the step. Above `host_load.max`, the step is
   invalid (`host contaminated: net load 1.6 > 1`), the round stops and `load-run` exits 1. Nothing repeats
   silently. An interval between two samples counts only when every CPU reading of the lab (node, store and
   balancer cgroups, generators, harness) exists in both samples and the host idle counter did not go back; a
   failed cgroup read would otherwise subtract all the CPU the container had accumulated and show tens of
   foreign cores. The mean covers the counted intervals; `host.net_load_skipped` in the step JSON is how many
   were left out. The quiet wait leaves them out too, and a skipped interval ends the quiet run. When every
   interval of a step is skipped the step is not judged by this rule. The same step is also INVALID when the
   host itself ran out of cores: the mean busy cores (`host.busy_cores_mean`, the lab's own CPU included) above
   `host_busy.max_share` of the host's cores, for example `host saturated: 3.6 busy cores > 3.4 (85% of 4
   cores)`. The generator, the balancer, the store and the nodes share the host, so a node that cannot get a
   core is not at its own limit. The generator's lag cannot show this: it includes the wait for a slow node
   (`generator.lag_p99_ms`), and the generator's own release lag (the stall check, step 6) stays small while the
   host is full. This verdict follows the foreign-load one and the round stops.
3. **Swap.** The step is INVALID (not a failure of the node; the round stops) when any of these holds:
   - a measured container (node, store or balancer) swapped: its cgroup `memory.swap.current` was above 0 at any sample. It is read from the host through the cgroup of the container's init PID, with the other cgroup reads. When it is unreadable it is recorded as null and not judged;
   - the `VmSwap` of the load generators (`/proc/PID/status`, summed over the processes `load-run` started and their children) grew by more than `generator_swap.max_mb`;
   - the host's swap used (`SwapTotal - SwapFree`) grew by more than `host_swap.max_growth_mb` during the step: the largest sample minus the value at the start.

   The level of host swap is only recorded, never judged: a host may hold gigabytes of old swap that the step does not touch. Each step file records host swap start, max and growth, generator swap start, max and growth, and the largest swap of each measured container; the report shows the generator swap growth and the largest host swap. The `swap` measure applies the same rule (the node A container is removed during that run, so its swap reads as null afterwards).
4. **Node stopped.** A node that breaks at its limit is a result, not a crash of the runner. After the
   step, and when the generator fails, `load-run` runs `docker inspect` on the node container and compares
   it with its state at the start of the step. The step FAILS, and the ramp bisects or stops as for any other
   failure, with the reason `node OOM-killed`, `node exited CODE` (for example 137), `node restarted` (same
   container started again, or a new one) or `node container gone`. It is judged before the invalid checks
   (host load, swap, delivery). It saves `NAME.node-state.txt` (the container state) and `NAME.node.log` (the
   whole log since the container started, the last 5 MB of it when longer) next to the step file, before the lab is removed. A step that fails on a criterion with the node still running saves the same two files, and both cases also save `NAME.store.log` (the store container's log with its timestamps) and `NAME.store-metrics.txt` (its Prometheus metrics) before the harness replaces the store. The lines of the store log and metrics that name a token, key, secret or credential are dropped. A node that is fine
   while a side measurement fails (the store round trip, the awake cells, the descriptors) keeps its step as
   measured: the value is null and `notes` in the step file says what was not measured.
   The nodes do not restart (`restart: "no"`), so the round ends at a node stop: no bisection and no
   confirmation. The summary has `node_stopped: true`, `first_failure` and `stopped_by` from that step, and
   `approved` is the last good value (no confirmation repeat); `load-run` still exits 0. A step that finds the
   node not running at its start runs no generator: it is INVALID ("node not running at step start") and ends
   the round the same way.
5. **Store tmpfs.** The step is INVALID (the round stops) when the store's tmpfs passed `store_fill.max_tmpfs_pct`
   of its size at any sample, for example `store tmpfs 93% > 90%`. A full tmpfs makes the store answer S3 500s,
   which measure the lab, not the node, so this verdict wins over the criteria: a p99 or 5xx failure on a full
   store is not recorded as a failure of the node. It applies to ramp, refine and confirm steps and to the swap. A
   node that stopped (step 4) is still judged first; the store's share is then added to the `notes` of the step. The
   step file records it as `store.tmpfs_max_pct` of `store.tmpfs_size_mb`. Size the tmpfs with `store.tmpfs_size`.
   With `store.backing = "disk"` there is no store tmpfs to judge; the same verdict is made on the share of the
   store's filesystem used (`store_fill.max_disk_pct`), for example `store disk 93% > 90%`.
6. **Stall.** The step is INVALID, with a reason that starts with `stall:`, when the lab stopped for a moment
   and failed the step by chance: the generator's own lag p99 (`generator.release_lag_p99_ms` in the step file,
   how late the generator put requests in its queue) is above `generator_lag.max_ms` (normal steps show 1 to
   8 ms), or the node's CPU throttling (`node_throttled_ms` in `series`) grew between two consecutive samples by
   more than `throttle.max_jump_ms` and by more than `throttle.jump_factor` times the median growth per sample of
   the step. A node saturated at every sample throttles at every sample, so its median is high and it is not
   flagged. A step whose generator lags is not a measurement of the node. A node above its ceiling answers
   slowly, the generator's keep-alive connections are all busy, and requests wait for a free one:
   `generator.lag_p99_ms` (how late requests left against the schedule) grows, but `release_lag_p99_ms` stays
   small because the generator itself is on time. That step is not a stall: it is judged by the criteria
   (usually p99) and fails, so the ramp refines. A step file from a generator that does not report
   `release_lag_p99_ms` (`null`) is judged on `lag_p99_ms`.

   The store can stall too: a second where its answers all take about a second (observed: 64 node-to-store requests of
   1.0 to 1.1 s in the last second of a step, in-flight up to 225, p99 651 ms, while the rest of the step was healthy).
   That is the store's fault, not the node's ceiling. When a step would fail on a criterion, `load-run` reads the node's
   log from the start of the step (`docker logs --since`) and counts the lines `HTTP request PUT store:8333 took N ms`
   with N at or above `store_stall.min_ms`. When `store_stall.min_requests` of them fall within `window_s`, the
   step is INVALID with `stall: store stalled, N node-to-store requests took >= 1000 ms within 5 s (slowest M
   ms)`. The evidence is `store_stall` in the step file (`slow_requests`, `max_ms`, `window_requests`, `window_s`,
   `threshold_ms`, `min_requests`, `stalled`); it is `null` when the log showed no slow request, and a step that
   passed is not read. Unlike the other INVALID verdicts, a stall repeats the step (`stall_repeats` times; a fresh
   node when the step is fresh), so one chance event does not stop the round: the first attempt is kept in
   `first_attempt` of the step file and in `notes`. When the repeat is INVALID too, the usual INVALID path
   applies: the round stops and `load-run` exits 1. The exception is a store that stalls in both attempts (with
   `store_stall.fail_on_repeat`): it stalls at this load every time, so that is the lab store's limit and not a
   chance event. The step **fails**, valid, with `store: stalled at this step twice (EVIDENCE); failed on:
   CRITERIA`, where CRITERIA are the criteria that made the step fail (for example `refused 1.2% > 1%`; also the
   list `criteria` of the step file), so the ramp's ceiling is the step before and the round goes on; the
   report shows the reason, so a ceiling set by the store is not read as the node's.
7. **Criteria.** The step fails when any criterion of the table above broke.
8. **Delivery.** Achieved below `delivery.min_ratio` of planned: the step is INVALID and the round stops. This
   is not a failure of the node. A saturated node breaks p99 first, so it is a failure, not an invalid step.
   A saturated node that answers too slowly leaves a backlog in the generator. The generator keeps the
   backlog bounded: a request picked up more than `generator.timeout_s` (10 s) after it was due, and any request
   still queued or in flight `timeout_s + 5` s after the last one was due, is counted as `error: not completed`.
   That is an error, so the step fails (step 7), as a measured saturation; the generator still writes its
   document. INVALID stays for real generator problems: a crash, no file descriptors, CPU or swap.

In short, what makes a step INVALID (no verdict on the node):

| Cause | Limit (rule) | Repeated? |
| --- | --- | --- |
| Host busy or contaminated | net load 1 core (`host_load`) | no, the round stops |
| Host saturated | mean busy cores over 85% of the host's cores (`host_busy`) | no, the round stops |
| Swap | 16 MB generator, 256 MB host growth, any in a measured container (`generator_swap`, `host_swap`) | no, the round stops |
| Store full | 90% of its tmpfs or disk (`store_fill`) | no, the round stops |
| Stall | generator release lag p99 over 50 ms, a throttling jump over 5000 ms and 5 times the median, or on a failing step 10 node-to-store requests of 1000 ms or more within 5 s (`generator_lag`, `throttle`, `store_stall`) | `stall_repeats` times; the round stops if the repeat stalls too, except a store that stalls in both: that step fails (`store:`) and the round goes on |
| Delivery | achieved under 95% of planned (`delivery`) | no, the round stops |

Every step writes one JSON file, atomically (temporary file, then rename), with: scenario and limits, measure,
value, planned and achieved, `achieved_rate` (completed requests per second) and `useful_rate` (non-503 answers
per second), p50/p95/p99/max, status counts (503 with and without `Retry-After`), node CPU cores, memory (service,
tmpfs, peak since the container started, and the largest `memory.current` of the node's cgroup,
`current_max_mb`; `service_max_mb` and `max_pct_of_limit` are the working set (`memory.current - inactive_file`,
what the node's memory gate reads, tmpfs included) and its share of the scenario memory (the node refuses at 85%
of it, the criterion fails the step at 90%); `tmpfs_start_mb`, `tmpfs_max_mb` and `tmpfs_growth_mb` are the tmpfs at
the first sample, its largest size and the growth in the step), descriptors, S3 bytes and trips, host load,
validity, `criteria` and the criterion that stopped it.

### The memory criterion

The node's memory gate and the `ws` and `cells` criterion read the same number: the working set of the node's
cgroup, `memory.current` minus `inactive_file` (tmpfs included), against the same limit, the scenario memory (A 512 MB, B 2 GB).
The node refuses new requests at 85% of it (503 `overloaded`, reason `memory`; the step file's `refusing_seen` and
`refused_memory` show it) and the harness fails the step at `memory.max_pct` (90). The gates do not close open
WebSockets (design §7.1, a documented decision): sockets opened below 85% keep their memory, and their growth
(messages, buffers) can take a `ws` step past 90% with no refusal to show for it. The step then fails with the stop reason
`working set N% of the scenario limit >= 90%`, and `refusing_seen` is true only if the node refused something on the way
(for example the opening of more sockets). That is a result about the sockets held, not a defect of the gate.

The ramp steps before the first failure share one node and one store: the tmpfs is not reset between them and the working set counts it,
and the container limit has room for the whole tmpfs, so data left by earlier steps can fill the tmpfs (writes
then fail with a full disk) but cannot get the node OOM-killed. Restarting the node between those steps would lose the warm state they are meant to measure. Each
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

Every step file also keeps the evidence to tell what the admission gate did, one entry per sample (every `generator.sample_s`):

- `series`: a list of integer entries, `null` where a source did not answer. `t` is the seconds since the first sample; `memory_current`, `shmem`, `anon` and `inactive_file` come from the node's cgroup; `working_set`, `refusing` (0 or 1), `in_flight`, `refused_memory`, `refused_in_flight` and `refused_disk` from the node's admission (`runtime.admission`, counters since the node started); `beam_total`, `beam_processes`, `beam_binary`, `process_count` and `oom_kill` from the VM and the cgroup events; `store_memory_current`, `store_shmem` (the store's tmpfs use), `store_limit` and `store_s3_errors` (S3 requests the store answered 5xx, from its metrics, since it started) from the store; `store_breaker_open` (1 when a store breaker of the node was open or half-open in that sample, from `runtime.store`) and `node_throttled_ms` (the node cgroup's CPU throttled time since it started, `cpu.stat`) place a stall in the step. `stalls` in the step file tells a stop of the whole VM from a node or store fault: `ticker_stalls` are the times (seconds from the first sample, as `t` of `series`) when a 0.1 s sleep of the harness's own process overshot by a second or more, `breaker_open_at_s` the samples with an open breaker, and `vm_pause_suspected` is true when a stall came within 10 s before the first of them. Together with a high `generator.release_lag_p99_ms`, it points at the VM and not at the node or the store. The node log has the breaker opening and closing with their times (`atanor: store breaker open ...`) and the store errors behind it.
- `admission`: the thresholds the node judged against (`limit_bytes`, `refuse_at_bytes`, `max_in_flight`, `disk_budget_bytes`), the refusals counted in the step by reason (`refused`, last sample minus first), `refusing_seen`, and the largest `in_flight` and `working_set_max_bytes`. `null` without `/runtime`.
- `runtime.cgroup_memory_max_bytes`: `memory.max` as the node sees it.
- `store_backing` (`tmpfs` or `disk`, from `load-env info`) and `store.backing`: where the store's data was.
- `store`: `memory_max_mb`, `limit_mb`, `tmpfs_max_mb`, `tmpfs_size_mb`, `tmpfs_max_pct` (the store's tmpfs fill) and `s3_errors` in the step; on disk, `tmpfs_max_pct` is null and `disk_used_max_mb`, `disk_free_min_mb` and `disk_max_pct` (from `df /data` in the store container) take its place.
- `refusals`: the 503 answers of the step set against every refusal counter the node reports (`runtime.admission.refused`: `memory`, `disk`, `in_flight`, `wake_gate`, `awake_limit`, `busy`, `disk_full`, `queue_timeout`, `worker_queue`, `nested_calls`, `unavailable`, whatever the node counts, summed over the nodes of a cluster; `unavailable` counts the 503 `unavailable` answers, so those 503s are attributed). `answers_503` are the 503s the generator saw, `by_cause` the growth of each counter, `attributed` their sum and `unattributed` the 503 answers no counter grew for (`max(answers_503 - attributed, 0)`; the counters count calls, so `attributed` may exceed the answers). `notes` says how many stayed unattributed, or that there was no `/runtime` reading. `admission.refused` keeps only the causes the node reports, and `admission.refused_unreported` lists the known ones it does not (an older node), so a missing counter is not read as 0.
- `statuses_503_by_reason` (step) and `generator.statuses_503_by_reason` (join): the 503 answers by the reason in their JSON body, `error/reason` such as `overloaded/memory`, `overloaded/queue_timeout` or `unavailable/store_unavailable` (`unknown` for a body without one). The generator (`reasons_503` in its document) parses only the bodies of 503 answers, so the other requests cost nothing more. The status counts keep `503 retry-after` and `503 no retry-after`.
- `admission.unavailable_by_reason`: the growth over the step of the node's `admission.unavailable_by_reason` in `/runtime`, the `unavailable` 503s by reason. `null` when the node does not report it (an older node), not an empty map.
- `per_node` (the scale measure, every step of 2 or more nodes): for each node, `throttled_ms` (growth of its CPU throttling in the step) and `throttled_jump_ms` (the largest between two samples), `in_flight_max`, `refused` (its counters' growth), `unavailable_by_reason`, `wakes` and `compaction` (growth of the node's counters of those names, `null` when it does not report them), `disk_budget_bytes` (what its admission reports), and `runtime_failed` (samples in which its own `/runtime` did not answer) with the last `runtime_error`. Each entry of `series` has `nodes`, the same per sample (`throttled_ms` since the node started, `in_flight`). `node_throttled_ms` stays node-1's, which the stall rule reads.
- `evictions`: what tells why cells slept. The node counts the cells it hibernated under memory pressure (`pressure.hibernated` in `/runtime`): `pressure_hibernated` is its growth over the step, `null` when the node does not report it (no memory limit, or `memory.hibernate_fraction` off). `wakes` is the growth of the node's top-level `wakes` counter of `/runtime` (cells woken), `null` for a node that does not report it. `compaction` is the growth of the node's `hibernations.compaction` counters (`none`, `done`, `deadline`, `error`: hibernations by the outcome of the compaction before the release) with `tail_max`, the longest WAL tail found; `null` for a node that does not report it, and the same per node in `per_node`. A `deadline` count above 0 means cells were released with a long chain, so the next wake of each reads many segments. The other causes are not counted: the awake budget's (`[:alambique, :admission, :evict]`) and the disk reclaim's (`[:atanor, :disk, :reclaim]`) are telemetry events, not in `/runtime` (`counter_in_runtime` is false). For them the step records the evidence around them: `cells_awake_start` and `cells_awake_end` (`/cells`, so `cells_awake_change`), and the node's disk use against its budget (`admission.disk_used_start_bytes`, `disk_used_max_bytes`, `disk_used_max_pct_of_budget`, and `disk_used` in `series`). The disk reclaim starts at `disk.evict_fraction` of the budget (0.7 by default): cells that sleep with the disk use under it were not put to sleep by the reclaim.

The report adds, per measure, the refusals by reason, whether the gate was refusing, the largest in-flight count, the store tmpfs fill and the store 5xx at the approved step and at the first failing one.

### The opening of the cells measure

A `cells` step first writes each of its N cells once, at `workload.open_rate` (100 cells/s): the opening. Every one of
those writes wakes a cold cell, so it pays the store trips that a hot cell does not. The rest of the step, one
write per cell every `workload.cell_period_s`, is the hold: the cells being kept hot is what the measure is about.
p99 and the refused share are judged on the hold alone, so an opening that is slow or refused (a node under
a burst of cold starts) does not fail a ramp that the hold passes. In the step file `latency_ms` is the hold's, and
`opening` has the opening's own figures: `planned`, `answers`, `refused`, `refused_pct` and `latency_ms`
(`statuses` stays the whole step's). The log line ends `(hold; opening p99 N ms, refused M)`. Errors other
than 503 still fail a step, wherever they happen. In the generator's document the opening is `opening`, with its
statuses and histogram; `load-run` subtracts it from the totals to get the hold.

### The warm-up of the http measures

The first step of a fresh node woke its cells at the load rate: with the same 25 ms per store trip, B at 450 req/s had a
p99 of 244.5 ms against 55 ms at 600. An http step (`http-native`, `http-wasm`, `http-wasm-jobs`; not `swap`, and not the
join of the scale measure) therefore starts like a `cells` step: each of its `workload.cells` cells is written once, at
`workload.open_rate` (100 cells/s), then the generator rests 2 s before the steady load of `duration_s` seconds. The warm-up is the
`opening` of the step file, with the figures of [the opening](#the-opening-of-the-cells-measure) (`planned`, `answers`, `refused`,
`refused_pct`, `latency_ms`), and p99 and the refused share are judged on the steady part alone, as for cells. Errors other than 503
still fail a step wherever they happen. `statuses`, `achieved_rate` and `useful_rate` count the warm-up too (64 writes against
tens of thousands of requests). `workload.warmup = false` goes back to judging the cold wakes with the rest.

### The connection cap of the ws measure

The node holds at most `http.max_connections` connections (16384 by default, plus its 10 acceptors, so 16390;
[`ATANOR_HTTP_MAX_CONNECTIONS`](configuration.md)). A `ws` ramp that reaches it measures the cap, not the node's
memory. `node.http_max_connections` sets it on the nodes of the lab. The file is refused when a `ws` plan's highest
step is not below the cap, and `load-run` refuses to run, before any step, when the cap is not below the node's
descriptor limit (`ulimit -n` of the container, the Docker default unless set), and says which value to use.
Every step file records the cap as `http_max_connections` (the configured one, or 16384 when 0). For example, the
official round sets `http_max_connections = 40000` above its highest `ws` step (30000).

## The scale measure

**The question:** how much more does a cluster of 2 or 3 nodes hold than one node, how evenly do the nodes share
the work, and how fast does a node that joins take its share?

`scale` runs on scenario A (each node 1 CPU and 512 MB; scenario B works the same way) behind the load
balancer, with 1, 2 and 3 nodes (`scale.max_nodes`). Add it to `round.measures` or `round.cases`. It starts its own
nodes: the round starts the lab once, to build the images, and no more. Every configuration starts on a fresh
store and fresh nodes (`scripts/load-env reset`, with `ATANOR_LOAD_NODES=N`), the generators send to the balancer
(the other measures send to the node), and the store's backing and 25 ms of added latency follow `[store]` as
everywhere else.

```toml
[round]
cases = ["A/scale"]
[scale]
max_nodes = 2          # 1 and 2 nodes
loads = ["http-native"]
[scale.join]
rate = 900             # the join at a fixed rate instead of 1.5 times the 1-node ceiling
```

**The ramps.** For each load (`scale.loads`: `http-native` and `cells` by default; `http-wasm` and
`http-wasm-jobs` are allowed too) and each node count, the ramp of [how a step is judged](#how-a-step-is-judged) runs
unchanged: the plan of that load for the scenario, the same criteria, the same INVALID rules (host load, swap, full
store, stall, delivery), the same refine and confirmation. One node starts at its plan; 2 or more start at the
approved value of one node fewer and grow by `scale.factor` (1.25), because the ceiling can hardly be below it. With
`scale.ceilings` (`"http-native:1" = 600`: the ceilings of an earlier round) each ramp runs `ceiling_factors` times
its ceiling instead, and a configuration without a ceiling is skipped. The working-set criterion of `cells` judges
the fullest node. A node that stops (any of them) is a result of the step, with the node named in the reason.

**What each configuration records.**

| Field | Meaning |
| --- | --- |
| `ceilings` | The approved value of each load on each node count (without a confirmation, the best step that passed). |
| `gain` | Per node count: the ceiling over the ceiling of 1 node (`gain`), the ideal (`ideal`: 2 and 3) and `efficiency` (gain over ideal). |
| `distribution` (each ramp's summary and the step files) | Requests the balancer sent to each node during the step (growth of HAProxy's `stot` per server), the cells awake on each (the `nodes` of the admin API's `/cells`), their shares and the deviation: the largest `|share x N - 1|`, 0 for an equal split. The balancer counts what it sent to a node, not who owns the cell, and the cells are what each node holds awake. |

Step files are `SCENARIO/scale/LOAD-nN/step-VALUE.json` and have `measure: scale`, `load` and `nodes`. The summary
is `SCENARIO/scale/summary.json`.

**The join.** After the ramps, `scale` starts one node on a fresh store and sends `http-native` at a fixed rate,
`scale.join.rate` or `scale.join.factor` (1.5) times the 1-node ceiling, an overload on purpose. After
`join.warmup_s` (30 s) it starts node 2 (`scripts/load-env add-node 2`, which waits until the node is healthy and in
the balancer's rotation), then, `join.observe_s` (120 s) after it started, node 3. The load never stops. Every
`join.sample_s` (2 s) it reads the balancer's per-node requests and the cells awake per node. `join.enabled = false`
skips it.

*Spread time*, for each join, in seconds from the moment the node was started: the first of `spread.hold` (3)
consecutive readings in which every node has its 1/N share within `spread.tol_pct` (25%) of it. Two times are
recorded: `requests_spread_s` (requests of each reading interval, with at least a quarter of the expected requests
in all) and `cells_spread_s` (cells awake on each node, at least `spread.min_cells` (10) in all). A time is null
when it never held in the window of that join (it ends when the next node starts, or with the load). The
requests spread when the node enters the rotation; the cells spread only if cells move to the new node, which
needs the rebalance on join. A cluster without it shows `cells_spread_s: null`, which is a result. Each window
also records the balancer's counters (requests, 5xx answers, connection and response errors, retries), and the
generator's totals (503 and errors) for the whole join: the 503 answers of the first window are the overload of
one node. The join's `rebalance` is what each node's `/runtime` says under `rebalance` at the end of each window
(just before the next node starts, or when the load ends), and `rebalance_observed` is the same read `join.observe_s`
after the node started, which is mid-plan when the plan is long (a plan of 35 cells showed 12 moved at that moment);
a field that is missing is null, and the report says so. The file is `SCENARIO/scale/join/step-RATE.json`.

An ok join keeps the evidence of a failing step, for every node: `step-RATE.node-N.node.log` and
`.node-N.node-state.txt`, the store's `.store.log` and `.store-metrics.txt` (the lines that name a secret are
dropped), and, for every window, `.window-N.runtime.json`: the whole `/runtime` of each node of that window when it ended,
or `{"error": ...}` for a node that did not answer. The step file lists them in `diagnostics`. A reading in which a
node's `/runtime` did not answer (2 s timeout) is named in the `runtime_errors` of that reading in `samples`, and each window's
`runtime_failures` counts them per node (`readings`) with the last error.

Each window of the join also records `cells_in_band_s`, the first reading in which the cells were within the
tolerance (held or not, unlike `cells_spread_s`, which needs `spread.hold` readings in a row), and `samples`: for
each reading, `t` (seconds from the first), `new_5xx` (the balancer's backend 5xx answers since the previous reading),
`moved` (the cells each node's rebalance has moved so far, `total.moved` of its `/runtime`) and `moved_new`
(the growth of their sum), so a burst of 5xx can be set against the moves. Each is null when the reading did not say.

**The CPU budget.** The nodes, the store and the balancer have CPU limits (scenario A: 1 CPU per node, 2 for the
store and 2 for the balancer: `store.cpus` and `balancer.cpus`), and the generators and the
harness need cores too. The limits are caps, not reservations, so `scale` never refuses on their sum. When
`scale.max_nodes` times the node CPUs plus the store's and the balancer's exceed the host's cores it prints a warning
once, and the scale summary records `cpu_caps_sum`, `host_cores` and `cpu_caps_warning`. The guard is the
host-saturated rule above: a step whose mean busy cores pass 85% of the host's cores is INVALID, and `largest_fit`
and the advice say how many nodes the host held.

**The default ceilings.** Each ramp ends at its plan's `max` when nothing fails: 20000 req/s for `http-native`, 100000 for
`cells`. A configuration that gets there has `ceiling_reached: true`: its ceiling is a lower bound, not the node's limit, and
the gain computed from it is too.

**INVALID.** The host guards of every step apply (net host load under 1 core, busy cores under 85% of the host's,
free memory, swap); every node's CPU counts as the test's own. The join judges the same guards (net load and busy share, `host.busy_cores_mean` in its file) over its readings, leaving out the
seconds in which a node was starting. When a step is INVALID, `scale` records it, runs no larger
configuration (and none for the other loads), and the summary says `largest_fit` and
`rerun with scale.max_nodes N`: rerun with the largest count that fit. Nothing asks for more resources than
`scale.max_nodes` nodes, and the exit status is 1 for an INVALID step, as for any measure.

**Cost.** Estimates from the harness's timings, not measurements. A step is 180 s of load, at least 60 s of quiet
wait and about 10 s of judging; a reset of 1 to 3 nodes takes 1 to 2 min. A 1-node ramp of one load is about
13 steps with the refinement and the confirmation, about 55 min; the ramps of 2 and 3 nodes start higher and take
8 to 10 steps, about 40 min each. Two loads on 3 configurations: about 4.5 h, and the join about 11 min
(reset, quiet wait, `join.warmup_s` plus two windows of `join.observe_s` plus `join.node_wait_s`, and
the last window). `max_nodes = 2` saves a third.

**The report.** `report.md` adds, under `scale`, the gain-per-node table (the same table the
[cluster guide](how-to-run-a-cluster.md#what-a-cluster-gains-per-node) fills from the official round), the table of
requests and cells per node, the steps of every configuration and the join.

## Exploring a ceiling

**The question:** how do I find the defects of the product or the harness before the official round, so that the
official round runs once?

An exploration round is unofficial. Its goal is findings, not numbers: nothing it measures is reported. Give each
measure `kind = "ceiling"` with the `approved` value of a previous round as its `ceiling`: it runs only the steps at
75%, 100%, 125% and 150% of it, and with `duration_s = 75`, `refine = 0` and `confirm = false` it neither bisects nor
confirms. The ramp stops at the first failing step, as always. The swap has no ramp: set `swap.rate` to the
`http-wasm-jobs` ceiling. Write one file per scenario, run it, and redo only the measure of a finding after a fix
(`round.cases = ["A/ws"]`, with another `output.name`).

**Clean or a finding.** A measure is clean when every step is `ok` or a failure that is a result of the node:
a failed criterion (p99, memory, descriptors) or 503 answers, each with `Retry-After`. Anything else is a finding:

- a step INVALID (any cause in the table of [how a step is judged](#how-a-step-is-judged)), `host busy` included
  when the host was quiet;
- a crash of the harness, of the generator or of a script;
- a node that stopped (`node OOM-killed`, `node exited`, `node restarted`, `node container gone`);
- a 5xx other than a 503 with `Retry-After`, or an error that is not a measured saturation;
- a ramp that fails below the previous ceiling by more than 25%, or a swap that loses or duplicates a write;
- any behavior of the harness that you did not expect (a wrong number, a missing file, a hang).

Each finding becomes a fix before anything else; when every measure is clean, run the official round once.
Time: a step is 75 s of load, at least 60 s of quiet wait and about 10 s of judging, and a failing step is followed
by a reset of the node (about 1 min); ten measures take about 80 min (an estimate, not a measurement).

## Smoke test

To check the harness without loading anything, run each measure for a few seconds at a low value. Save this as
`load/rounds/smoke.toml` and run `mise run load -- --config load/rounds/smoke.toml`:

```toml
[round]
measures = ["http-native", "ws", "cells", "http-wasm", "http-wasm-jobs", "swap"]
[output]
dir = "/tmp/atanor-load-smoke"
[generator]
sample_s = 3.0
[workload]
ws_interval_s = 10.0
cell_period_s = 5.0
[swap]
rate = 10.0
warmup_s = 5.0
overlap_s = 3.0
settle_s = 8.0
[measures.http-native.steps]
kind = "ladder"
values = [10, 20]
duration_s = 15.0
refine = 0
[measures.ws.steps]
kind = "ladder"
values = [20, 40]
duration_s = 15.0
refine = 0
[measures.cells.steps]
kind = "ladder"
values = [20, 40]
duration_s = 15.0
refine = 0
[measures.http-wasm.steps]
kind = "ladder"
values = [10]
duration_s = 15.0
refine = 0
[measures.http-wasm-jobs.steps]
kind = "ladder"
values = [10]
duration_s = 15.0
refine = 0
```

## When the store fills its tmpfs

**The question:** a step ended INVALID with `store tmpfs 9x% > 90%`: how do I measure on a store that does not fill?

The store's tmpfs is 1 GB (`store.tmpfs_size`). When a step fills it, run the whole round again, scenarios A and B,
with the store on the host's disk. Mixing backings inside one round would make the numbers incomparable.

1. Set `backing = "disk"` in `[store]` of the round file and check that the host has free disk for the store's
   volume (the store keeps its data in the volume `store-data` of the project until the lab is removed).

   ```toml
   [store]
   backing = "disk"
   ```

2. Run the round as usual. The node's data stays in tmpfs, so its memory accounting is unchanged, and the 25 ms added per store trip stays.
3. Read the backing in `scripts/load-env info` (`store_backing`), in every step file (`store_backing`, `store.backing`) and in the report ("store on disk"). A step is INVALID when the store's filesystem passes 90% used.

A disk-backed store may answer faster or slower than a tmpfs one, so numbers of the two backings are not comparable with each other.

## Troubleshooting

- **The file is refused.** Every problem is listed with its key (`judging.p99.max_ms: -1 is out of range`). An old
  name such as `node_tmpfs` or `min_available_gb` gets a hint (`data_tmpfs`, `min_available_gib`).
- **The round refuses: step files were made by another config.** A key that affects a case changed after its
  steps were written. Set another `output.name`, or pass `--no-skip-done` to run them again and overwrite them.
- **`the added latency is not visible`.** The store's qdisc was not applied: the host kernel lacks `sch_netem`
  (`modprobe sch_netem`) or Docker refused `NET_ADMIN`. Run `scripts/load-env --config FILE latency` to see the round trips.
- **`host busy` or `host contaminated`.** Another job kept the host busy: before a step for longer than
  `host_load.quiet_max_wait_s`, or during it above `host_load.max`. Stop the other work and run the round again
  (`--skip-done` keeps what is done); raising `host_load.max` weakens the result, so say so.
- **A ramp ends at the first step.** Read `stop_reason` in its JSON. A 404 or an error on the first request
  means a worker is not deployed: run `scripts/load-env --config FILE deploy`.
- **`delivery ... < 95%` on a quiet node.** The generator is the limit. Lower `generator.rate_per_proc` so that more
  processes share the rate, or stop other work on the host.
- **A ws ramp past about 28,000 connections.** One generator address has about 28,000 ephemeral ports towards
  one node address; the generator reports connection errors before the node does.
- **The swap stops with `node-2 is exited with status 127`.** Node B did not start; the log lines under that message
  say why. Status 127 with `/opt/atanor/bin/atanor: not found` means B used an image without the release, not the load
  image: run the swap through the round, not `scripts/cluster-swap-run`, in the load environment.
- **`--remote` refuses.** It names the reason: local changes in the clone on the host, a commit that is not your
  `HEAD` (`git pull` there, after pushing), the round file missing in the clone, or a round already running
  (`--status`). `--status` or `--fetch` say `set output.name` when the results directory cannot be found again.

## Limits

- `memory.peak` is the peak since the container started; the step also records the largest sampled value.
- One generator host: its own CPU is reported (`generator.cpu_cores`) and counted out of the host load.
- Hot cells below the memory policy (`memory: awake_fraction`) may hibernate and wake again; the step records
  the cells awake from the admin API at its end.
- `--remote` does not copy files: the round file and the code must be in the clone on the host.

Next: [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md),
[how-to-replace-a-node.md](how-to-replace-a-node.md), [design.md](design.md) section 12 for the benchmarks that
run in one VM.
