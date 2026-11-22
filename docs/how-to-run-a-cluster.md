# How to run a cluster and watch requests follow their cells

**The question:** How do I run Atanor on several nodes over one bucket, see
each request run on the node that owns its cell, and see what happens when a
node dies?

This guide builds on [how-to-run-a-node-locally.md](how-to-run-a-node-locally.md):
it uses the same image, secrets and store, and runs three nodes on one machine.
Read that guide first.

## Prerequisites

- Docker, and steps 1 to 3 of [how-to-run-a-node-locally.md](how-to-run-a-node-locally.md):
  `IMAGE` is set, `atanor-secrets` holds the secrets, `atanor-net` is the network
  and SeaweedFS runs as `atanor-store` with the bucket `atanor`. Do not start the
  single node of its step 4: this guide starts three nodes.
- A WASM worker with a cell, in `atanor-hello`: a manifest and a component, as in
  [how-to-write-a-wasm-worker.md](how-to-write-a-wasm-worker.md). The steps below
  assume that `GET /hello/<name>` on the host `localhost` answers
  `{"hello":"<name>","greetings":<n>}`, where `n` counts the requests of that name
  in the cell `hits.<name>`. The worker's cell calls run on the cell's owner.
- In every command, `TOKEN` is the admin token of the nodes:

  ```sh
  TOKEN=$(cat atanor-secrets/admin_token)
  ```

## Concepts in three lines

Every node runs the same instance over the same bucket. A cell has one owner
at a time (a lease in the bucket). A node that receives a request runs it, and
each call to a cell runs on the cell's owner, on whichever node that is.

## Steps

