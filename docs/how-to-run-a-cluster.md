# How to run a cluster and watch requests follow their cells

**The question:** How do I run Atanor on several nodes over one bucket, see
each request run on the node that owns its cell, and see what happens when a
node dies?

This guide builds on [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md):
it runs the same project, [examples/hello-native](../examples/hello-native), on
three nodes on one machine. Read that guide first if you have no worker yet.

## Prerequisites

- The tools of the [README](../README.md#requirements), and Docker for the
  local SeaweedFS, which the nodes share as their bucket.
- A native worker project that compiles, with a `route_key/2` that names a
  cell (the example has one). Without it the request runs on the node that
  received it; its cell calls still reach the owner.
- Three terminals in `examples/hello-native`. In the commands, `HOST` is the
  short host name of your machine (`hostname -s`).

## Concepts in three lines

Every node runs the same instance over the same bucket. A cell has one owner
at a time (a lease in the bucket). A node that receives a request for a cell
runs the worker's callback on the owner and sends back the answer.

## Steps

1. Start the shared bucket.

   ```sh
   mise run seaweedfs:up
   ```

   ```text
   SeaweedFS ready on 127.0.0.1:18343
   ```

2. Start the first node. `--sname` and `--cookie` make it a distributed
   Erlang node; the other nodes must use the same cookie. `atanor-demo` is a public
   value for this local demo. For a real cluster use a secret cookie, set in the
   environment of the process (`RELEASE_COOKIE` for a release) and not in the
   arguments, which show in the process list. Alambique's Mix tasks read
   `ALAMBIQUE_COOKIE` when `--cookie` is absent. Each node needs its
   own `--port`, `--admin-port` and `--data-dir`.

   ```sh
   mise exec -- elixir --sname a --cookie atanor-demo -S mix atanor.dev \
     --store seaweedfs --port 4001 --admin-port 5001 --admin-token demo-token \
     --data-dir /tmp/atanor-demo/a
   ```

   ```text
   Atanor listening on http://127.0.0.1:4001
     localhost/hello -> hello
   ```

3. In the second and third terminals start `b` and `c` the same way, with their
   own ports, and `--connect` to the nodes that are already up. Atanor does not
   find other nodes: connecting them is the operator's job (`--connect` calls
   `Node.connect/1`; in production use a cluster library or your orchestrator).

   ```sh
   mise exec -- elixir --sname b --cookie atanor-demo -S mix atanor.dev \
     --store seaweedfs --port 4002 --admin-port 5002 --admin-token demo-token \
     --data-dir /tmp/atanor-demo/b --connect a@HOST
   mise exec -- elixir --sname c --cookie atanor-demo -S mix atanor.dev \
     --store seaweedfs --port 4003 --admin-port 5003 --admin-token demo-token \
     --data-dir /tmp/atanor-demo/c --connect a@HOST --connect b@HOST
   ```

4. Check that the nodes see each other.

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5001/health
   ```

   ```json
   {"node":"a@myhost","status":"ok","nodes":["a@myhost","b@myhost","c@myhost"],"workers":1}
   ```

5. Send requests for the same name through each node, and for two other names.
   Whatever the node that receives it, the counter of a name goes on.

   ```sh
   for p in 4001 4002 4003; do curl -s -H "host: localhost" localhost:$p/hello/alice; echo; done
   curl -s -H "host: localhost" localhost:4002/hello/bob; echo
   curl -s -H "host: localhost" localhost:4003/hello/carol; echo
   ```

   ```text
   {"hello":"alice","greetings":1}
   {"hello":"alice","greetings":2}
   {"hello":"alice","greetings":3}
   {"hello":"bob","greetings":1}
   {"hello":"carol","greetings":1}
   ```

6. See where the cells are. Each live cell is on one node, and the worker ran
   on that node for every one of the requests above.

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5001/cells
   curl -s -H "authorization: Bearer demo-token" "localhost:5001/cells?node=c@HOST"
   ```

   ```text
   {"total":3,"nodes":{"a@myhost":{"count":1,"status":"ok"},"b@myhost":{"count":0,"status":"ok"},"c@myhost":{"count":2,"status":"ok"}},"partial":false}
   {"node":"c@myhost","next":null,"cells":[{"id":"hits.alice","key":"alice","namespace":"hits"},{"id":"hits.bob","key":"bob","namespace":"hits"}]}
   ```

   The cells were woken on the nodes Alambique prefers (rendezvous hashing
   over the names), not on the node that got the request: `b` got requests and
   owns none.

