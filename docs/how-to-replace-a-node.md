# How to replace a node with another one

**The question:** How do I start a new Atanor node next to a running one
(a new version, a new machine, a smaller cluster), move everything to it,
shut the old one down without losing a write, and see what clients get on the
way?

This guide stands alone for the swap itself. The commands run on the container
cluster of [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md),
whose task `mise run cluster:swap-run` does the whole swap under load and
checks it; the steps apply to any deployment (systemd, Kubernetes) with the
names changed.

## How it works, in short

Node A (the one that leaves) and node B (the one that comes) **form no
cluster**. They share the store (S3 bucket and prefix) and nothing else: no
Erlang distribution between them, no call from one to the other. A cell lives
on whichever node holds its lease in the store.

1. B starts and serves. A request for a cell that A holds gets 503
   `held_elsewhere` with `Retry-After` from B; B never takes a lease that is
   held.
2. A drains (SIGTERM or `POST /drain`): it reports `draining` on its health
   endpoints, so the balancer stops sending to it, keeps serving the cells it
   still holds, hibernates every cell, releases each lease and stops itself.
3. B wakes each cell from the store at its next request.

Design: [§8.11](design.md#811-draining-and-stopping-gracefully).

## Prerequisites

- Two nodes that use the same store and prefix, and a balancer that sends to
  both and takes a node out while it answers 503 on `/health/serving`.
- **A different node name and `node_id` on each.** The id is in the leases
  (default: the Erlang node name, `atanor@node-1.cluster`). With the same id, B would
  treat A's lease as its own and both nodes would write the same cell. Atanor
  cannot detect this; keep the names distinct.
- **No cluster between them.** Nodes that share a store find each other through it
  ([discovery](configuration.md#discovery)), so B must be in **another discovery
  group** than A: start it with `ATANOR_GROUP=b` (A has none). B is in the store's
  registry, but neither node dials the other. Another store prefix would isolate
  them too, but they would then share no cells, which a swap needs. If they connect,
  they are a cluster and the swap is a different operation
  ([how-to-run-a-cluster.md](how-to-run-a-cluster.md)). B keeps its group after A
  is gone: a node you add later joins B's group, or B restarts without it.
- **A grace period longer than the drain.** The drain is bounded by
  `stop.shutdown_ms` (75 000 ms by default). `docker stop` (10 s by default),
  Kubernetes (30 s) and systemd (90 s) would otherwise send SIGKILL to a node
  that is still handing cells back; its leases then expire as after a crash
  and B waits up to the TTL plus the skew (32 s). In Compose,
  `stop_grace_period` is 90 s in [cluster/compose.yml](../cluster/compose.yml)
  (`ATANOR_CLUSTER_STOP_GRACE`). Or lower `shutdown_ms` (and
  `ATANOR_CLUSTER_SHUTDOWN_MS`) and keep the grace above it.
- For the walk-through below: Docker, and the setup of the container cluster
  guide (`mise install`, `jq`, `curl`, `python3`).

## Steps

1. Start A as the only node, in no group, and deploy the app.

   ```sh
   ATANOR_CLUSTER_NODES=1 mise run cluster:up
   mise run cluster:deploy-example
   ```

   ```text
   cluster ready: 1 nodes, release ebd7be660c0b-dirty
   ...
   scoreboard: active 55c8cdbc30d325d5628e54486c7ddb7bf3528f6355afe153817dafefb7f4061f, revision 1, previous none
   ```

   Outside the container cluster, the same is: `ATANOR_GROUP` unset on A and set on B, and a
   node name and `ATANOR_NODE_ID` of their own.

2. Start B: another Compose service of the same project (`node-2`: hostname
   `node-2`, node `atanor@node-2.cluster`), the same bucket, in group `b` (`ATANOR_CLUSTER_GROUP=b`).

   ```sh
   docker compose -p atanor-cluster -f cluster/compose.yml up -d --no-deps node-2
   docker exec atanor-cluster-node-1 sh -c 'curl -s -H "authorization: Bearer $(cat /run/secrets/admin_token)" http://127.0.0.1:4001/health'
   docker exec atanor-cluster-node-2 sh -c 'curl -s -H "authorization: Bearer $(cat /run/secrets/admin_token)" http://127.0.0.1:4001/health'
   ```

   ```text
   {"node":"atanor@node-1.cluster","status":"ok","nodes":["atanor@node-1.cluster"],"workers":1}
   {"node":"atanor@node-2.cluster","status":"ok","nodes":["atanor@node-2.cluster"],"workers":1}
   ```

   Each node sees only itself: they are not a cluster. B follows the app's
   deployment within the poll interval (5 s). If you used a compose file
   other than ours, the side-by-side services look like this (the part that
   matters: distinct names, another group, one bucket, a long grace period):

   ```yaml
   services:
     node-1: &node
       image: atanor-node:1
       hostname: node-1                      # node atanor@node-1.cluster
       stop_grace_period: 90s                # more than stop.shutdown_ms (75 s)
       environment: &env
         ATANOR_ADVERTISE: node-1.cluster      # the node is atanor@node-1.cluster
         ATANOR_S3_ENDPOINT: http://store:8333
         ATANOR_STORE: s3://atanor           # the same store and prefix
         ATANOR_NODE_ID: atanor@node-1.cluster # optional; distinct from B's
     node-2:
       <<: *node
       image: atanor-node:2                  # the new version
       hostname: node-2
       environment:
         <<: *env
         ATANOR_GROUP: b                     # not A's group: no cluster with A
         ATANOR_ADVERTISE: node-2.cluster
         ATANOR_NODE_ID: atanor@node-2.cluster
   ```

3. Point the balancer at both. In the container cluster HAProxy finds every
   `node-N` through DNS and checks `/health/serving` on the admin port every
   second; B is in rotation after two good checks (about 3 s after its start
   in our runs). Check it:

   ```sh
   curl -s "http://127.0.0.1:18083/stats;csv" | awk -F, '$1 == "atanor_http" && $2 ~ /^node/ {print $2, $18}'
   ```

   While both are in rotation, a request for a cell that A holds and that
   lands on B is 503 `held_elsewhere` with `Retry-After: 1`. Keep that period
   short: drain A as soon as B serves (`--overlap` of the task is that time).

4. Drain A. Either way A keeps serving the cells it still holds, hands each
   back and stops itself with status 0.

   SIGTERM (what `docker stop`, systemd and Kubernetes send):

   ```sh
   docker stop --timeout 90 atanor-cluster-node-1
   ```

   or the admin API, from inside A's container (the node's admin port is not
   published; `atanor drain` is the same call, against the URL of the node
   that leaves and not through the balancer):

   ```sh
   docker exec atanor-cluster-node-1 sh -c 'curl -s -X POST -H "authorization: Bearer $(cat /run/secrets/admin_token)" http://127.0.0.1:4001/drain'
   ```

   ```text
   {"node":"atanor@node-1.cluster","state":"drained","errors":[],"hibernated":3,"duration_ms":5}
   ```

   `errors` is empty when every cell was handed back and each lease released.

5. Watch the drain. On A, `GET /drain` says `idle`, `draining` or `drained`;
   `GET /health` stays 200 with `"status":"draining"`, and `/health/ready` and
   `/health/serving` answer 503 `draining`, which is what takes A out of the
   balancer (within about 2 s: `inter 1s fall 2`). A node with many cells
   stays in `draining` for the time they need (48 cells took 0.3 s here);
   poll it. While `draining` the answer also carries `cells_at_start`, `done`
   and `left`, once the jobs have finished and the cells are being handed back:

   ```sh
   docker exec atanor-cluster-node-1 sh -c 'curl -s -H "authorization: Bearer $(cat /run/secrets/admin_token)" http://127.0.0.1:4001/drain'
   ```

   The node's log says `atanor: SIGTERM received, draining before the VM
   stops` or `atanor admin drain ...`. The telemetry events are
   `[:atanor, :node, :drain, :start]` and `[:atanor, :node, :drain]`
   ([telemetry.md](telemetry.md)).

6. What clients see. A request that reaches A for a cell it already handed
   back, or that needs a cell A would have to wake, is 503 `draining`; one that
   reaches B for a cell A still holds is 503 `held_elsewhere`. Both carry
   `Retry-After` (seconds), neither ran the request, and a client that
   retries after that time is served by B. A TCP connection closes and a
   WebSocket upgrade gets the 503. The balancer retries only failed
   connections.

7. A exits. Check it and remove it. Nothing else is needed: B already serves
   every cell.

   ```sh
   docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' atanor-cluster-node-1
   docker rm atanor-cluster-node-1
   ```

   ```text
   exited 0
   ```

   Exit status 1 means the drain left some cell awake (see Troubleshooting). The
   admin port closes with the VM, so a poll of `GET /drain` during a SIGTERM
   ends with a refused connection, not with `drained`; read the exit status and
   the log.

8. Do all of it under load and measure it:

   ```sh
   ATANOR_CLUSTER_NODES=1 mise run cluster:up && mise run cluster:deploy-example
   mise run cluster:swap-run --trigger sigterm   # or --trigger api
   ```

   The task starts the [scoreboard](../examples/scoreboard/README.md) load
   (`--rooms` 12, `--workers` 8 of at most 12, `--rate` 60 requests per second),
   runs `--warmup` 25 s with A alone, starts B, waits until it is in rotation,
   lets both serve `--overlap` 5 s, drains A, waits up to `--drain-wait` 120 s
   for A to exit, keeps the load `--settle` 30 s, and runs the checker. It
   exits 1 when an acknowledged write is lost or duplicated, a refused write is
   stored, any answer was not a 503 with `Retry-After` or a refused connection,
   or A did not exit with status 0. If B exits or turns unhealthy before it
   serves, it stops at once with B's exit status and its last log lines. Results
   are in `--out`.

   Measured on this repository (one Ryzen AI 5 340, 12 schedulers, nodes at
   1.5 CPUs, data in memory, host load average 2 to 5), one run each:

   | Run | Trigger | Rooms / rate | Overlap | Acked | Refused (503) | Lost / dup. | A exit | Last 503 | p50 / p99 / max before | during the swap | after |
   | --- | --- | --- | ---: | ---: | --- | --- | ---: | ---: | --- | --- | --- |
   | 1 | SIGTERM | 12 / 60 | 5 s | 3,623 | 206 `held_elsewhere` | 0 / 0 | 1.5 s | 0.1 s | 5 / 75 / 83 | 9 / 418 / 418 | 5 / 70 / 869 |
   | 2 | `POST /drain` | 48 / 100 | 5 s | 6,350 | 335 `held_elsewhere` | 0 / 0 | 3.9 s | 1.9 s | 18 / 85 / 105 | 52 / 476 / 655 | 14 / 89 / 100 |
   | 3 | SIGTERM | 48 / 100 | 0 | 6,036 | 81 `held_elsewhere` | 0 / 0 | 3.1 s | 1.6 s | 22 / 95 / 123 | 33 / 429 / 618 | 16 / 88 / 120 |
   | 4 | `POST /drain` | 48 / 100 | 0 | 5,982 | 102 `held_elsewhere` | 0 / 0 | 2.8 s | 1.3 s | 17 / 85 / 97 | 50 / 376 / 504 | 19 / 94 / 1,078 |

   Latencies are those of acknowledged writes, in ms. "Swap" is from the
   start of the drain to the exit of A; "A exit" and "Last 503" are measured
   from the start of the drain. There was no other status than 503 in any run
   (no 5xx, no unknown outcome, no refused connection), every 503 had
   `Retry-After: 1`, and no refused write was stored. The 503s before the drain
   are the overlap: with both nodes in rotation, half of the requests
   reached the node that did not hold the cell. The drain itself took 0.3 s
   for 48 cells (`POST /drain`: `"duration_ms":289`, `"hibernated":48`); the
   rest of "A exit" is the VM stopping. The 3 s that B needs to enter the
   rotation are not part of the swap. The `draining` reason did not appear:
   with this few cells A finished before a request met it.

### A swap with a slow store and many busy cells

The four runs above had no unknown outcome because the store answered in under a
millisecond. With the store 25 ms away (load scenario A, one CPU and 512 MB per
node, 12 rooms, 750 requests per second), 4 of 4 swaps in `mise run load:swap`
(`scripts/cluster-swap-run`) left 22 to 36 requests with no answer, always from
the same 4 of the 12 rooms, each hanging again every 10 to 11 s until B had
woken them, 25 to 32 s after the drain. They are client timeouts at 10 s, not
resets, and no acknowledged write was lost or duplicated.

The leases were not the cause. A released all 12 of them in 0.1 s (12 releases
in the node's telemetry, `errors: 0`), and B acquired each one at once. B then
spent 25 to 32 s restoring those 4 cells: 449 to 822 segments each, one object
per commit, read one at a time (`restore: [fetch_concurrency: 1]` on a 512 MB
node) at 25 ms. The other 8 cells restored from 13 to 73 segments in 1 to 4 s,
because Alambique's compactor had merged them while A served. The compactor
takes the first 8 ready cells of its table at each tick, in table order, and
12 busy cells are all ready again at the next one, so the same 4 cells are never
compacted (open defect in Alambique 0.6.1, see
[what-does-not-work.md](what-does-not-work.md)). A request for such a cell waits
for its wake and has no deadline, so its client gives up first.

`cluster:swap-run` now writes the balancer's request log (`docker-lb.log`) and
adds `no_answer_by_server` and `no_answer_requests` (id, room, node, balancer
state) to `result.json`, so a timeout is tied to the node that held it.

## Job claims and alarms during the swap

- **Jobs.** The drain releases the claims of the jobs A did not finish while
  it still owns the cells, so B runs them at its next tick (within about a
  second), not after `claim_ms` (60 s). A job that still runs on A is waited
  for up to `stop.jobs_ms` (15 s) and nothing is released for it, so no job
  runs twice ([how-to-use-jobs.md](how-to-use-jobs.md), design.md, section 15.12).
- **Alarms.** An alarm fires once, even on two nodes that are not a cluster:
  the claim is a conditional update in the cell, which only the holder of the
  lease can run (tested in `test/atanor/alarms_handback_test.exs`). A draining
  node leaves the alarm scheduler, so B scans the shards alone.

## Troubleshooting

- **The container ends with status 137 (SIGKILL) after the grace period.** The
  grace period is shorter than the drain (not seen in our runs, which used 90 s). Set it above
  `stop.shutdown_ms` (`ATANOR_CLUSTER_STOP_GRACE`). The leases were not all
  released and expire as after a crash.
- **A exits with status 1 and `errors` lists `:deadline`.** The drain ran out
  of `stop.shutdown_ms` or `stop.drain_timeout_ms`. A still stops through the
  supervisor, which hibernates each cell it holds (upload, then release of the
  lease, up to 30 s per cell), so B usually serves them within seconds, as in
  our runs (1,300 cells in 2.3 to 3.3 s with a 100 ms deadline). Raise
  `drain_timeout_ms` or `shutdown_ms` if cells are slow to upload, then repeat.
- **Clients get 503 `held_elsewhere` for about 32 s.** A was killed (SIGKILL) or
  a cell could not upload before it ended: that cell keeps its lease until the
  TTL (`lease_ttl_ms`, 30 s) expires. B waits for the TTL plus the skew margin
  (2 s); `Retry-After` stays `http.retry_after_s` (1 s), so clients poll until
  the lease ends.
- **Two nodes write the same cell.** Their `node_id` is the same. Give each
  node its own name or id before they share a store; there is no check at
  start.
- **`/health` on A or B lists the other node.** They are connected as a
  cluster: they share a discovery group. Give one of them `ATANOR_GROUP` and restart it.
- **Many 503 `held_elsewhere` before the drain.** Both nodes are in rotation
  while A holds the cells. Drain A right after B serves, or add B to the
  balancer only when you drain.
- **`cluster:swap-run` says the node is in a discovery group.** Start the cluster with one
  node and without `ATANOR_CLUSTER_GROUP`.

## Next steps

- [how-to-run-a-cluster.md](how-to-run-a-cluster.md): the same nodes as one
  cluster, with takeover and the failure detector.
- [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md):
  the container cluster, its settings and fault scenarios.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md), step 13, and
  [cli.md](cli.md) (`atanor drain`).