1. Start three nodes. Each has its own ingress port (`400N` on the host), its
   own admin port (`500N`) and a name that the others resolve: the network alias
   `node-N.cluster` is the node's name, `atanor@node-N.cluster`
   (`ATANOR_ADVERTISE`). There is no list of nodes: each node publishes its name
   in the bucket and connects to the names it reads there
   ([discovery](configuration.md#discovery)).

   ```sh
   for n in 1 2 3; do
     docker run -d --name atanor-node-$n --network atanor-net --network-alias node-$n.cluster \
       --stop-timeout 90 -p 127.0.0.1:400$n:4000 -p 127.0.0.1:500$n:4001 \
       -v "$PWD/atanor-secrets:/run/secrets:ro" \
       -e ATANOR_STORE=s3://atanor -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
       -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
       -e ATANOR_ADMIN_TOKEN_FILE=/run/secrets/admin_token -e ATANOR_COOKIE_FILE=/run/secrets/cookie \
       -e ATANOR_ADVERTISE=node-$n.cluster "$IMAGE"
   done
   until [ "$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $TOKEN" \
     http://127.0.0.1:5001/health/ready)" = 200 ]; do sleep 1; done
   ```

   Expected: `docker ps` lists `atanor-node-1` to `atanor-node-3` as running, and
   the loop ends when node 1 is ready.

2. Deploy the worker through node 1, as in step 5 of
   [how-to-run-a-node-locally.md](how-to-run-a-node-locally.md). The command writes
   the package to the bucket, and every node applies it at its next poll (at most
   5 seconds).

   ```sh
   docker run --rm --network atanor-net -v "$PWD/atanor-secrets:/run/secrets:ro" -v "$PWD/atanor-hello:/w:ro" \
     -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     "$IMAGE" deploy /w --bucket s3://atanor --activate
   ```

   Expected: the package is stored and active, as in step 5 of the local guide.

3. Check that the nodes see each other. Run it again if a node has just started:
   a node is found within a few seconds.

   ```sh
   curl -s -H "authorization: Bearer $TOKEN" 127.0.0.1:5001/health
   ```

   ```json
   {"node":"atanor@node-1.cluster","status":"ok","nodes":["atanor@node-1.cluster","atanor@node-2.cluster","atanor@node-3.cluster"],"workers":1}
   ```

4. Send requests for the same name through each node, and for two other names.
   Whatever the node that receives a request, the counter of a name goes on.

   ```sh
   for p in 4001 4002 4003; do curl -s -H "host: localhost" 127.0.0.1:$p/hello/alice; echo; done
   curl -s -H "host: localhost" 127.0.0.1:4002/hello/bob; echo
   curl -s -H "host: localhost" 127.0.0.1:4003/hello/carol; echo
   ```

   ```text
   {"hello":"alice","greetings":1}
   {"hello":"alice","greetings":2}
   {"hello":"alice","greetings":3}
   {"hello":"bob","greetings":1}
   {"hello":"carol","greetings":1}
   ```

5. See where the cells are. Each live cell is on one node, and the cell calls of
   the requests above ran on that node.

   ```sh
   curl -s -H "authorization: Bearer $TOKEN" 127.0.0.1:5001/cells
   curl -s -H "authorization: Bearer $TOKEN" "127.0.0.1:5001/cells?node=atanor@node-3.cluster"
   ```

   ```text
   {"total":3,"nodes":{"atanor@node-1.cluster":{"count":1,"status":"ok"},"atanor@node-2.cluster":{"count":0,"status":"ok"},"atanor@node-3.cluster":{"count":2,"status":"ok"}},"partial":false}
   {"node":"atanor@node-3.cluster","next":null,"cells":[{"id":"hits.alice","key":"alice","namespace":"hits"},{"id":"hits.bob","key":"bob","namespace":"hits"}]}
   ```

   The cells were woken on the nodes Alambique prefers (rendezvous hashing
   over the names), not on the node that got the request: node 2 got requests and
   owns none.

6. Kill the node that owns `alice` (node 3 above). A `SIGKILL` stops it without a
   shutdown. Then ask through node 1 until the cell answers again.

   ```sh
   docker kill -s KILL atanor-node-3
   while true; do
     out=$(curl -s -m 5 -w ' [%{http_code}]' -H "host: localhost" 127.0.0.1:4001/hello/alice)
     echo "$out"; case "$out" in *'[200]') break;; esac; sleep 0.2
   done
   ```

   ```text
   {"hello":"alice","greetings":4} [200]
   ```

   The surviving nodes saw the process die at once (the operating system
   closed its connections), the detector confirmed it down, and the request for
   `alice` took the cell over: Alambique raised the epoch of its lease and woke
   the cell on node 1, without waiting for the dead node's lease (30 s by default).
   The counter goes on from 3 to 4: nothing that was acknowledged was lost. Only
   the cells that are asked for move; `/health` now lists two nodes and `/cells`
   shows where the cells are. (A client that sends the request while the node is
   already gone but not yet confirmed down gets a 503 `unavailable` or waits for
   the verdict: step 8.)

7. See how the nodes watch each other, and what a lost machine looks like.
   Nodes send each other heartbeats, and `/nodes` shows how this node sees each
   peer. Start node 3 again (it joins by itself), then:

   ```sh
   docker start atanor-node-3
   curl -s -H "authorization: Bearer $TOKEN" 127.0.0.1:5001/nodes
   ```

   ```json
   {"node":"atanor@node-1.cluster","nodes":[{"node":"atanor@node-2.cluster","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":41},{"node":"atanor@node-3.cluster","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":146}]}
   ```

   Ask for a few more names through node 2 until node 3 owns one (`/cells?node=atanor@node-3.cluster`
   lists them). Then freeze node 3 without closing its connections, as a lost
   machine would, ask node 1 for `mona` in the background and look at `/nodes`
   after 3 and after 7 seconds:

   ```sh
   docker pause atanor-node-3
   curl -s -m 20 -w ' [%{http_code}] after %{time_total}s\n' -H "host: localhost" 127.0.0.1:4001/hello/mona &
   ```

   ```json
   {"node":"atanor@node-1.cluster","nodes":[{"node":"atanor@node-2.cluster","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":212},{"node":"atanor@node-3.cluster","reason":null,"state":"alive","phi":1.37,"last_heartbeat_ms":3320}]}
   {"node":"atanor@node-1.cluster","nodes":[{"node":"atanor@node-2.cluster","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":215},{"node":"atanor@node-3.cluster","reason":"{:phi, 10.9}","state":"down","phi":300.0,"last_heartbeat_ms":7328}]}
   {"hello":"mona","greetings":2} [200] after 4.943359s
   ```

   `phi` grows with the silence of a peer. When it passes the threshold (8 by
   default) node 1 asks node 2 to reach node 3 too, and when nobody can it marks node 3
   `down` and disconnects it. The request that was waiting for node 3 fails at that
   moment, and node 1 takes `mona` over: the answer does not wait for the 60 s
   `net_ticktime` or the 30 s lease. A request for another cell of node 3 after
   that is answered at once. The time to the verdict is the detection time; to
   shorten it see "Tune the failure detector" below.

   `docker unpause atanor-node-3` thaws it; its heartbeats come back and node 3 is `alive`
   again in the same listing, with none of its taken cells (the old owner is
   fenced). The states are `alive`, `suspect`, `link_broken` (this node cannot
   reach the peer but another can; its cells are not taken) and `down`.

8. Tell Atanor that a node is gone, as the infrastructure would (a hook that runs
   after a machine is destroyed, a cloud event, an orchestrator). The admin token is
   required. Freeze node 3 again and post the hint to any node:

   ```sh
   docker pause atanor-node-3
   curl -s -X POST -H "authorization: Bearer $TOKEN" 127.0.0.1:5001/nodes/atanor@node-3.cluster/gone
   curl -s -H "authorization: Bearer $TOKEN" 127.0.0.1:5002/nodes
   curl -s -m 5 -w ' [%{http_code}] after %{time_total}s\n' -H "host: localhost" 127.0.0.1:4002/hello/oscar
   ```

   ```text
   {"node":"atanor@node-3.cluster","state":"down"}
   {"node":"atanor@node-2.cluster","nodes":[{"node":"atanor@node-1.cluster","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":298},{"node":"atanor@node-3.cluster","reason":":platform_hint","state":"down","phi":-0.0,"last_heartbeat_ms":105}]}
   {"hello":"oscar","greetings":2} [200] after 0.018528s
   ```

   Both nodes mark node 3 down at once, without waiting for phi, and the first
   request for a cell of node 3 (`oscar`) takes it over. A node that is not
   known is 404 `unknown_node` and a call without the token is 401. Thaw node 3
   with `docker unpause atanor-node-3`; for a few seconds it still counts its peers as lost
   and may answer 400 or 503.

9. Clean up: stop the nodes that still run (`docker stop` sends `SIGTERM`, and
   a node drains before it exits), remove them, then remove the store and the
   secrets as step 7 of [how-to-run-a-node-locally.md](how-to-run-a-node-locally.md)
   does.

   ```sh
   docker stop atanor-node-1 atanor-node-2 atanor-node-3
   docker rm atanor-node-1 atanor-node-2 atanor-node-3
   ```

## What happens when a node joins

A cell that is awake stays on its node: a new node would get only new and idle
cells. So after a node joins, every node moves the cells it serves whose preferred
node (the node that would wake them now) is another one. This is on by default and
needs nothing from you.

- **When.** Each node waits `start_delay_ms` (30 s) after the last change of the
  members. A node that joins and leaves inside that time moves nothing.
- **Which and how fast.** Cells awake here that the new node prefers, coldest first,
  one at a time, at most `max_moves_per_s` (5) a second per node. A move pauses
  that cell for the time of a hibernate and a wake; its callers wait and then go to
  the new node. About a third of the cells go to a third node. At the default rate a
  node moves 5 cells a second, so moving N cells takes about N / 5 seconds after the delay.
- **What stays.** A cell with a call in flight when its turn comes is tried again a
  few times and, if still busy, left for another round. A cell that moved is not moved back
  while the members stay the same, and a hot cell that the
  [hot-cell loop](how-to-place-hot-cells.md) placed is left where it is.
- **Watch it.** `GET /runtime` on the admin API has a `rebalance` section: the phase
  (`waiting`, `running`, `done`), the cells still to move and the ones moved and failed.
  The events are in [telemetry.md](telemetry.md#rebalance-on-join).

  ```sh
  curl -s -H "authorization: Bearer $TOKEN" 127.0.0.1:5001/runtime | jq .rebalance
  ```

Tune it in the instance options, or by environment for the daemon:

```elixir
{Atanor, name: MyApp.Atanor, store: store, rebalance: [max_moves_per_s: 2, start_delay_ms: 60_000]}
```

| Option | Variable | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | `ATANOR_REBALANCE` | `true` | `false` keeps awake cells where they are, as before. |
| `max_moves_per_s` | `ATANOR_REBALANCE_MAX_MOVES_PER_S` | 5 | From 1 to 20, per node. Lower it if moves slow your callers. |
| `start_delay_ms` | `ATANOR_REBALANCE_START_DELAY_MS` | 30000 | How long the members must stay unchanged. Raise it for rolling restarts. |

The design is in [design §8.1](design.md#81-finding-the-owner). If a rolling
restart moves cells you would rather leave, raise `start_delay_ms` above the time
between two restarts, or turn it off and let cells go where they wake.

## Keep the cookie and the distribution ports private

The Erlang cookie is a root password for every node: whoever has it and can
reach a node's distribution port can run any code there and read every
tenant's cells and secrets. Distribution is plain TCP, so forwarded requests
(headers and bodies included) cross it unencrypted. For a real cluster:

1. Give the cookie its own random value, not used for anything else (not the
   admin or dashboard token), and give it to the node as a file:
   `ATANOR_COOKIE_FILE`, or `RELEASE_COOKIE` in the environment. The secrets of
   [how-to-run-a-node-locally.md](how-to-run-a-node-locally.md) do this. Never
   put the cookie in a command-line argument: every user of the host sees arguments
   in the process list.
2. Open `epmd` (4369) and the distribution ports (9100 to 9110) only between the
   nodes. Whoever can write `<prefix>/nodes/` in the bucket decides whom the nodes
   dial: the cookie still gates the handshake, but give the bucket's write keys only
   to the nodes.
3. If the network between the nodes is not private, use TLS distribution: start
   the nodes with `-proto_dist inet_tls -ssl_dist_optfile /etc/atanor/dist.conf`
   and put the certificates in that file, as the Erlang/OTP guide "Using TLS for
   Erlang Distribution" describes. Check it with `:net_kernel.get_net_ticktime()`
   on a node and `/health` listing the other nodes.

The steps above use the random cookie of the local guide, on a private Docker
network with no published distribution ports. [how-to-run-in-production.md](how-to-run-in-production.md)
covers the rest of the arrangement.

## Tune the failure detector

The defaults detect a silent node in about 5 seconds. Give `detector:` to
`Atanor` to change them; every value is optional:

```elixir
{Atanor, name: MyApp.Atanor, store: store, data_dir: dir,
 detector: [interval_ms: 500, phi_threshold: 8, acceptable_pause_ms: 1_000,
            indirect: [k: 3, timeout_ms: 500]]}
```

Lower `acceptable_pause_ms` and `interval_ms` to detect sooner; raise
`acceptable_pause_ms` or `phi_threshold` if `[:atanor, :node, :suspect]` events
are followed by `:alive` (late heartbeats under load or on a slow network). All
options and the arithmetic are in [design.md §8.7](design.md#87-the-phi-accrual-detector).
The detection time is also the time a lost node's cells need to serve again:
the first request for each takes it over (design
[§8.10](design.md#810-acting-on-a-confirmed-failure)). The other settings are
`takeover:` (`enabled`, `quorum`, `attempts`), `routing:` and `stop:`
([Atanor](../lib/atanor.ex) lists them). `takeover: [quorum: true]`, the default,
means a node takes cells over only when it and the peers it still reaches are a
majority of the nodes it knows, so a node cut off from the others takes nothing
([design §8.10](design.md#810-acting-on-a-confirmed-failure)). With two nodes,
a silent failure waits for the lease.

## Stop a node without errors

A node stopped with SIGTERM (`docker stop`, or the stop of your service manager)
closes its listeners, tells its peers that it leaves, and hands its cells off
before it exits (design [§8.11](design.md#811-draining-and-stopping-gracefully)). Its cells
serve again on the other nodes at once, and `GET` requests through the
other nodes see no error. A `POST` that was running on the stopping node can
still get 503 `unknown_outcome`. Put a load balancer's drain before the stop so
that clients stop sending to the node first; `stop: [connections_ms: ...]` is how
long open connections get to finish.

## What a client sees when a node fails

| Answer | Meaning | What to do |
| --- | --- | --- |
| 503 `{"error":"unavailable","reason":"no_quorum"}` | The call did not run: this node is not a majority of the nodes it knows, so it took nothing over. | Repeat it through a node in the majority, or after the partition heals. |
| 503 `{"error":"unavailable","reason":"owner_unreachable"}` | The call did not run: the owner is not reachable and is not confirmed down yet. | Repeat it; the cell is taken over when the detector confirms the loss. |
| 503 `{"error":"unavailable","reason":"owner_down"}` | The call did not run: the owner is confirmed down but the cell has not been taken over (takeover off, or its lease has not expired). | Repeat it until the lease is taken over. |
| 503 `{"error":"unavailable","reason":"draining"}` | The call did not run: this node hands its cells off and does not wake the cell. | Repeat it; another node serves the cell (see [the admin API](how-to-use-the-admin-api.md), step 13). |
| 503 `{"error":"unavailable","reason":"held_elsewhere"}` | The call did not run: a node outside this cluster (one being replaced) holds the cell's lease. | Retry after the `Retry-After` time; the lease is released when that node drains (or expires, after a crash). |
| 503 `{"error":"unavailable","reason":"fenced"}` | The call did not run: this node lost the cell's lease (a takeover or a move fenced it). | Repeat it; the owner lookup finds the new owner. |
| 503 `{"error":"overloaded","reason":"worker_queue"}` | The call did not run: the WASM queue was full (`refused.worker_queue` of the admin runtime page). `nested_calls` is a call between workers above `max_nested_calls`. Other `reason` values name other gates (`memory`, `disk`, `in_flight`, `wake_gate`, `awake_limit`, `busy`, `disk_full`; design §7.1). | Retry after the `Retry-After` time, or raise the limit that `reason` names. |
| 503 `{"error":"overloaded","reason":"queue_timeout"}` | The request waited past `http.queue_wait_ms` (5 s) for a thread, the cell owner, a wake or a read, and was refused; the call did not run. | Back off for `Retry-After` and retry. The node is saturated or its store is slow: see the CPU, `refused.queue_timeout` of the admin runtime page, and the store latency. |
| 503 `{"error":"unknown_outcome","reason":"unknown_outcome"}` | The call started on a node that was lost. A `GET` is repeated by Atanor itself; a `POST` is not. | Read the state before repeating a write. |
| 500 `{"error":"foreign_store","reason":"foreign_store"}` | The call did not run: it was routed toward a node that runs this instance over another store or prefix. A repeat fails the same way, and there is no `Retry-After`. | Give every node the same `store:` (or `placement:`) and `prefix:`; see Troubleshooting. |
| 500 `{"error":"internal_error"}` | A defect: the worker raised, returned an invalid response, or an unexpected error happened. | Report it; it is not expected unavailability. |

Every 503 carries `Retry-After` in seconds (`http: [retry_after_s: 1]` by
default, also for `held_elsewhere`) and a `reason` field. A worker that catches a cell error and answers 5xx
still gets the 503: the runtime keeps the availability reason of the cell call.

[design.md §8.4](design.md#84-when-the-node-is-lost) has the full table.

## Troubleshooting

- **`/health` lists only one node.** The nodes are not connected. Check that
  every node has the same cookie file, the same bucket and the same `ATANOR_STORE`
  prefix, and that the objects under `<prefix>/nodes/` exist. Check that each
  advertised name (`ATANOR_ADVERTISE`) resolves from the other nodes: the network
  alias of step 1 does that on the Docker network. Look for
  `atanor discovery: cannot connect` in `docker logs atanor-node-2`.
- **`could not connect to ...`.** The other node is not up yet or uses another
  cookie. Start the nodes one after the other.
- **Every request is a 404.** `host: localhost` is missing: the route of the
  worker matches the host `localhost`.
- **500 `foreign_store`, and an error in the log naming a node.** A node of
  this cluster was routed toward a node that runs an instance of the same name
  over another store or prefix, so the call was refused (not retried, no
  `Retry-After`). Nodes of two stores are connected, or a restart changed the
  store's location (endpoint, bucket) or the prefix and the nodes are split
  between the old and the new value. Start every node of the instance with the
  same `ATANOR_STORE` (the bucket and the prefix) or the same `store:` and `prefix:`
  options, or disconnect the nodes of the other store. The event `[:atanor, :foreign_store]`
  counts the refusals.
- **A node answers `401` on the admin port.** Send
  `authorization: Bearer <the admin token>`.

## Next steps

- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) for the endpoints
  used above.
- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) to switch every node
  to a new version; a request that crosses nodes keeps the version it started
  on.
- [how-to-place-hot-cells.md](how-to-place-hot-cells.md) to let a very busy cell move to a less loaded or a dedicated node.
- [how-to-run-in-production.md](how-to-run-in-production.md) to put the nodes behind a
  load balancer, with TLS and a private network between them.
- [design.md §8](design.md#8-cluster) for how routing, retries and failures
  work, including its limits.