7. Crash the node that owns `alice` (`c` above). Find the VM and kill it
   without a shutdown, then ask through `a` until the cell answers again.

   ```sh
   ps -eo pid,args | grep -- '-sname c' | grep -v grep   # the PID is the first column
   kill -KILL PID
   while true; do
     out=$(curl -s -m 5 -w ' [%{http_code}]' -H "host: localhost" localhost:4001/hello/alice)
     echo "$out"; case "$out" in *'[200]') break;; esac; sleep 0.2
   done
   ```

   ```text
   {"hello":"alice","greetings":4} [200]
   ```

   In the run recorded here the cell answered 35 ms after the kill, on the first
   try. The surviving nodes saw the process die at once (the operating system
   closed its connections), the detector confirmed it down, and the request for
   `alice` took the cell over: Alambique raised the epoch of its lease and woke
   the cell on `a`, without waiting for the dead node's lease (30 s by default).
   The counter goes on from 3 to 4: nothing that was acknowledged was lost. Only
   the cells that are asked for move; `/health` now lists two nodes and `/cells`
   shows where the cells are. (A client that sends the request while the node is
   already gone but not yet confirmed down gets a 503 `unavailable` or waits for
   the verdict: step 8.)

8. See how the nodes watch each other, and what a lost machine looks like.
   Nodes send each other heartbeats, and `/nodes` shows how this node sees each
   peer. Restart `c` if you killed it in step 7 (it joins again by itself), then:

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5001/nodes
   ```

   ```json
   {"node":"a@myhost","nodes":[{"node":"b@myhost","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":41},{"node":"c@myhost","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":146}]}
   ```

   Ask for a few more names through `b` until `c` owns one (`/cells?node=c@HOST`
   lists them; `mona` was one here). Then freeze the VM of `c` without closing
   its connections, as a lost machine would (`PID` is the `beam.smp` of `c`,
   found as in step 7), ask `a` for `mona` in the background and look at `/nodes`
   after 3 and after 7 seconds:

   ```sh
   kill -STOP PID
   curl -s -m 20 -w ' [%{http_code}] after %{time_total}s\n' -H "host: localhost" localhost:4001/hello/mona &
   ```

   ```json
   {"node":"a@myhost","nodes":[{"node":"b@myhost","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":212},{"node":"c@myhost","reason":null,"state":"alive","phi":1.37,"last_heartbeat_ms":3320}]}
   {"node":"a@myhost","nodes":[{"node":"b@myhost","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":215},{"node":"c@myhost","reason":"{:phi, 10.9}","state":"down","phi":300.0,"last_heartbeat_ms":7328}]}
   {"hello":"mona","greetings":2} [200] after 4.943359s
   ```

   `phi` grows with the silence of a peer. When it passes the threshold (8 by
   default) `a` asks `b` to reach `c` too, and when nobody can it marks `c`
   `down` and disconnects it. The request that was waiting for `c` fails at that
   moment, `a` takes `mona` over, and the answer comes at 4.9 s instead of
   after the 60 s `net_ticktime` or the 30 s lease. A request for another cell of
   `c` after that is answered at once (38 ms for `nick`). The 4.9 s is the
   detection time; to shorten it see "Tune the failure detector" below.

   `kill -CONT PID` thaws it; its heartbeats come back and `c` is `alive`
   again in the same listing, with none of its taken cells (the old owner is
   fenced). The states are `alive`, `suspect`, `link_broken` (this node cannot
   reach the peer but another can; its cells are not taken) and `down`.

9. Tell Atanor that a node is gone, as the infrastructure would (a hook that runs
   after `virsh destroy`, a cloud event, an orchestrator). The admin token is
   required. Freeze `c` again and post the hint to any node:

   ```sh
   kill -STOP PID
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5001/nodes/c@HOST/gone
   curl -s -H "authorization: Bearer demo-token" localhost:5002/nodes
   curl -s -m 5 -w ' [%{http_code}] after %{time_total}s\n' -H "host: localhost" localhost:4002/hello/oscar
   ```

   ```text
   {"node":"c@myhost","state":"down"}
   {"node":"b@myhost","nodes":[{"node":"a@myhost","reason":null,"state":"alive","phi":-0.0,"last_heartbeat_ms":298},{"node":"c@myhost","reason":":platform_hint","state":"down","phi":-0.0,"last_heartbeat_ms":105}]}
   {"hello":"oscar","greetings":2} [200] after 0.018528s
   ```

   Both nodes mark `c` down at once, without waiting for phi, and the first
   request for a cell of `c` (`oscar`) takes it over in 18 ms. A node that is not
   known is 404 `unknown_node` and a call without the token is 401. Thaw `c`
   with `kill -CONT PID`; for a few seconds it still counts its peers as lost
   and may answer 400 or 503.

10. Clean up: press Ctrl-C twice in the terminals of the nodes that still run,
   then remove the bucket container and the data directories.

   ```sh
   mise run seaweedfs:down
   rm -r /tmp/atanor-demo
   ```

## Keep the cookie and the distribution ports private

The Erlang cookie is a root password for every node: whoever has it and can
reach a node's distribution port can run any code there and read every
tenant's cells and secrets. Distribution is plain TCP, so forwarded requests
(headers and bodies included) cross it unencrypted. For a real cluster:

1. Generate a cookie that is not used for anything else (not the admin or
   dashboard token), and give it to the process through the environment:

   ```sh
   export RELEASE_COOKIE="$(openssl rand -base64 32)"   # releases
   export ALAMBIQUE_COOKIE="$RELEASE_COOKIE"             # Alambique's Mix tasks
   ```

2. Open `epmd` (4369) and the distribution ports only between the nodes. Fix the
   range with `-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9110` so a
   firewall rule can name it.
3. If the network between the nodes is not private, use TLS distribution: start
   the nodes with `-proto_dist inet_tls -ssl_dist_optfile /etc/atanor/dist.conf`
   and put the certificates in that file, as the Erlang/OTP guide "Using TLS for
   Erlang Distribution" describes. Check it with `:net_kernel.get_net_ticktime()`
   on a node and a successful `--connect`.

The demo above uses the public cookie `atanor-demo` for a local run only. The
lab scripts generate a separate random secret for the cookie and for the admin
and dashboard token.

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
majority of the nodes it knows, so a node cut off from the others takes nothing;
in a cluster of two a silent failure then waits for the lease
([what-does-not-work.md](what-does-not-work.md)).

## Stop a node without errors

A node stopped with a release stop, `Supervisor.stop/1` or `System.stop/0`
closes its listeners, tells its peers that it leaves, and hands its cells off
before it exits (design [§8.11](design.md#811-draining-and-stopping-gracefully)). Its cells
serve again on the other nodes in about 10 ms, and `GET` requests through the
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
| 503 `{"error":"unavailable","reason":"held_elsewhere"}` | The call did not run: a node outside this cluster (one being replaced) holds the cell's lease. | Wait the `Retry-After` time, which follows the lease; the lease is released when that node drains. |
| 503 `{"error":"unavailable","reason":"fenced"}` | The call did not run: this node lost the cell's lease (a takeover or a move fenced it). | Repeat it; the owner lookup finds the new owner. |
| 503 `{"error":"overloaded","reason":"overloaded"}` | The call did not run: the WASM queue was full. | Retry after the `Retry-After` time, or raise the queue. |
| 503 `{"error":"unknown_outcome","reason":"unknown_outcome"}` | The call started on a node that was lost. A `GET` is repeated by Atanor itself; a `POST` is not. | Read the state before repeating a write. |
| 500 `{"error":"foreign_store","reason":"foreign_store"}` | The call did not run: it was routed toward a node that runs this instance over another store or prefix. A repeat fails the same way, and there is no `Retry-After`. | Give every node the same `store:` (or `placement:`) and `prefix:`; see Troubleshooting. |
| 500 `{"error":"internal_error"}` | A defect: the worker raised, returned an invalid response, or an unexpected error happened. | Report it; it is not expected unavailability. |

Every 503 carries `Retry-After` in seconds (`http: [retry_after_s: 1]` by
default; `held_elsewhere` follows the lease, at most `retry_after_max_s`, 30) and a `reason` field. A worker that catches a cell error and answers 5xx
still gets the 503: the runtime keeps the availability reason of the cell call.

[design.md §8.4](design.md#84-when-the-node-is-lost) has the full table.

## Troubleshooting

- **`/health` lists only one node.** The nodes are not connected. Check that
  every node has the same `--cookie`, that `--connect` names `NAME@HOST` with
  the host from `hostname -s`, and run `epmd -names` to see the registered
  names. Nodes started with `--sname` cannot connect to nodes started with
  `--name`.
- **`mix atanor.dev` says `--connect needs a named node`.** Start it through
  `elixir --sname NAME -S mix atanor.dev`, as above.
- **`could not connect to ...`.** The other node is not up yet or uses another
  cookie. Start the nodes one after the other.
- **Every request is a 404.** `host: localhost` is missing: the route of the
  example matches the host `localhost`.
- **500 `foreign_store`, and an error in the log naming a node.** A node of
  this cluster was routed toward a node that runs an instance of the same name
  over another store or prefix, so the call was refused (not retried, no
  `Retry-After`). Nodes of two stores are connected, or a restart changed the
  store's location (endpoint, bucket) or the prefix and the nodes are split
  between the old and the new value. Start every node of the instance with the
  same `store:` or `placement:` and `prefix:`, or disconnect the nodes of the
  other store. The event `[:atanor, :foreign_store]` counts the refusals.
- **A node answers `401` on the admin port.** Send
  `authorization: Bearer <the --admin-token>`.

## Next steps

- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) for the endpoints
  used above.
- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) to switch every node
  to a new version; a request that crosses nodes keeps the version it started
  on.
- [how-to-place-hot-cells.md](how-to-place-hot-cells.md) to let a very busy cell move to a less loaded or a dedicated node.
- [how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md) to run it on three VMs and break it on purpose.
- [design.md §8](design.md#8-cluster) for how routing, retries and failures
  work, and [what-does-not-work.md](what-does-not-work.md) for the limits.
