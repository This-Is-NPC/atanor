# How to operate Atanor

**The question:** What do I watch on a running Atanor cluster, which alerts do I set, how do I back it up and
restore it, how do I replace a node or move to a new version, and what do I do when the store breaker opens, the
disk fills, nodes answer 503 `overloaded` or cells wake slowly?

This guide is a runbook and does not stand alone: it links to the guides that explain each tool. It assumes a
cluster set up as in [how-to-run-in-production.md](how-to-run-in-production.md). Atanor ships no metrics
exporter and no alert rules ([operating-a-cluster-compared.md](operating-a-cluster-compared.md)): the signals
below are fields of the admin API, log lines and [telemetry events](telemetry.md) that you collect with your own
tools.

Each fact is marked. **Observed** is output of a run on 2026-11-16 (see [How this was checked](#how-this-was-checked)).
**Inference** is read from the code or the documentation and was not run. A suggested limit is a starting point,
not a measured one.

## What lives where

| Place | Holds | If you lose it |
| --- | --- | --- |
| The bucket (`ATANOR_STORE`, prefix `atanor` by default) | The cells, the packages and heads of the workers, the alarm and job index, the audit log, crash reports ([design §5](design.md#5-deployments-and-the-store-layout)) | Everything. It is the only state that matters, and the one to back up. |
| `data_dir` of a node (`/var/lib/atanor/cells`) | Local copies of cells, compiled WASM, crash breadcrumbs | Nothing: a node restores its cells from the bucket. |
| The node (container, VM) | Nothing. It applies the worker heads it reads from the bucket. | Nothing. Start another one. |
| The secrets (S3 keys, admin token, cookie) | Access | Keep them where you keep the rest of your secrets. They are not in the bucket. |

## What to monitor

Read the node with `GET /runtime`, `GET /health` and `GET /health/serving` on the admin port (port 4001; the
bearer token is the admin token), and collect the telemetry events in-process. Examples use `$ADMIN` for
`http://NODE:4001` and `$TOKEN` for the admin token ([how-to-use-the-admin-api.md](how-to-use-the-admin-api.md)).

### Admin API fields

```sh
curl -s -H "authorization: Bearer $TOKEN" $ADMIN/runtime | jq -c '.admission, .store'
```

```text
{"refused":{"memory":0,"disk":0,"in_flight":0,"nested_calls":0,"queue_timeout":0,"worker_queue":0,"wake_gate":0,"awake_limit":0,"busy":0,"disk_full":0},"max_in_flight":1024,"disk_refusing":false,"in_flight":0,"refusing":false,"disk_budget_bytes":19899324825,"disk_used_bytes":375776,"limit_bytes":null,"refuse_at_bytes":false,"working_set_bytes":null}
{"default":{"state":"closed","failures":0,"since_ms":1794809749751}}
```

(Observed. `limit_bytes` is `null` because the container had no memory limit; give the container one, or
`ATANOR_MEMORY_LIMIT`, or the memory gate is off.)

| Field | Suggested limit | Why |
| --- | --- | --- |
| `/health/serving` status | Not 200 for more than 30 s | 503 is `starting`, `draining` or `no_quorum` ([design §10.2](design.md#102-admin-api)). A balancer takes the node out by itself; an alert says that it did. |
| `/health` `.store.<location>.state` | Not `closed` | The store circuit breaker (`closed`, `open`, `half_open`). It never makes the node unready, so only this field and the log say it is open. |
| `/health` `.store.<location>.failures` | Above 0 for 1 minute | A closed breaker with failures is a store that has begun to fail. The breaker opens at 5 in a row. |
| `/runtime` `.admission.working_set_bytes` / `.limit_bytes` | 0.75 for 5 minutes (the node refuses at 0.85) | The memory gate refuses with 503 `overloaded` at `memory: [refuse_fraction: 0.85]`. Page before it. |
| `/runtime` `.admission.refusing` | `true` | The memory gate is closed: every new request is refused. |
| `/runtime` `.admission.disk_used_bytes` / `.disk_budget_bytes` | 0.7 for 5 minutes, 0.9 at once | At 0.7 the node starts to hibernate idle cells to free the disk; at 0.95 it refuses every request ([design §4.4](design.md#44-the-disk-budget)). |
| `/runtime` `.admission.disk_refusing` | `true` | The disk gate is closed. |
| `/runtime` `.admission.in_flight` / `.max_in_flight` | 0.7 for 5 minutes | At 1,024 requests at once the node refuses with `in_flight`. A high value with a low CPU means requests wait for the store or a cell. |
| `/runtime` `.admission.refused.*` | Any increase of `memory`, `disk` or `in_flight`; a rate above 1% of requests for `wake_gate`, `awake_limit`, `busy`, `disk_full`, `queue_timeout`, `worker_queue`, `nested_calls`; any increase of `unavailable` | Each gate counter is one reason of 503 `overloaded`, and every such 503 is in one of them. `unavailable` counts every other 503, and `.admission.unavailable_by_reason` names why (`owner_unreachable`, `fenced`, `unknown_outcome`, `overloaded_unattributed`, ...). They count since the node started: alert on the rate. |
| `/runtime` `.consent.open` | `true` on a node where several teams deploy | No `hosts`, `http_allow` or `namespaces` ceiling is set, so any deployer may claim routes, namespaces and outbound hosts ([who may claim what](how-to-run-in-production.md#who-may-claim-what)). The node also warns at start. |
| `/runtime` `.pressure.hibernated`, `.wakes` | A steady rise of `pressure.hibernated`; a `wakes` rate far above your usual | `pressure.hibernated` counts cells hibernated by memory pressure; `wakes` counts cells woken on this node since it started, and `/runtime` `.wake_ms` (`total`, `max`) is the time they took in milliseconds: `total / wakes` is the mean wake. Cells that go to sleep and wake again at once say the awake set is too big for the memory ([memory](configuration.md#cells-limits-memory-and-store-requests)). |
| `/runtime` `.cgroup.events.oom_kill` | Any increase | The kernel killed a process of the container. |
| `/runtime` `.cgroup.memory_current` / `.memory_max` | 0.9 | `memory_current` includes the page cache; the gate uses the working set, so this is the late warning. `memory_max` is `null` without a limit. |
| `/runtime` `.top_message_queue[0].message_queue_len` | 10,000 | A process that cannot keep up. `.top_message_queue[0].name` names it. |
| `/runtime` `.run_queues` | The sum above twice the scheduler count for 1 minute | The VM has more runnable work than CPU. |
| `/runtime` `.wasm.queued_calls`, `.wasm.rejected_calls` | `rejected_calls` increases | Calls wait for a WASM pool thread, or were refused because the queue was full. |
| `/runtime` `.wasm.traps_timeout`, `.traps_memory`, `.traps_cpu` | Any increase | A worker hits its limits ([design §14](design.md#14-wasm-engine)). |
| `/nodes` `.nodes[].state` | Not `alive` for 30 s | The failure detector's view of a peer: `suspect`, `link_broken` or `down`. Ask every node: the view is per node. |
| `/jobs/:namespace/:key` | A `pending` job whose `due_at_ms` is older than 1 minute, with no `running` job | A job that does not start. See [a restored cell whose jobs never start](#restore-from-a-copy-of-a-live-bucket). |
| `/crashes` | A new report | A VM died ([how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md)). |

### Telemetry events and log lines

Attach handlers as in [telemetry.md](telemetry.md). The ones to chart or alert on:

| Event or log | Measure | Suggested limit | Why |
| --- | --- | --- | --- |
| `[:atanor, :http, :reject]` | rate by `reason` | `:memory`, `:disk`, `:in_flight`, `:disk_full` above 0; `:queue_timeout`, `:worker_queue` above 1% of requests | The 503s the node chose to send, with the gate that sent them. |
| `[:atanor, :call]` | `duration` p99; share of `result: :error` by `reason` | p99 at twice your normal; errors above 1% | The worker's own latency and failures (`:crashed`, `:bad_return`, `{:limit, _}`). |
| `[:atanor, :forward]` | share of `result` other than `:ok` | `:lost` or `:unknown_outcome` above 0 | Requests that crossed nodes and failed or may have been applied. |
| `[:atanor, :node, :down]`, `[:atanor, :node, :link_broken]` | count | Any | A peer is gone, or only this node cannot reach it. |
| `[:atanor, :node, :suspect]` followed by `:alive` | count | Above 5 an hour | A late heartbeat; many say the detector is too tight for the network ([how-to-run-a-cluster.md](how-to-run-a-cluster.md)). |
| `[:atanor, :cell, :take_over]` | `result` | Not `:ok` or `:moved`; `:no_quorum` at all | A cell of a lost node that was not taken over. |
| `[:atanor, :disk, :sample]` | `level` | `:reclaim` for 5 minutes, `:refuse` at once | The disk monitor's level. |
| `[:atanor, :node, :drain]` | `errors` | Above 0 | Cells that could not be handed back; the log has a warning too. |
| `[:atanor, :job, :dead]`, `[:atanor, :alarm, :failed]` with `final: true` | count | Any | Work that was given up. |
| `[:atanor, :crash, :detected]` | count | Any | The previous VM died. |
| `[:alambique, :store, :breaker, :open]` | count | Any | The store breaker opened (Alambique's `docs/telemetry.md`). |
| `[:alambique, :cell, :wake]` | `duration`, `store_time` | `duration` above 1 s | A slow wake; the node also logs it. |
| `[:alambique, :admission, :wake_queue]` | `result` | `:expired` or `:full` | Wakes waiting for a slot, or refused. |
| `[:alambique, :cell, :quarantined]` | count | Any | A cell that crashed the VM repeatedly and was frozen. |
| Log `atanor: store breaker open for ...` | line | Any | The cause is the lines before it: `atanor: store failure: :get on default: reason=:timeout_recv counted=true`. |
| Log `atanor: slow wake of ...` | line | Any | A wake of 1 s or more, with the store requests it made and the time they took. |
| `[:alambique, :cell, :hibernate]` with `compaction: :deadline`, `:deadline_error`, `:busy` or `:error`, `/runtime` `.hibernations.compaction` | count | `deadline`, `deadline_error`, `busy` or `error` rising | Cells leave long WAL chains (`.hibernations.tail_max` is the longest left after a compaction), so their next wake reads many segments. `busy` is a release the node's `compaction: [release_concurrency:]` (4) refused: raise it, or check why the releases are slow. The node also logs `atanor: release compaction of ...`, at most once per second. Check the store's latency; `compaction: [release_deadline_ms:]` (3 s by default) passes through to Alambique ([configuration](configuration.md)). |

## Recommended alerts

| Alert | Condition | What it means | First action |
| --- | --- | --- | --- |
| Store breaker open | `.store.*.state != "closed"` on any node, or the log line | The store failed 5 requests in a row. Awake cells may still answer, cold cells get 503 `store_unavailable`. | [Store breaker open](#the-store-breaker-is-open). |
| Memory gate closed | `.admission.refusing == true`, or `refused.memory` increases | The working set passed 85% of the limit; every new request is refused. | [503 overloaded](#requests-get-503-overloaded). |
| Disk gate closed | `.admission.disk_refusing == true` | `data_dir` passed 95% of its budget. | [Disk full](#the-disk-is-full). |
| Disk near the budget | `disk_used_bytes / disk_budget_bytes >= 0.7` | The node is hibernating idle cells to make room. | Raise the budget or the disk, or lower `awake: [max_cells:]`, before 0.95. |
| Node not serving | `/health/serving` not 200 for 30 s while no drain or deploy runs | `starting`, `draining` or `no_quorum`. | Read the `reason` in the body; `no_quorum` is the private network ([how-to-run-in-production.md](how-to-run-in-production.md#troubleshooting)). |
| Peer down | `[:atanor, :node, :down]`, or `/nodes` not `alive` | A node is gone. Its cells are taken over once its lease ends, about 32 s. | Start a replacement ([below](#replace-a-node)); tell Atanor the node is gone if the platform knows ([how-to-use-the-admin-api.md](how-to-use-the-admin-api.md), step 7). |
| Takeover failing | `[:atanor, :cell, :take_over]` with `{:error, _}` or `:no_quorum` | A cell stays unavailable until its lease expires, or this node is not in a majority. | The reason is in the event; for `:no_quorum` fix the network. |
| OOM kill | `.cgroup.events.oom_kill` increases | The container hit its memory limit. | Raise the limit or lower the load; read `/runtime` `.top_memory`. |
| Crash report | `/crashes` gains an entry, or `[:atanor, :crash, :detected]` | A VM died. | [how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md). |
| Dead jobs | `[:atanor, :job, :dead]` | A job failed `max_attempts` times or the store failed for `infrastructure_timeout_ms`. | `GET /jobs/:namespace/:key?state=dead`; retry or discard ([how-to-use-jobs.md](how-to-use-jobs.md)). |
| Jobs that never start | A `pending` job older than 1 minute, no `running` job | The cell's wake-up entry is missing from the bucket. | [Restore from a copy of a live bucket](#restore-from-a-copy-of-a-live-bucket). |
| Slow wakes | `[:alambique, :cell, :wake]` above 1 s, or the `slow wake` log line | The store is slow, or a cell's chain is long. | [Slow wake](#cells-wake-slowly). |
| Backup old | No new backup for twice your interval | You cannot restore to a recent point. | Run it; look at why it stopped. |

## Back up and restore

The bucket is the backup target. Atanor documents no backup of it
([operating-a-cluster-compared.md](operating-a-cluster-compared.md)); Alambique can rewind a cell to a recorded
point inside its retention window, which does not help if the bucket is gone
(Alambique's `docs/how-to-operate-a-cell.md`, step 3).

**What to copy.** Every object under the bucket and prefix: `cells/`, `packages/`, `workers/`, `versions/`,
`owners/`, `meta/`, `alarms/`, `audit/`. Without `packages/` and `workers/` the nodes have no worker to run;
without `owners/` a cell namespace has no owner. Not copied, by design: the secrets, and the `data_dir`.

**How to copy.** Any S3 client works. The commands below use the AWS CLI from the `amazon/aws-cli` image,
in the same Docker network as the store. They fit the
[README quick start](../README.md#run-it-in-1-minute), run from the directory where you ran it: the network
`atanor-net`, the store `atanor-store:8333`, the bucket `atanor` (the node keeps its objects under the default prefix `atanor`, so they sit at
`atanor/...` inside it; the copy takes the whole bucket either way), and the keys in
`atanor-secrets/access_key` and `atanor-secrets/secret_key`. For another setup, change those names.

The function `s3` runs one AWS CLI command. The keys reach the container as environment variables, so they
show in `docker inspect` while it runs. `--user` makes the files in `backup/` yours, not root's; `HOME=/tmp`
gives that user a writable home. On the host, `backup/` is the backup directory and `backup/bucket` holds the
copy; in the container the same directory is `/b`. The first call pulls `amazon/aws-cli` (about 85 s on a
2 vCPU VM, 2026-11-18).

```sh
mkdir -p backup
s3() { docker run --rm --network atanor-net --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e AWS_ACCESS_KEY_ID="$(cat atanor-secrets/access_key)" \
  -e AWS_SECRET_ACCESS_KEY="$(cat atanor-secrets/secret_key)" -e AWS_DEFAULT_REGION=us-east-1 \
  -v "$PWD/backup:/b" amazon/aws-cli --endpoint-url http://atanor-store:8333 "$@"; }
```

Copy the bucket `atanor` (all of it) to `backup/bucket`, and copy it back to restore:

```sh
s3 s3 sync s3://atanor /b/bucket     # back up: bucket to the host
s3 s3 sync /b/bucket s3://atanor     # restore: host to the bucket
```

The restore needs a store that is running with its bucket created, as in step 3 of the quick start. Start
the new node on an empty `data_dir` that the node's user (uid 10001) can write: a named volume
(`-v atanor-data:/var/lib/atanor/cells`) is. A host directory that does not exist yet is not: Docker creates
it as root, and the node exits with `data_dir_unusable` (`Permission denied`); create it first and
`chown 10001` it. When you are done, remove `backup/`, the image (`docker rmi amazon/aws-cli`), and the
volumes the removed containers left (`docker volume ls`, then `docker volume rm`): `docker rm -f` without `-v`
keeps a container's anonymous volume. The measurements below were taken
with MinIO's `mc mirror`, whose progress tables they show; `s3 s3 sync` makes the same copy and prints
other lines.

**Which copy is safe.** Read this before you choose, because the two ways differ ([the evidence](#restore-from-a-copy-of-a-live-bucket)):

- **A copy taken after every node drained is consistent.** `POST /drain` on each node hands every cell back and
  stops the node. Copy, then start the nodes. It needs a window without service.
- **A copy taken while nodes serve restores the data, and can leave jobs and alarms that never fire.** The cells
  restore to a consistent prefix. The index of wake-ups under `alarms/` is copied at another moment than the cells,
  so a cell can come back with a pending job and no index entry. Use it only with the repair below.

### Test data

The rest of this section uses the [scoreboard example](../examples/scoreboard/README.md), a WASM worker that keeps
one cell per room, and a node of an image built from this repository (`docker build --target runtime`, release
`runbook`), over a disposable SeaweedFS 4.48. The commands start the store and a node as in the
[README](../README.md#run-it-in-1-minute); names are shortened here (`store`, `node-a`). Three rooms are
written, and a fingerprint is taken: the rows and a hash of them, read through the worker.

The scoreboard needs no build toolchain. Each release attaches it, already compiled, as
`atanor-scoreboard-VERSION.tar.gz` (with a `.sha256`); the version below is the one of the image you run.
Download it, then deploy it as in step 5 of the [README quick start](../README.md#run-it-in-1-minute), with the
directory `scoreboard` in place of `atanor-hello`:

```sh
VERSION=0.8.0 # x-release-please-version
curl -fsSLO "https://github.com/This-Is-NPC/atanor/releases/download/v$VERSION/atanor-scoreboard-$VERSION.tar.gz"
curl -fsSL "https://github.com/This-Is-NPC/atanor/releases/download/v$VERSION/atanor-scoreboard-$VERSION.tar.gz.sha256" | sha256sum -c -
tar -xzf "atanor-scoreboard-$VERSION.tar.gz"
docker run --rm --network atanor-net -v "$PWD/atanor-secrets:/run/secrets:ro" -v "$PWD/scoreboard:/w:ro" \
  -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
  -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
  "$IMAGE" deploy /w --bucket s3://atanor --activate
```

To build it yourself instead (needs Rust, see [how-to-build-and-test.md](how-to-build-and-test.md)), run
`mise run build:scoreboard` in a clone and deploy `examples/scoreboard`.

```sh
fp() { for room in alpha beta gamma; do
  body=$(curl -s -H "host: scoreboard.localhost" "http://127.0.0.1:$PORT/rooms/$room/writes?limit=1000")
  echo "$room $(echo "$body" | jq '.writes|length') rows, last seq $(echo "$body" | jq '.writes[-1].seq'), sha256 $(echo "$body" | jq -S -c '.writes' | sha256sum | cut -c1-16)"
done; }
PORT=14000 fp
```

```text
alpha 45 rows, last seq 45, sha256 1747893d468f934e
beta 40 rows, last seq 40, sha256 8cf54163272ea7e9
gamma 40 rows, last seq 40, sha256 e0462940bf8b5ee4
```

The bucket held 475 objects and 2.4 MiB (`mc du s/atanor`; with the function above,
`s3 s3 ls --recursive --summarize s3://atanor | tail -2`).

### (a) Lose the node

The machine is gone, the bucket is not. Start a new node with an empty `data_dir` and the same bucket. The
workers come from the bucket: nothing is deployed again.

```sh
docker kill node-a                      # the node dies without handing its cells back
docker run -d --name node-b ... -v /tmp/atanor-runbook-data-b:/var/lib/atanor/cells ...   # as node-a, another name
for i in $(seq 1 14); do
  curl -s -i -H "host: scoreboard.localhost" "http://127.0.0.1:14010/rooms/alpha/writes?limit=1" | sed -n '1p;$p'; sleep 3
done
```

```text
03:16:55  docker kill
03:17:01  node-b ready
03:17:01 HTTP/1.1 503 Service Unavailable {"error":"unavailable","reason":"held_elsewhere"}   (retry-after: 1)
...      (6 answers, every 3 s)
03:17:19 HTTP/1.1 200 OK {"room":"alpha","writes":[{"seq":1,"id":"a1","player":"ann","points":1}]}
```

(Observed.) The new node answered 200 24 s after the kill. Until then the old node's lease on each cell is
still valid, and the answer is 503 `held_elsewhere` with `Retry-After`; a client that retries is served. The wait
is at most the lease time (`ATANOR_LEASE_TTL_MS`, 30 s) plus a 2 s margin
([how-to-replace-a-node.md](how-to-replace-a-node.md#troubleshooting)).

```sh
PORT=14010 fp > after-a.txt; diff before.txt after-a.txt && echo IDENTICAL
```

```text
IDENTICAL
```

(Observed: the three rooms have the same rows and hashes as before the kill.)

### (b) Lose the data directory

The disk of the node is gone, the node is back (the same name, the same node id). Start it with an empty
`data_dir`.

```sh
docker kill node-b && docker rm node-b
docker run --rm --name wipe -v /tmp/atanor-runbook-data-b:/d alpine:3.22 sh -c 'rm -rf /d/* /d/.[!.]*'
docker run -d --name node-b ... -v /tmp/atanor-runbook-data-b:/var/lib/atanor/cells ...   # the same command as before
```

```text
03:18:01  docker kill
03:18:09  node-b ready
03:18:09 503 (7 answers, every 3 s)
03:18:30 200
```

(Observed.) The first 200 came 29 s after the kill: the new process has the same node id as the dead one, and
the lease of the dead process is still valid for the same time, so it waits like any other node. The fingerprint
after was `IDENTICAL` again. A data directory is owned by the user of the container (uid 10001), so removing it
from the host needs `sudo` or a container, as above.

### (c) Come back from the bucket only

The node, its disk and the store are gone. All that is left is a copy of the bucket. This was run twice: with the
node running (live copy) and after a drain (cold copy).

**Cold copy, the recommended one.** Observed. A writer sent 34 acknowledged writes to the room `delta` (50 rows),
then the node was drained and copied:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" $ADMIN/drain
until [ "$(docker inspect -f '{{.State.Status}}' node-d)" = exited ]; do sleep 1; done
docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' node-d
s3 s3 sync s3://atanor /b/bucket
```

```text
{"node":"atanor@atanor-runbook-node-d.local","state":"drained","errors":[],"hibernated":2,"duration_ms":319}
exited 0
│ Total    │ Transferred │ Duration │ Speed      │
│ 5.43 MiB │ 5.43 MiB    │ 00m01s   │ 3.49 MiB/s │
```

Then the node and the store were removed, a new store was started and its bucket created, the copy was mirrored
back, and a new node was started on a new, empty `data_dir` (here a host directory, which uid 10001 must be able to write; see
[how to copy](#back-up-and-restore) for a named volume instead):

```sh
docker rm -f node-d store                # the disaster
# start a new store as in the README, then create the bucket (HTTP 200)
s3 s3 sync /b/bucket s3://atanor
docker run -d --name node-e ... -v /tmp/atanor-runbook-data-e:/var/lib/atanor/cells ...
for room in alpha beta gamma delta; do curl -s -H "host: scoreboard.localhost" "http://127.0.0.1:14040/rooms/$room" | jq -c '{last_seq,ranked_through}'; done
curl -s -H "host: scoreboard.localhost" "http://127.0.0.1:14040/rooms/delta/writes?limit=1000" | jq '[.writes[].id|select(startswith("e-"))]|length'
```

```text
│ Total    │ Transferred │ Duration │ Speed      │
│ 5.43 MiB │ 5.43 MiB    │ 00m02s   │ 2.55 MiB/s │
atanor-runbook-node-e ready
{"last_seq":86,"ranked_through":86}
{"last_seq":40,"ranked_through":40}
{"last_seq":40,"ranked_through":40}
{"last_seq":85,"ranked_through":85}
35
```

All 34 acknowledged writes are in `delta` (35 rows; inference: the writer's last request was in flight when it was stopped
and was applied), `ranked_through` equals `last_seq` in every room (the jobs ran), and the node needed no
deployment: it read the worker from the restored bucket. Order of a real recovery: store, bucket, copy, one node,
check, the other nodes.

**Live copy.** Observed. A writer sent 5 writes a second to `alpha` while `mc mirror` ran (1 s), and the node
kept serving. The node and the store were then removed and the copy restored as above.

```text
alpha 84 rows, last seq 84, sha256 2cb5ddbda48c31fd      (live: 105 rows)
beta 40 rows, last seq 40, sha256 8cf54163272ea7e9
gamma 40 rows, last seq 40, sha256 e0462940bf8b5ee4
```

The data was a consistent copy of one moment: `alpha` had the 50 rows from before, and `live-1` to `live-34`,
with no gap. The 15 writes acknowledged before the copy began were all there. The 21 writes acknowledged
after the copy had read the cell (`live-35` to `live-55`) are not in it. The new node served
and took new writes (`last_seq` 85).

#### Restore from a copy of a live bucket

In that run the jobs of `alpha` did not run after the restore. A write enqueues a `rank` job; the job lists
showed:

```sh
curl -s -H "host: scoreboard.localhost" http://127.0.0.1:14020/rooms/alpha | jq -c '{last_seq,ranked_through}'
curl -s -H "authorization: Bearer $TOKEN" "$ADMIN/jobs/rooms/alpha?limit=500" | jq -c '[.jobs[]|.state]|group_by(.)|map({(.[0]):length})|add'
```

```text
{"last_seq":86,"ranked_through":83}
{"done":82,"pending":3,"running":1}
```

(Observed.) Three jobs stayed `pending` and one `running` for more than 3 minutes, past the 60 s that a claim
lasts, and a restart of the node did not change it. The cell's own table of wake-ups had a row for a wake
(`@jobs|1794809947744|6b0c7899|0`) whose index object was not in the bucket. The design says a node finds due
jobs through the index under `alarms/` ([design §15.12](design.md#1512-the-claims-of-a-node-that-hands-its-cells-back)),
and an enqueue left a wake that it believed had an entry alone. That was fixed: when the wake of a cell is overdue by
more than `alarms.timeout_ms`, the next enqueue or re-arm of that cell checks the index object and puts it back if
it is missing. What remains is a cell with pending jobs that gets no new enqueue: it stays stuck
([what-does-not-work.md](what-does-not-work.md)). Enqueue a job to the cell, or use the repair below.

Copying `alarms/` last (a second `mc mirror` after the first, with `--exclude 'atanor/alarms/*'`; in the lab bucket the objects sat under the prefix `atanor`) did not avoid
it: the room `delta`, copied that way with a writer running, came back with `{"last_seq":50,"ranked_through":44}`.
**Repair**, observed to work: put an empty-looking object at the key of the missing entry. Read the row from a
copy of the cell (`mix alambique.restore rooms.delta out.db`, then
`sqlite3 out.db 'select * from _atanor_alarms'`, or the file in `data_dir`), build the key
`alarms/<minute, 10 digits>/<at_ms, 15 digits>/<shard>/@jobs/<namespace>.<key>/<nonce>` (`minute` is `at_ms / 60000`,
`at_ms` is padded with zeros, `shard` is `:erlang.phash2("<namespace>.<key>", 64)`; the body is the time in
milliseconds) and write it. Entries in the older layout (`<minute>/<shard>/<at_ms>`) are still read for one release:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' --aws-sigv4 aws:amz:us-east-1:s3 --user "$ACCESS:$SECRET" -X PUT \
  --data "$(date +%s%3N)" "http://127.0.0.1:18433/atanor/atanor/alarms/0029913504/001794810284506/61/%40jobs/rooms.delta/3bd2283b"
sleep 8; curl -s -H "host: scoreboard.localhost" http://127.0.0.1:14030/rooms/delta | jq -c '{last_seq,ranked_through}'
```

```text
200
{"last_seq":50,"ranked_through":50}
```

(`%40` is `@`: S3 signs the encoded path.) Alarms set with `set_alarm` have the same index and were not tested;
**inference:** they are affected the same way. Prefer a copy taken after `POST /drain`.

### Keep the copy safe

Inference from Alambique's `docs/storage-compatibility.md`: turn on bucket
versioning and a lifecycle rule for noncurrent versions of at least `deletion_grace_ms` plus the time you want to
keep, and never a rule that expires current objects of `cells/` or `trash/`. The `audit/` prefix grows without
bound and has no retention ([design §10.2.1](design.md#1021-deploys-scoped-tokens-and-the-audit-log)); give it a lifecycle rule, and
expect it in the copy. Test a restore on a schedule: a backup that was never restored is a hope.

## Replace a node

[how-to-replace-a-node.md](how-to-replace-a-node.md) is the procedure: start the new node in another discovery
group, wait until it serves, then drain the old one. The short form, with the commands of this guide:

1. Start the new node with its own name and `ATANOR_GROUP=b`, the same bucket and cookie.
2. `curl -s -H "authorization: Bearer $TOKEN" $NEW_ADMIN/health/serving` until 200.
3. Drain the old one: `POST /drain` on its admin port, or `docker stop --timeout 90`. Check exit status 0.
4. Read `held_elsewhere` and `draining` as retryable: they did not run the request.

If the old node is already dead, skip 3: its cells are served by the new node once the leases end (about 24 to
32 s; observed in [(a)](#a-lose-the-node)).

## Upgrade to a new version

An upgrade is a replacement with a new image. Observed on a bucket written by an older image and read by the
build of this repository:

```sh
# node-f: the image atanor-cluster-node:local (release 3fcc461779ae, Alambique 0.6.1), with data
# node-g: this repository's image (Alambique v0.10.1 per alambique.ref), in group b, started next to it
docker run -d --name node-g ... -e ATANOR_GROUP=b ...
curl -s -H "authorization: Bearer $TOKEN" $NODE_G_ADMIN/health | jq -c '{node,nodes,workers}'
curl -s -i -H "host: scoreboard.localhost" "http://127.0.0.1:14060/rooms/alpha/writes?limit=1" | sed -n '1p;/retry-after/Ip;$p'
curl -s -X POST -H "authorization: Bearer $TOKEN" $NODE_F_ADMIN/drain
curl -s -o /dev/null -w '%{http_code}\n' -H "host: scoreboard.localhost" "http://127.0.0.1:14060/rooms/alpha/writes?limit=1"
```

```text
{"node":"atanor@atanor-runbook-node-g.local","nodes":["atanor@atanor-runbook-node-g.local"],"workers":1}
HTTP/1.1 503 Service Unavailable
retry-after: 1
{"error":"unavailable","reason":"held_elsewhere"}
{"node":"atanor@atanor-runbook-node-f.local","state":"drained","errors":[],"hibernated":2,"duration_ms":37}
200
```

The old node exited 0. The rooms `alpha` and `beta` had the same hashes before and after
(`d216c22bda7ecf62` and `6464d5d398440163`), the new node accepted a write, and its log had no warning but
`Alambique could not restrict /var/lib/atanor/cells: :eperm`, which came from a host directory that the container
user does not own (use a Docker volume, or give the directory to uid 10001).

Steps for a real upgrade:

1. **Read the changes.** [CHANGELOG.md](../CHANGELOG.md) for breaking changes and renamed variables (a renamed
   `ATANOR_*` variable fails the start, which is the safe way), and
   [how-to-update-alambique.md](how-to-update-alambique.md) if the Alambique version changed. From 0.4.1 to 0.5.0:
   WebSocket `permessage-deflate` is off by default (`ATANOR_WEBSOCKET_COMPRESS=true` brings it back,
   [trade-off](how-to-use-websockets.md#origins-and-compression)); the `reason` of admin errors is a fixed text per
   case, so parse the `error` code ([admin API](how-to-use-the-admin-api.md)); `atanor login` exits 2 when it cannot
   hide the token ([cli](cli.md#atanor-login---url-url)); the node warns at start when no `ATANOR_HOSTS`,
   `ATANOR_NAMESPACES` or `ATANOR_HTTP_ALLOW` is set, and when an admin or dashboard listener is not on loopback
   and `ATANOR_BEHIND_TLS_PROXY` is not set ([production](how-to-run-in-production.md#tls-at-the-proxy)).
2. **Back up.** A cold copy if you can, a live one with the repair above if you cannot.
3. **Rehearse migrations.** If the new package has migrations, run
   [how-to-run-a-migration-rehearsal.md](how-to-run-a-migration-rehearsal.md) on copies of real cells. A cell is
   migrated forward when it wakes, and code serves cells one version ahead, so old and new nodes can run together
   (Alambique's `docs/concepts.md`).
4. **Replace the nodes one at a time**, as above, and wait for `/health/serving` 200 on the new one before you
   drain the next. For a cluster of nodes in one group, roll them by stopping one and starting one; see
   [how-to-run-a-cluster.md](how-to-run-a-cluster.md).
5. **Check** `GET /deployments` on each node: the same `release.id` and `serving` equal to the `head` of each worker.
6. **Roll back by the same steps with the old image.** Not tested: a node that wrote cells with a newer Alambique
   may not be readable by an older one. Inference: keep the backup from step 2 until the new version has run for
   longer than your rollback window. Workers roll back on their own with `atanor rollback`
   ([how-to-deploy-a-worker.md](how-to-deploy-a-worker.md)).

Not tested: a rolling upgrade of a cluster of three or more nodes in one group, and an upgrade under load.
[how-to-replace-a-node.md](how-to-replace-a-node.md#steps) has the measured cost of a swap under load.

**From 0.8 to 0.9: upgrade through 0.9.** 0.9.0 orders the alarm index keys by time inside a minute
([design §7.4](design.md#74-alarms)). A 0.9 node reads and fires keys of both layouts; the release after it reads
only the new one. During a rolling upgrade a node still on 0.8 does not fire the alarms that 0.9 nodes set; the 0.9
nodes fire them. Do not skip 0.9 when you upgrade from 0.8.

## Common incidents

### The store breaker is open

**Symptom.** Cold cells answer 503 fast with `{"error":"unavailable","reason":"store_unavailable"}` and
`Retry-After`. The log has `atanor: store breaker open for 5000 ms (:failures): default`.

**Confirm.**

```sh
curl -s -H "authorization: Bearer $TOKEN" $ADMIN/health | jq -c .store
docker logs NODE 2>&1 | grep -E "breaker|store failure|store error"
```

```text
{"default":{"state":"open","failures":5,"since_ms":1794810691630}}
06:31:28.217 [warning] atanor: store failure: :head on default: reason=:timeout_recv counted=true
06:31:31.630 [warning] atanor: store breaker open for 5000 ms (:failures): default
06:31:37.505 [info] atanor: store breaker closed: default
```

(Observed, with the store container paused, `docker pause`.) With the breaker open, a request for a cold cell
took 0.09 s to answer 503 `store_unavailable`, `/health/ready` stayed 200, and the breaker closed by itself 5.9
s after it opened (the 5 s cool-down and one good probe). With the store paused and the breaker still closed, three requests for cold cells each
waited 5.0 s and got 503 `overloaded` with `reason` `queue_timeout`
(`http: [queue_wait_ms: 5_000]`). A read of an awake cell (`alpha`) also answered 503 during the outage; the body
was not captured. **Inference:** it was the lease check, which reads the store; the design expects awake cells to
keep answering ([design §10.2](design.md#102-admin-api)).

**Cause.** The store did not answer 5 requests in a row: a store down, a network cut, credentials rejected, a
full or throttled bucket. The reason of each failure is in the log (`:timeout_recv`, `:timeout_connect`,
`{:http, status}`, `:transport`, `:crashed`). The module is `Atanor.StoreLog` (the log) over Alambique's breaker
(`Atanor.Overview.store_breakers/1`). The breaker never takes a node out of rotation, on purpose
([design §10.2](design.md#102-admin-api)): every node opens it at once, as the store is shared.

**Action.** Fix the store, not the nodes: check the endpoint and credentials in the first `effective settings`
log line, the store's own health, and the network. Do not restart the nodes; they reconnect by themselves and
the breaker closes after one good probe. If the failures say `{:http, 403}`, the credentials or the bucket policy
changed. If a breaker opens once in a while under load with a healthy store, see the open entry in
[what-does-not-work.md](what-does-not-work.md).

### The disk is full

**Symptom.** 503 with `{"error":"overloaded","reason":"disk"}` and `Retry-After`, for every request, reads
included. A write that SQLite refuses for lack of space is also 503 `overloaded` (reason `disk_full`), never 500.

**Confirm.**

```sh
curl -s -H "authorization: Bearer $TOKEN" $ADMIN/runtime | jq -c '.admission|{disk_used_bytes,disk_budget_bytes,disk_refusing,refused}'
```

```text
{"disk_used_bytes":478236,"disk_budget_bytes":460800,"disk_refusing":true,"refused":{"memory":0,"disk":301,"in_flight":0,"nested_calls":0,"queue_timeout":0,"worker_queue":0}}
```

(Observed on a node with `ATANOR_DISK_LIMIT=450k`, an artificially small budget, after writes.) The node also
logs the budget at start: `atanor: data_dir limited to 460800 bytes (option), ...`.

**Cause.** `data_dir` holds the files of the awake cells and their write-ahead logs. At 70% of the budget the node
hibernates idle cells; at 95% it refuses every request until the use falls 5 points
([design §4.4](design.md#44-the-disk-budget), modules `Atanor.Disk` and `Atanor.Admission`). Cells that are awake and
busy are not hibernated, and a node whose awake cells' database files alone pass the budget stays closed.

**Action.** Raise the budget (`ATANOR_DISK_LIMIT`) or the disk, then restart the node, or lower
`awake: [max_cells:]` so that fewer cells are kept. Observed: after the node was stopped and started again with
`ATANOR_DISK_LIMIT=10m` over the same data directory, `disk_refusing` was `false` and the write returned 201. The
refusing node did not recover by itself in the 20 s that were observed, because its use stayed above the mark.
Moving traffic to another node does not fix it: the cells follow their data.

### Requests get 503 overloaded

**Symptom.** `{"error":"overloaded","reason":"<reason>"}` with `Retry-After`, and `[:atanor, :http, :reject]`
events with the same reason.

**Confirm.** The `reason` of the body says which gate; `/runtime` `.admission` has the counters.

```sh
curl -s -i -H "host: scoreboard.localhost" "http://127.0.0.1:14080/rooms/disk/writes?limit=1" | sed -n '1p;/retry-after/Ip;$p'
curl -s -H "authorization: Bearer $TOKEN" $ADMIN/runtime | jq -c '.admission|{working_set_bytes,limit_bytes,refuse_at_bytes,refusing,refused}'
```

```text
HTTP/1.1 503 Service Unavailable
retry-after: 1
{"error":"overloaded","reason":"memory"}
{"working_set_bytes":185085952,"limit_bytes":104857600,"refuse_at_bytes":89128960,"refusing":true,"refused":{"memory":1,"disk":0,"in_flight":0,"nested_calls":0,"queue_timeout":0,"worker_queue":0}}
```

(Observed on a node started with `ATANOR_MEMORY_LIMIT=100m`, below its working set.)

| `reason` | Cause | Module | Action |
| --- | --- | --- | --- |
| `memory` | Working set at 85% of the limit | `Atanor.Admission` | Raise the limit, or lower the awake cells (`memory: [awake_fraction:]`); find what grows with `/runtime` `.top_memory` and `.ets`. A wake of a cold cell is refused too. |
| `disk` | `data_dir` at 95% of the budget | `Atanor.Admission`, `Atanor.Disk` | [The disk is full](#the-disk-is-full). |
| `in_flight` | 1,024 requests being served | `Atanor.Admission` | Add nodes, or find what makes requests slow (the store, a worker). |
| `queue_timeout` | An admitted request waited 5 s for a wake, a cell or a WASM slot | `Atanor.Admission`, `Atanor.Cell` | Usually the store is slow: [the store breaker](#the-store-breaker-is-open) or [slow wake](#cells-wake-slowly). The request did not run; the client retries. |
| `wake_gate` | The memory gate is closed and the cell is not awake anywhere | `Atanor.Cell` | As `memory`. |
| `awake_limit`, `busy`, `disk_full` | Alambique's own limits: awake cells full, or the wake slots and queue full (many cells waking at once, on a request's lookup or call); a cell's waiting callers or the statement slots full; SQLite out of space | `Atanor.Unavailable` | Raise `awake: [max_cells:]`, `sql: [max_concurrent_statements:]`, or the disk. `/runtime` `.admission.awake_limit_by` says why Alambique refused a wake: `no_wait`, `queue_full`, `wait_expired` (raise `awake: [wake_queue_ms:]` or `max_wakes`), `crowded` or `max_children`. |
| `worker_queue`, `nested_calls` | The WASM queue is full; calls between workers above `max_nested_calls` | `Atanor.Wasm` | Raise `worker_queue` or `queue` of the WASM settings, or fix the worker that calls itself in a loop. |

Only `memory`, `disk` and `queue_timeout` were reproduced; the others are read from
[telemetry.md](telemetry.md) and the code. **Action common to all:** shed or slow the load, keep the clients
retrying with the `Retry-After`, and do not restart the node: a restart sends every cell back to the store at once.

### Cells wake slowly

**Symptom.** The first request for a cell takes seconds; later ones are fast. After a node swap or a takeover,
some cells answer 503 `queue_timeout` or time out at the client.

**Confirm.** The node logs every wake of 1 s or more, with the store requests it made and the time they took
(module `Atanor.WakeLog`):

```sh
docker logs NODE 2>&1 | grep "slow wake"
```

```text
atanor: slow wake of "<cell>": <ms> ms, <requests> store requests in <ms> ms, result <result>
```

The line above is the format from the code, not output; **no slow wake could be provoked** in
these runs (pausing the store while a cell woke gave a wake of 0.2 to 2.8 s with no `slow wake` line, so the stall
was before the wake proper). The event `[:alambique, :cell, :wake]` carries the same numbers (`duration`,
`trips`, `store_time`). A wake that waits for a slot is in `[:alambique, :admission, :wake_queue]`.
[how-to-replace-a-node.md](how-to-replace-a-node.md) measured 25 to 32 s for cells with 449 to 822 segments over a
store 25 ms away, and 1.4 s after Alambique 0.7 to 0.9 fixed it.

**Cause.** A wake reads the cell from the store: its newest snapshot and the segments after it, one object each.
A long chain, a slow or distant store, or too many wakes at once make it slow. Many wakes together follow a node
that died or was drained.

**Action.** Check the store's latency first. Then: let the node finish (the wake goes on after a 503
`queue_timeout`, so the retry finds it ready); give a draining node time to compact the chain it hands off (do
not `docker kill` it); and keep the wake limits derived from memory
([configuration.md](configuration.md#cells-limits-memory-and-store-requests)). If one cell is always slow,
`mix alambique.inspect CELL` shows its chain (Alambique's `docs/how-to-operate-a-cell.md`).

## How this was checked

On 2026-11-16, on one laptop, with containers named `atanor-runbook-*` and a data directory, backup and keys
under `/tmp/atanor-runbook-*`, all disposable: a SeaweedFS 4.48 as the store, one node at a time, the
scoreboard WASM worker, and the image built from this repository at commit `9fc0b66` (`docker build --target
runtime`). Node names and ports in the outputs are those of the runs. Times are wall-clock of the laptop, which
was busy (load average above 20).

Tested: loss of the node, of the data directory and of the whole store with a cold and a live copy; the repair of
the missing index entry; an upgrade from an older image to this one; the open breaker, the memory gate and the
disk gate; a store that stops answering for a cold cell. Not tested: more than one node in one group, an upgrade
under load, a rollback to an older image, a real S3, bucket versioning and lifecycle rules, `set_alarm` after a
live restore, a slow wake, the `in_flight`, `awake_limit`, `busy`, `worker_queue` and `nested_calls` refusals, and
any metrics collector or alert rule (the thresholds are suggestions).

## Next steps

- [how-to-run-in-production.md](how-to-run-in-production.md): the arrangement this runbook assumes.
- [how-to-replace-a-node.md](how-to-replace-a-node.md): the swap, with measurements under load.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md): every endpoint used above.
- [how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md): when a node dies.
- [configuration.md](configuration.md): the limits behind each gate.
- [design.md](design.md): the store layout (§5), the disk budget (§4.4), the admin API (§10.2) and the drain (§8.11).
