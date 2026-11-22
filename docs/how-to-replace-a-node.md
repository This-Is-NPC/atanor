# How to replace a node with another one

**The question:** How do I start a new Atanor node next to a running one
(a new version, a new machine, a smaller cluster), move everything to it,
shut the old one down without losing a write, and see what clients get on the
way?

This guide stands alone for the swap itself. Its commands use Docker, the store and the
secrets of the [local node guide](how-to-run-a-node-locally.md). The steps apply to any
deployment (systemd, Kubernetes) with the names changed.

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
  (default: the Erlang node name, `atanor@<ATANOR_ADVERTISE>`, for example
  `atanor@node-1.cluster`). With the same id, B would
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
  `stop.shutdown_ms` (75 000 ms by default). `docker stop` (10 s by default)
  and Kubernetes (30 s) would otherwise send SIGKILL to a node
  that is still handing cells back; its leases then expire as after a crash
  and B waits up to the TTL plus the skew (32 s). Give the node a grace period of
  90 s: `docker stop --timeout 90`, or `stop_grace_period: 90s` in Compose. Or lower
  `stop.shutdown_ms` (`ATANOR_SHUTDOWN_MS`) and keep the grace above it
  ([the rule](configuration.md#the-stop-grace-period)).
- Docker, `curl` and `jq`, and the store of the [local node guide](how-to-run-a-node-locally.md)
  with its secrets in `atanor-secrets`.

## Steps

The steps take A to be the node of the local node guide, `atanor-node`, with its admin port on
`127.0.0.1:4001`. B is `node-b`, with its port 4000 on `127.0.0.1:4010` and its admin port on `127.0.0.1:4011`.
`$IMAGE` is the image of the new version.

1. A is the only node, in no group. If it is not running yet, start it and deploy the app as in
   steps 4 and 5 of the [local node guide](how-to-run-a-node-locally.md).

2. Start B with its own name, the same bucket and cookie, and group `b`:

   ```sh
   docker run -d --name node-b --network atanor-net --stop-timeout 90 \
     -p 127.0.0.1:4010:4000 -p 127.0.0.1:4011:4001 -v "$PWD/atanor-secrets:/run/secrets:ro" \
     -e ATANOR_STORE=s3://atanor -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     -e ATANOR_ADMIN_TOKEN_FILE=/run/secrets/admin_token -e ATANOR_COOKIE_FILE=/run/secrets/cookie \
     -e ATANOR_GROUP=b -e ATANOR_ADVERTISE=node-b.local "$IMAGE"
   curl -s -H "authorization: Bearer $(cat atanor-secrets/admin_token)" http://127.0.0.1:4001/health
   curl -s -H "authorization: Bearer $(cat atanor-secrets/admin_token)" http://127.0.0.1:4011/health
   ```

   Each node lists only itself in `nodes`: they are not a cluster. The first answer is A
   (`atanor@atanor-node.local`), the second is B (`atanor@node-b.local`). B follows the app's
   deployment within the poll interval (5 s). If you run your own compose file, the side-by-side
   services look like this (the part that matters: distinct names, another group, one bucket, a long
   grace period):

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

3. Point the balancer at both. A node is in rotation while `/health/serving` on its admin port
   answers 200, and out while it does not. Check B:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -H "authorization: Bearer $(cat atanor-secrets/admin_token)" \
     http://127.0.0.1:4011/health/serving
   ```

   ```text
   200
   ```

   While both are in rotation, a request for a cell that A holds and that
   lands on B is 503 `held_elsewhere` with `Retry-After: 1`. Keep that period
   short: drain A as soon as B serves.

4. Drain A. Either way A keeps serving the cells it still holds, hands each
   back and stops itself with status 0.

   SIGTERM (what `docker stop`, systemd and Kubernetes send):

   ```sh
   docker stop --timeout 90 atanor-node
   ```

   or the admin API, on A's admin port (`atanor drain` is the same call, see [cli.md](cli.md)):

   ```sh
   curl -s -X POST -H "authorization: Bearer $(cat atanor-secrets/admin_token)" http://127.0.0.1:4001/drain
   ```

   ```text
   {"node":"atanor@atanor-node.local","state":"drained","errors":[],"hibernated":N,"duration_ms":N}
   ```

   `errors` is empty when every cell was handed back and each lease released.

5. Watch the drain. On A, `GET /drain` says `idle`, `draining` or `drained`;
   `GET /health` stays 200 with `"status":"draining"`, and `/health/ready` and
   `/health/serving` answer 503 `draining`, which is what takes A out of the
   balancer. A node with many cells
   stays in `draining` for the time they need; poll it. While `draining` the answer also carries `cells_at_start`, `done`
   and `left`, once the jobs have finished and the cells are being handed back:

   ```sh
   curl -s -H "authorization: Bearer $(cat atanor-secrets/admin_token)" http://127.0.0.1:4001/drain
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
   docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' atanor-node
   docker rm atanor-node
   ```

   ```text
   exited 0
   ```

   Exit status 1 means the drain left some cell awake (see Troubleshooting). The
   admin port closes with the VM, so a poll of `GET /drain` during a SIGTERM
   ends with a refused connection, not with `drained`; read the exit status and
   the log.

8. Check the data. Take the fingerprint of the [test data](how-to-operate-atanor.md#test-data) before
   the swap and after it, through B's port 4010. The same rows and hashes mean that no acknowledged
   write was lost. The container cluster of this repository runs a scripted swap under load; that is
   a contributor tool ([how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md)).

## Job claims and alarms during the swap

- **Jobs.** The drain releases the claims of the jobs A did not finish while
  it still owns the cells, so B runs them at its next tick (within about a
  second), not after `claim_ms` (60 s). A job that still runs on A is waited
  for up to `stop.jobs_ms` (15 s) and nothing is released for it, so no job
  runs twice ([how-to-use-jobs.md](how-to-use-jobs.md), design.md, section 15.12).
- **Alarms.** An alarm fires once, even on two nodes that are not a cluster:
  the claim is a conditional update in the cell, which only the holder of the
  lease can run. A draining
  node leaves the alarm scheduler, so B scans the shards alone.

## Troubleshooting

- **The container ends with status 137 (SIGKILL) after the grace period.** The
  grace period is shorter than the drain. Set it above
  `stop.shutdown_ms` (`docker stop --timeout 90`, or `stop_grace_period` in Compose). The leases were not all
  released and expire as after a crash.
- **A exits with status 1 and `errors` lists `:deadline`.** The drain ran out
  of `stop.shutdown_ms` or `stop.drain_timeout_ms`. A still stops through the
  supervisor, which hibernates each cell it holds (upload, then release of the
  lease, up to 30 s per cell), so B usually serves them within seconds. Raise
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
- **A wake is slow.** B logs `slow wake of ...` when a wake takes one second
  or more, with the store requests it made and their time. A request that
  reaches the 5 s queue deadline gets 503 `queue_timeout` with `Retry-After`;
  its write was not sent, so the client retries it.

## Next steps

- [how-to-run-a-cluster.md](how-to-run-a-cluster.md): the same nodes as one
  cluster, with takeover and the failure detector.
- [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md):
  the container cluster of this repository, for contributors.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md), step 13, and
  [cli.md](cli.md) (`atanor drain`).
- [known-limitations.md](known-limitations.md) for what a swap still costs clients.
