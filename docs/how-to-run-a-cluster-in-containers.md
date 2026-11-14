# How to run a cluster in containers and break it

**The question:** How do I run Atanor on several nodes in Docker containers
over their own SeaweedFS and a load balancer, deploy an app with a scoped
token, and kill, pause, partition or restart a node or the store?

This guide stands alone for someone with the repository and Docker. For the
cluster itself (routing, takeover, detector) see
[how-to-run-a-cluster.md](how-to-run-a-cluster.md); for the VM version see
[how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md).

## What it runs

Everything belongs to the Compose project `atanor-cluster` ([cluster/compose.yml](../cluster/compose.yml)).

| Container | What it is |
| --- | --- |
| `atanor-cluster-node-1..N` | The Atanor release ([daemon](../daemon)), in the `harness` image: the `harness` target of the [Dockerfile](../Dockerfile) at the repository root, which is the product image plus `curl`, `tc`, `iptables` and `ps` for the faults and healthchecks ([how to build it](how-to-build-the-release.md)). One Compose service per node (`node-1` to `node-10`), each with the hostname `node-N` and the network alias `node-N.cluster`. N is 3 by default, at most 10. |
| `atanor-cluster-store-1` | SeaweedFS `chrislusf/seaweedfs:4.48`, pinned by digest, with a volume. |
| `atanor-cluster-bucket-1` | Creates the bucket once, then exits. |
| `atanor-cluster-lb-1` | HAProxy. A node is in rotation only while `GET /health/serving` on its admin port answers 200: the node is ready and has a quorum ([design §10](design.md#102-admin-api)). It adds the header `x-atanor-server` (the balancer's slot) to every answer. |

A node is named `atanor@node-N.cluster` (`ATANOR_ADVERTISE`, set by the Compose service to its hostname plus `.cluster`; long names need a dot). Docker's DNS resolves
`node-N.cluster` while the container runs. There is no list of peers: each node publishes
`atanor@node-N.cluster` under `atanor/nodes/` in the bucket and connects to the names it reads there
([discovery](configuration.md#discovery)), so a container that restarts with another address is the
same node. Between the nodes the network must carry `epmd` (4369) and the distribution ports 9100 to
9110; Compose's network does. Whoever can write `atanor/nodes/` in the bucket decides whom the nodes
dial, though the cookie still gates the handshake: give the bucket's keys to the nodes only. The Erlang cookie, the admin and dashboard tokens and the S3 keys
are generated in `cluster/secrets` (git-ignored, mode 700) and mounted as
Compose secrets; the nodes read them through the `*_FILE` variables
(`ATANOR_COOKIE_FILE`, `ATANOR_ADMIN_TOKEN_FILE`, ...), and every node setting is
one of [the daemon's](configuration.md#the-daemon-environment-and-file). The cluster uses static keys (the first source); on AWS a node
can take its S3 credentials from a web identity, the container agent or the instance profile instead
([AWS credentials](configuration.md#aws-credentials)). The cookie is a root password for the cluster
([design §4](design.md#4-bindings), "What the cookie protects"); it
is separate from the tokens. Ports 4001 (admin) and 4002 (dashboard) of the
nodes are not published; the load balancer publishes everything on
`127.0.0.1` only.

## Prerequisites

- Docker with Compose v2 and BuildKit, `curl`, `jq`, `openssl`, `python3`.
- The tools of the [README](../README.md#requirements) (`mise install`).
- Internet for the first build (base images, Hex, crates, and the public
  Alambique repository at the tag in `alambique.ref`). It took about three
  minutes on 12 cores with 6 Cargo jobs.
- Free host ports 18080 to 18083 (or set the ports below).
- Node.js 22 or later for the WebSocket client (optional).

## Settings

Set these in the environment of `mise run`; the defaults are in `compose.yml`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ATANOR_CLUSTER_NODES` | 3 | Number of nodes, 1 to 10. |
| `ATANOR_CLUSTER_NODE_CPUS`, `_NODE_MEMORY` | 1.5, 2g | Limits per node. |
| `ATANOR_CLUSTER_STORE_CPUS`, `_STORE_MEMORY` | 1.5, 2g | Limits of SeaweedFS. |
| `ATANOR_CLUSTER_LB_CPUS`, `_LB_MEMORY` | 0.5, 256m | Limits of HAProxy. Every memory limit also sets `memswap_limit` to the same value: no container uses swap. |
| `ATANOR_CLUSTER_HTTP_PORT`, `_ADMIN_PORT`, `_DASHBOARD_PORT`, `_STATS_PORT` | 18080 to 18083 | Host ports of the load balancer. |
| `ATANOR_CLUSTER_BIND` | 127.0.0.1 | Host address the ports bind to. Keep loopback. |
| `ATANOR_CLUSTER_STORE_IMAGE`, `_LB_IMAGE` | pinned digests | Images. |
| `ATANOR_CLUSTER_IMAGE` | `atanor-cluster-node:local`, built by `cluster:up` | The node image. When you set it, `cluster:up` does not build: it uses that image, which needs `curl` (the `harness` target has it). The load tests do not use it: `load:up` builds a [derived image](how-to-build-a-derived-image.md) ([cluster/load/Dockerfile](../cluster/load/Dockerfile)) and starts the cluster with it. |
| `ATANOR_CLUSTER_LEASE_TTL_MS`, `_NET_TICKTIME` | 30000, 60 | Cell lease and Erlang net tick time (seconds). |
| `ATANOR_CLUSTER_GROUP` | none | The discovery group of the nodes started ([`ATANOR_GROUP`](configuration.md#discovery)). `cluster:swap-run` starts the replacement in group `b`, so it does not join the others ([how-to-replace-a-node.md](how-to-replace-a-node.md)). |
| `ATANOR_CLUSTER_REGISTRY_TTL_MS`, `_REGISTRY_RENEW_MS` | 15000, 3000 | How long a node's entry in the store lives, and how often it is renewed (`ATANOR_REGISTRY_*`). A new node is found within the renewal; a node that was killed is forgotten after the TTL plus 2 s. |
| `ATANOR_CLUSTER_STOP_GRACE` | 90s | Time `docker stop` waits for a node to drain; derived from `ATANOR_CLUSTER_SHUTDOWN_MS` (else `ATANOR_SHUTDOWN_MS`, 75 s) plus 15 s. A value at or below the drain, or one that is not seconds, `90s` or `2m`, is refused by the scripts ([rule](configuration.md#the-stop-grace-period)). |
| `ATANOR_CLUSTER_SHUTDOWN_MS`, `_DRAIN_TIMEOUT_MS`, `_DRAIN_CONCURRENCY` | node defaults (75000, 15000, 64) | The node's `stop.shutdown_ms`, `drain_timeout_ms` and `drain_concurrency`. |
| `ATANOR_CLUSTER_BUILD_JOBS` | 6 | Cargo jobs while building. |
| `ATANOR_CLUSTER_RELEASE` | commit, plus `-dirty` | The release id nodes report (`GET /deployments`). |
| `ATANOR_CLUSTER_UP_TIMEOUT` | 300 | Seconds `cluster:up` waits. |
| `ATANOR_CLUSTER_TMPFS` | 0 | `1` keeps the data of the nodes and of SeaweedFS in memory ([below](#keeping-the-data-in-memory)). |
| `ATANOR_CLUSTER_TMPFS_SIZE` | 1g | Size of each tmpfs: one per node (`/var/lib/atanor`) and one for the store (`/data`). |

`scripts/cluster-roll roll` (used by the rolling restart scenario) also reads
`CLUSTER_ROLL_PAUSE` (seconds to wait after each node is ready, default 0) and
`CLUSTER_ROLL_LOGS` (a directory that keeps the log of each container it replaces).

## Keeping the data in memory

Writes wait for the disk under the cell files and under SeaweedFS. On a host whose file system
stalls writes (we saw it on btrfs), the cluster stalls with it: above about 60 requests per second,
every 6 to 10 s all rooms on all nodes waited about 2 s. It comes from the host, not from the
library or from Atanor.

Start the cluster with the data on tmpfs to take the host's disk out of the path:

```sh
ATANOR_CLUSTER_TMPFS=1 mise run cluster:up
```

`cluster/compose.tmpfs.yml` replaces the volumes of the store and the nodes with tmpfs mounts of
`ATANOR_CLUSTER_TMPFS_SIZE` each. Points to know:

- **The default is off, because the data is lost.** It disappears when the container is removed or
  the host restarts, and a node that restarts (`cluster:chaos kill`, a rolling restart) comes back with
  an empty local directory and restores its cells from the store. The store's own data is lost the
  same way: `cluster:chaos restart store` empties the bucket.
- **Set the variable for every `cluster:*` command** that starts or recreates containers
  (`cluster:up`, `cluster:chaos-run`, `cluster:roll`). Without it they use the disk layout and
  recreate containers with it.
- **tmpfs counts against the container's memory limit.** A cell file took about 50 MB in these
  runs (12 rooms on one node: 640 MB), and the store held 684 MB after 19,000 writes. If a node holds
  many cells, raise `ATANOR_CLUSTER_NODE_MEMORY` and `_STORE_MEMORY` together with the size.
- A full tmpfs of a node shows as HTTP 503 `overloaded` (Alambique's `disk_full`); a full tmpfs of the store, as store errors (see Troubleshooting).

Measured on this repository's cluster (3 nodes at 1.5 CPUs, SeaweedFS, HAProxy, 12 rooms `d1` to `d12`, 8
workers, 40 s per run, host: AMD Ryzen AI 5 340, 12 schedulers,
btrfs on an encrypted NVMe root). Latency is that of acknowledged writes, in ms.

| Data | Rate asked | Host load average (1 min) | Sent / acknowledged / refused / unknown | p50 | p99 | Maximum | LOST / DUPLICATED |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tmpfs | 100 | 3.5 | 4,008 / 4,008 / 0 / 0 | 4 | 22 | 205 | 0 / 0 |
| tmpfs | 200 | 4.5 | 7,992 / 7,992 / 0 / 0 | 5 | 46 | 966 | 0 / 0 |
| btrfs | 100 | 2 to 23 (other work) | not recorded | not recorded | 460 to 2,050 | 2,040 to 2,150 | not recorded |
| btrfs | 60 | quiet | not recorded | not recorded | 11 | 217 | not recorded |

The btrfs rows are the earlier runs of this investigation (7 runs of 40 s at 100 per second, and one check
at 60 per second), kept as they were; their request counts were not recorded. The tmpfs rows are one run each,
with a load average of 3.5 to 4.5 from the run itself, so they are single measurements. The one request over 1
s in the 200 run is one request, not the periodic 2 s stall. The same hardware with the data on btrfs under a shared load gave stalls of 1 to 3 s
(section 12 of Alambique's `docs/design.md` has its table at 120 and 200 requests per second).

One `ATANOR_CLUSTER_TMPFS=1 mise run cluster:chaos-run kill` (60 requests per second, host load average
4 at the start, 14 at the end) killed node-2 with 5 of 12 rooms: 5,820 sent, 5,819 acknowledged, 0 refused,
1 unknown (an HTTP 502, not stored), LOST 0, DUPLICATED 0. The rooms were served again 8.8 s after the first
failure (outage 7.5 s); the node was healthy again 7.2 s after `start`. p99 by phase: before 22, during
2,013 (the killed node's rooms), rejoin 101, after 114. The restarted node began with an empty tmpfs.

## Steps

1. Start the cluster. The first run builds the image, generates the secrets and
   waits until the three nodes are ready and the balancer has them all in
   rotation. A second run reuses everything.

   ```sh
   mise run cluster:up
   ```

   ```text
   generated cluster/secrets/cookie
   ...
    Container atanor-cluster-store-1 Healthy
    Container atanor-cluster-bucket-1 Exited
   waiting for 3 nodes...
   cluster ready: 3 nodes, release 67d1373032b7-dirty
     http      http://127.0.0.1:18080
     admin     http://127.0.0.1:18081   (token: cluster/secrets/admin_token)
     dashboard http://127.0.0.1:18082/workers?token=$(cat cluster/secrets/dashboard_token)
     balancer  http://127.0.0.1:18083/stats
   ```

2. Look at it.

   ```sh
   mise run cluster:chaos status
   ```

   ```text
   atanor-cluster-node-2     Up About a minute (healthy)
   atanor-cluster-node-1     Up About a minute (healthy)
   atanor-cluster-bucket-1   Exited (0) 44 minutes ago
   atanor-cluster-lb-1       Up 41 minutes
   atanor-cluster-store-1    Up 7 minutes (healthy)
   load balancer (server slots in rotation):
     node1 UP
     node2 UP
     node3 UP
   views of the cluster:
     atanor-cluster-node-3 (atanor@node-3.cluster) sees 3 nodes
     atanor-cluster-node-2 (atanor@node-2.cluster) sees 3 nodes
     atanor-cluster-node-1 (atanor@node-1.cluster) sees 3 nodes
   ```
   The balancer's slots (`node1`..) are numbered in the order DNS answered, not
   by node.

3. Deploy the example, the [scoreboard](../examples/scoreboard/README.md). It
   is a WASM worker, so the component travels in the package and the nodes need
   no new image. The task builds the component, runs the `atanor` command of the node image (`docker run IMAGE deploy ...` in the node's network), uses
   the operator token once to create a token limited to
   `worker:scoreboard:deploy`, `activate` and `read`, keeps it in
   `cluster/secrets/deploy-token`, and deploys with that token.

   ```sh
   mise run cluster:deploy-example
   ```

   ```text
   token atn_da778a3b31c72449ddacf15d (scoreboard-deploy)
   scopes: worker:scoreboard:deploy worker:scoreboard:activate worker:scoreboard:read
   expires: never
   package 40fb5077586e27a6c8732e39376f56b493c4b0b44150290d2d3d3c6b7d80dd7e (scoreboard, wasm, 117504 bytes)
   scoreboard: active 40fb5077586e27a6c8732e39376f56b493c4b0b44150290d2d3d3c6b7d80dd7e, revision 1, previous none
   ```

   The nodes follow within their poll interval (5 seconds).

4. Use it through the load balancer. `scoreboard.localhost` resolves to
   loopback, so no `Host` header is needed.

   ```sh
   curl -s -X POST "scoreboard.localhost:18080/rooms/lobby/scores?id=t-1&player=ada&points=1" -w ' [%{http_code}]\n'
   curl -s -X POST "scoreboard.localhost:18080/rooms/lobby/scores?id=t-4&player=bob&points=10"
   curl -s scoreboard.localhost:18080/rooms/lobby/writes
   curl -s scoreboard.localhost:18080/rooms/lobby
   ```

   ```text
   {"id":"t-1","room":"lobby"} [201]
   {"id":"t-4","room":"lobby"}
   {"room":"lobby","writes":[{"seq":1,"id":"t-1","player":"ada","points":1},{"seq":2,"id":"t-4","player":"bob","points":10}]}
   {"room":"lobby","writes":2,"last_seq":2,"ranked_through":2,"rankings":[{"rank":1,"player":"bob","total":10},{"rank":2,"player":"ada","total":1}]}
   ```

   Watch the room over a WebSocket and post from another terminal:

   ```sh
   scripts/scoreboard-watch http://scoreboard.localhost:18080 lobby 6
   ```

   ```text
   {"type":"joined","room":"lobby"}
   {"type":"score","id":"ws-3","player":"cy","points":20}
   {"type":"score","id":"ws-4","player":"cy","points":20}
   {"type":"rankings","ranked_through":9,"top":[{"rank":1,"player":"cy","total":100},{"rank":2,"player":"bob","total":10},{"rank":3,"player":"ada","total":6}]}
   ```

5. Check the writes. `write` sends scores with unique ids over several rooms and
   logs each answer; `verify` compares the log with the rooms. Every request is
   put in one of three groups: **acknowledged** (201), **refused** (the call
   provably did not run: 503 `unavailable` with `no_quorum`, `owner_down`,
   `owner_unreachable`, `fenced`..., 503 `overloaded`, a 503 of the balancer, a
   refused connection) or **unknown** (a timeout or reset, 503
   `unknown_outcome`, 502, 504, any other 5xx). `verify` reports acknowledged
   writes that are not stored (LOST) or stored twice (DUPLICATED), and how many
   unknown and refused writes were stored. An unknown write that was stored is
   normal; a refused one that was stored is a bug and is reported as such.

   ```sh
   U=http://scoreboard.localhost:18080
   mise run cluster:scoreboard-check write --url $U --rooms r1,r2,r3 --count 300 --workers 6 --log /tmp/r1.log
   mise run cluster:scoreboard-check verify --url $U --log /tmp/r1.log
   ```

   ```text
   sent 300 over 3 rooms with 6 workers, log /tmp/r1.log
   sent 300: acknowledged 300, refused 0, unknown 0 (no answer 0); stored rows 300
   acknowledged: LOST 0, DUPLICATED 0
   stored although not acknowledged: unknown 0 of 0, refused 0 of 0
   ```

6. Break something. `cluster:chaos ACTION TARGET`, with `TARGET` `node-N`,
   `store` or `lb`:

   | Action | Effect |
   | --- | --- |
   | `kill` | SIGKILL; the container stays down. |
   | `stop`, `restart` | Graceful stop (grace derived from `stop.shutdown_ms`, 90 s by default), and start again for `restart`. |
   | `start` | Start a killed or stopped container. |
   | `pause`, `unpause` | Freeze with the cgroup freezer, and thaw. |
   | `partition` | A node: drops traffic with the other nodes inside its own network namespace (`partition node-3 node-1` cuts one pair). The store: disconnects it from the network. |
   | `heal` | Undoes `partition`. |
   | `status` | As in step 2. |

   Kill a node while writing, bring it back, check:

   ```sh
   mise run cluster:chaos kill node-2
   mise run cluster:scoreboard-check write --url $U --rooms m1,m2,m3,m4 --count 100 --workers 4 --log /tmp/r2.log
   mise run cluster:chaos status | tail -9
   mise run cluster:chaos start node-2
   mise run cluster:scoreboard-check verify --url $U --log /tmp/r2.log
   ```

   ```text
   kill atanor-cluster-node-2 (d327e65a7f0e)
   sent 100 over 4 rooms with 4 workers, log /tmp/r2.log
   load balancer (server slots in rotation):
     node1 UP
     node3 UP
   views of the cluster:
     atanor-cluster-node-3 (atanor@node-3.cluster) sees 2 nodes
     atanor-cluster-node-1 (atanor@node-1.cluster) sees 2 nodes
   start atanor-cluster-node-2 (d327e65a7f0e)
   sent 100: acknowledged 100, refused 0, unknown 0 (no answer 0); stored rows 100
   acknowledged: LOST 0, DUPLICATED 0
   stored although not acknowledged: unknown 0 of 0, refused 0 of 0
   ```

   The load balancer takes a node out of rotation when it is not ready or has
   no quorum (`/health/serving`, step 7), within about two seconds
   (`inter 1s fall 2`). The scenarios of step 7 do this under continuous load.

7. Run a scenario under continuous load and measure it.

   ```sh
   mise run cluster:chaos-run SCENARIO [--rooms 12] [--workers 8] [--rate 60] [--warmup 25] [--hold S] [--settle 40]
   ```

   `SCENARIO` is `kill`, `pause`, `partition`, `store-restart`,
   `rollout-deploy` or `rollout-restart`. The task starts the load
   (`scoreboard-check write` over `--rooms` rooms, `--workers` concurrent
   requests, at most `--rate` requests per second in total) and a WebSocket
   client that reconnects (`scoreboard-watch --log`), waits `--warmup` seconds,
   asks the admin API which node owns each room, injects the fault into the
   node that owns most of them (`--target node-N` to choose), undoes it after
   `--hold` seconds (defaults: kill 20, pause 40, which is longer than the 30 s
   lease, partition 40), waits `--settle` seconds, stops the load by PID and
   runs `verify`. The logs of every container and the JSON result go to
   `--out` (default `/tmp/atanor-o9x-SCENARIO-TIME`). The exit status is 1 when
   an acknowledged write is lost or duplicated, or a refused write is stored.
   `rollout-deploy` builds the scoreboard with another `x-scoreboard-version`
   (`--version`) and deploys it with `atanor deploy --activate`.
   `rollout-restart` builds the node image with a new release id and runs
   `scripts/cluster-roll roll`: for each node in turn, a graceful stop, a
   recreate from the new image under the same name, and a wait until it is
   ready and every node sees it.
   The load generator is one Python process; it uses about one core.

   What it measures, per run:

   - requests sent, acknowledged, refused and unknown, and those with no answer
     at all (a client timeout of 10 s or a reset: a subset of unknown);
   - LOST and DUPLICATED acknowledged writes (must be 0) and how many unknown
     and refused writes were stored;
   - *restore*: seconds from the start of the fault command until the cells the
     faulted node owned are served again by another node, read from the
     answers of the load. A call is disturbed when it failed or took more than
     2.5 s (`--slow-ms`); the cells are served again when the last disturbed
     call that ended during the fault ends, or, if it failed, when the next
     acknowledged call does. `not hit` means no call was disturbed. A final
     read of `GET /cells?node=` says where the rooms are afterwards (in the
     JSON result, `moved`);
   - p50 and p99 of acknowledged requests, by the time the request ended:
     *before* (from 12 s after the start), *during* (fault command until it is
     undone), *rejoin* (the next 15 s) and *after*;
   - for the WebSocket client, which watches one room of the faulted node: the
     acknowledged writes it did not receive after its first connection
     (*missed*, counting those lost while it was reconnecting) and the pushes it
     received twice.

   One run of each fault on one 12-core machine that also ran other containers,
   with 3 nodes at 1.5 cores, the default 30 s lease, 12 rooms, 8 workers and
   60 requests per second (each run takes about 1.5 to 2 minutes). Latency is
   that of acknowledged writes, in ms; p99 values above 1 s are mostly the host's
   disk stalls (see "Keeping the data in memory"):

   | Run | Faulted | Sent | Acked | Refused | Unknown (no answer) | LOST / DUPLICATED | Stored: unknown / refused | Restore (s) | p50 / p99 before | during | rejoin | after |
   | --- | --- | ---: | ---: | ---: | ---: | --- | --- | ---: | --- | --- | --- | --- |
   | kill | node-2 | 5059 | 5058 | 0 | 1 | 0 / 0 | 0 of 1 / 0 of 0 | 0.85 | 6 / 143 | 6 / 729 | 9 / 2088 | 8 / 728 |
   | pause | node-1 | 5654 | 5637 | 0 | 17 | 0 / 0 | 16 of 17 / 0 of 0 | 19.41 | 6 / 24 | 6 / 155 | 7 / 695 | 8 / 723 |
   | partition | node-2 | 6105 | 6088 | 2 | 15 | 0 / 0 | 0 of 15 / 0 of 2 | 13.31 | 6 / 18 | 6 / 24 | 7 / 27 | 7 / 1196 |
   | store-restart | all | 3047 | 3037 | 1 | 9 | 0 / 0 | 0 of 9 / 0 of 1 | 43.93 | 6 / 1852 | 6 / 7 | 7 / 3265 | 6 / 2507 |
   | rollout-deploy | all | 4698 | 4698 | 0 | 0 | 0 / 0 | 0 of 0 / 0 of 0 | not hit | 7 / 570 | 6 / 32 | 6 / 30 | 6 / 27 |
   | rollout-restart | all | 4529 | 4529 | 0 | 0 | 0 / 0 | 0 of 0 / 0 of 0 | not hit | 5 / 12 | 7 / 1070 | 6 / 1881 | 5 / 1895 |

   Reading the table:

   - **No acknowledged write was lost or duplicated** in any fault.
   - **Every unknown write of `pause` was stored**: the frozen node finished
     them after `unpause`. No unknown write of the other faults was stored, and
     no refused write was stored.
   - **A killed node's cells** are served again by another node in about a
     second. **A paused node's cells** take about 19 s and **a partitioned
     node's** about 13 s: the detector's decision, not the 30 s lease.
   - **The balancer follows the partition.** With `/health/ready` the balancer
     keeps sending a third of the traffic to the cut node, which answers 503
     `no_quorum` at once. With `/health/serving` it takes the node out within
     about two seconds.
   - **`store-restart`.** Cells are served again about 30 to 45 s after the
     restart began. Writes that fail in the window are refused with 503
     `store_unavailable` (the call did not run) or answered 503
     `unknown_outcome` (a cell stopped on an upload, which may have reached the
     store); the clients that waited were served.
   - **`rollout-deploy` is atomic for clients.** The last answer with the old
     version comes about 17 ms before the first with the new one, across all
     rooms, and nothing is refused. The new version first shows about a second
     after the command starts, which is when `atanor deploy` returns.
   - **`rollout-restart`** (a new image, one node at a time) refuses nothing in
     this run. A POST that reaches a stopping owner can be refused with 503
     `owner_down` in 2 to 3 ms, or answered 503 `unknown_outcome`; a client
     retries the first and uses ids to retry the second. A WASM worker runs on
     the node that received the request, and its cell calls reach the owner
     through Alambique's router, which meets a draining owner as `owner_down`
     at once; a native worker routed to the owner waits up to
     `routing.leave_wait_ms` (3 s) first ([design §8.11](design.md#811-draining-and-stopping-gracefully)).
   - **Latency noise.** Stalls of about 2 s that hit every room of one node at
     once appear above about 60 requests per second when the data is on btrfs,
     and not with the data on tmpfs ([Keeping the data in memory](#keeping-the-data-in-memory)).
     They are not the nodes' CPU limit, the store's CPU or latency, or the
     connection pool. Read the *during*, *rejoin* and *after* p99 with that in
     mind: only a p99 well above 2 s, and the restore column, show a fault.

   To reproduce one row: `mise run cluster:up`, `mise run
   cluster:deploy-example`, then `mise run cluster:chaos-run kill` (twice for
   two runs). The default load is 8 workers at 60 requests per second; `--workers`
   and `--rate` change it. The load is one Python process and the WebSocket client one Node.js process.

8. Look at resource use, once up and once under 4,000 writes from 6 client
   threads (`docker stats`):

   ```text
   NAME                     CPU %     MEM USAGE / LIMIT   PIDS     (idle)
   atanor-cluster-node-1    0.34%     154.6MiB / 2GiB     58
   atanor-cluster-lb-1      0.16%     15.1MiB / 256MiB    12
   atanor-cluster-store-1   4.61%     223.7MiB / 2GiB     8

   NAME                     CPU %     MEM USAGE / LIMIT   PIDS     (4,000 writes)
   atanor-cluster-node-1    52.02%    177.2MiB / 2GiB     58
   atanor-cluster-node-2    20.51%    161.6MiB / 2GiB     58
   atanor-cluster-node-3    23.61%    191.8MiB / 2GiB     59
   atanor-cluster-lb-1      14.82%    17.84MiB / 256MiB   12
   atanor-cluster-store-1   47.00%    463.3MiB / 2GiB     10
   ```

   CPU % is of one core; the limit is 150% per node.

9. Remove everything. It prints the ids of the containers it removes and keeps
   the image and the secrets.

   ```sh
   mise run cluster:down
   ```

   ```text
   removing containers:
     dd8052d3a855 atanor-cluster-node-2
     2ed346864c01 atanor-cluster-node-3
     7a0b56a6891d atanor-cluster-node-1
     01a23255694e atanor-cluster-bucket-1
     dc34a9ad46b2 atanor-cluster-lb-1
     1d4ee2b94ce5 atanor-cluster-store-1
   project atanor-cluster removed
   ```

   Check that nothing is left:
   `docker ps -a --filter label=com.docker.compose.project=atanor-cluster`.
   The scripts act only on that label.

## Troubleshooting

- **The image build stops with a git error.** `mix deps.get` clones Alambique
  at the tag in `alambique.ref` from the public repository. Check the network.
- **The build fails fetching crates or packages.** The build needs the
  internet; run `mise run cluster:up` again, the Rust build resumes from its
  cache.
- **`ports are not available`.** Another program uses 18080 to 18083. Set the
  `ATANOR_CLUSTER_*_PORT` variables.
- **`cluster:up` times out with fewer nodes ready.** Look at
  `docker logs atanor-cluster-node-1`. A token shorter than 32 bytes is
  refused: delete `cluster/secrets` and run `cluster:down` first.
- **A node does not rejoin after `partition`.** Run `cluster:chaos heal` for it;
  the rules vanish when the container restarts.
- **`deploy-example` says the token is refused.** The cluster was recreated;
  the script creates a new token by itself when the stored one stops working.
- **A node I replaced shows as a lost node.** Nodes are named after their
  service (`atanor@node-N.cluster`), so a restart, even with another address, is the same
  node. Only a container created under another name (for example by
  `docker compose up --scale`) is a different node.
- **The balancer shows a node DOWN though it is up.** The balancer asks
  `/health/serving`: a node without a quorum (cut off, or alone after the others
  left) answers 503 `no_quorum` there while `/health/ready` stays 200
  ([how-to-use-the-admin-api.md](how-to-use-the-admin-api.md)).
- **Requests stall for about 2 s above 60 requests per second.** Look at the host's
  file system under Docker's data directory. On btrfs this happened with the cell files and
  the store's data both on it; start with `ATANOR_CLUSTER_TMPFS=1`
  ([above](#keeping-the-data-in-memory)).
- **Writes answer 503 `overloaded`, or 500 from the store, with `ATANOR_CLUSTER_TMPFS=1`.** A tmpfs is full.
  Check `docker exec atanor-cluster-node-1 df -m /var/lib/atanor` and
  `docker exec atanor-cluster-store-1 df -m /data`, then run `cluster:down` and start again with a
  larger `ATANOR_CLUSTER_TMPFS_SIZE` (and memory limits). With 512m, two nodes filled in about four minutes
  of load.
- **The data is gone after a host restart.** That is what `ATANOR_CLUSTER_TMPFS=1` does. Start
  without it to keep the data on disk.

## Next steps

- [how-to-run-a-cluster.md](how-to-run-a-cluster.md) explains takeover, the
  detector and what clients see when a node fails.
- [how-to-replace-a-node.md](how-to-replace-a-node.md) for a swap of one node by
  another under load (`mise run cluster:swap-run`).
- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) and [cli.md](cli.md)
  for tokens and deploys.
- [examples/scoreboard](../examples/scoreboard/README.md) for the app and its
  checker.
