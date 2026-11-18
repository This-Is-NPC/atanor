# Telemetry

Atanor emits [`:telemetry`](https://hexdocs.pm/telemetry) events. Attach
handlers with `:telemetry.attach/4`. Durations are in native time units; use
`System.convert_time_unit/3`. Every event carries the `worker` (the manifest
name) and, when it belongs to a request, the `deployment` (the package id) and
the `cell` (`{namespace, key}`), so the dashboards of the three questions
"which worker", "which version" and "which cell" need no join.

| Question | Events |
| --- | --- |
| Requests, latency, errors | `[:atanor, :call]`, `[:atanor, :http, :reject]` |
| Bearer-token rejections and key fetches | `[:atanor, :auth, :reject]`, `[:atanor, :auth, :fetch]` |
| Cluster routing | `[:atanor, :forward]` |
| Failure detection | `[:atanor, :node, :suspect \| :down \| :link_broken \| :alive]` |
| Placement of hot cells | `[:atanor, :hot_cell, :sample \| :decision \| :move \| :replicas]` |
| Takeover of a lost node's cells, drain and graceful stop | `[:atanor, :cell, :take_over]`, `[:atanor, :node, :drain, ...]` |
| A node starts: deployments applied, then serving | `[:atanor, :deployments, :loaded]`, `[:atanor, :node, :ready]` |
| Awake cells migrated to a new worker version | `[:atanor, :foreign_store]` | `count` (1) | `instance`, `node` (the node of another store that a call was routed toward). A configuration error, not unavailability; the call is refused and not retried (design §8.4) |
| `[:atanor, :cells, :migrate]` |
| Limits hit and WASM instantiation | `[:atanor, :wasm, :limit]`, `[:atanor, :wasm, :invoke]`, `[:atanor, :wasm, :load]` |
| Cells hibernated to stay under `awake: [max_bytes:]` (Alambique's) | `[:alambique, :admission, :evict]` (`bytes`: memory of the awake cells after it; `cell`, `max_bytes`); documented in Alambique's `docs/telemetry.md` |
| Reads from replicas (Alambique's, design §19) | `[:alambique, :replica, :read]` (`source`: `:replica` or `:owner`, and `reason` for the owner), `:build`, `:refresh`, `:stop`; documented in Alambique's `docs/telemetry.md` |
| Disk use of `data_dir` against its budget | `[:atanor, :disk, :sample]`, `[:atanor, :disk, :reclaim]` |
| Cells hibernated because the working set passed `memory: [hibernate_fraction:]` | `[:atanor, :memory, :pressure]` |
| Ephemeral channels | `[:atanor, :channel, :publish]`, `[:atanor, :channel, :rejected]`, `[:atanor, :channel, :dropped]` |
| TCP, TLS, WebSockets, alarms | `[:atanor, :tcp, ...]`, `[:atanor, :tls, ...]`, `[:atanor, :ws, ...]`, `[:atanor, :alarm, ...]` |
| Jobs and bulk operations | `[:atanor, :job, ...]`, `[:atanor, :sweep, ...]` |
| Change feed | `[:atanor, :feed, :read]`, `[:atanor, :feed, :rejected]`, `[:atanor, :feed, :error]`, `[:atanor, :feed, :subscriber, :dropped]` |
| Admin control actions and the audit log | `[:atanor, :admin, :action]`, `[:atanor, :admin, :audit]` |
| Native counters | `[:atanor, :wasm, :native, :stats]` |

The [dashboard](how-to-open-the-dashboard.md) charts these events on its Metrics page.

## Calls and routing

`[:atanor, :call]` is emitted once per call into a worker, by the process that
ran it, on the node that ran it: an HTTP request (`:http` for
`handle_request/2`, `:plug` for a Plug), the callbacks of TCP connections
(`:tcp_init`, `:tcp_data`), of WebSockets (`:ws_init`, `:ws_in`, and `:ws_local` for
`handle_ws_local/3`, which runs on the socket's node) and an alarm
handler (`:alarm`). Work that the cluster forwards (design §8) is reported by
the owner, with `forwarded: true`.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :call]` | `duration` (the callback, without routing and without the network) | `worker`, `deployment`, `cell` (`{namespace, key}`, or `nil` when the work has no routing key), `kind`, `node` (the node that ran it), `instance`, `forwarded` (it came from another node), `release` (the node's release id), `result`: `:ok` or `:error`, `reason` (with `:error`: `:crashed`, `:bad_return`, `:bad_response`, `:overloaded`, `{:limit, :timeout \| :memory \| :cpu}`, ...), `status` (HTTP kinds, when a response was sent) |
| `[:atanor, :forward]` | `duration` (the whole round trip) | `worker`, `deployment`, `cell`, `target` (the node), `result`: `:ok`, `:moved` (it no longer owns the cell), `:rejected` (it cannot run the deployment), `:lost` (the connection failed before the callback started) or `:unknown_outcome` (it started, then the connection failed or the call timed out) |
| `[:atanor, :cells, :migrate]` | `count` (cells migrated), `errors` (cells whose migration failed) | `namespace`, `node`. Emitted by the node that applied a worker with new or more migrations for the namespace, once it finished migrating its awake cells of it (design §4.1) |
| `[:atanor, :http, :reject]` | `count` (1) | `reason`: `:no_route`, `:no_handler`, `:payload_too_large`, `:bad_request`, `:origin_not_allowed` (a WebSocket upgrade from an origin outside `websocket.allowed_origins`), `:bad_host` or `:bad_path` (the last two before any route is looked up), or the reason of a 503 `overloaded`: `:memory` / `:disk` / `:in_flight` (admission control, before anything else), `:wake_gate`, `:awake_limit`, `:busy`, `:disk_full`, `:worker_queue` (the WASM queue was full), `:nested_calls` (a call between workers above `max_nested_calls`) or `:queue_timeout` (a call the node refused after admitting the request, the last because it waited past `http.queue_wait_ms`; design §7.1), or the reason of any other 503 the node answers after admitting the request (`:owner_unreachable`, `:fenced`, `:owner_unknown`, `:store_unavailable`, `:unknown_outcome`, ...; design §8.4), `status`, `host`, `worker` (`nil` when no route matched) |

| `[:atanor, :auth, :reject]` | `count` (1) | `reason` (an atom: `:missing`, `:bad_request`, `:malformed`, `:algorithm`, `:type`, `:no_key`, `:signature`, `:claims`, `:issuer`, `:audience`, `:no_expiry`, `:expired`, `:not_yet_valid`, `:issued_in_future`, `:insufficient_scope`, `:keys_unavailable`), `status` (400, 401, 403 or 503), `host`, `worker`. A request that failed the `auth:` rule of its route and did not reach the worker ([how to protect a route](how-to-protect-a-route-with-oidc.md)). Never carries the token or a claim |
| `[:atanor, :auth, :fetch]` | `duration` | `issuer`, `kind` (`:discovery` or `:jwks`), `result` (`:ok` or `:error`), `reason` (with `:error`: `:unreachable`, `{:status, code}`, `:invalid_json`, `:too_large`). One fetch of the OIDC discovery document or the JWKS, at most one JWKS fetch per `oidc.min_refresh_ms` per issuer |

`[:atanor, :forward]` is emitted by the ingress node. `[:atanor, :call]` for the
same request is emitted by the owner. The two together give routing overhead
(the difference between the forward's `duration` and the call's).

## Placement of hot cells

Emitted when `hot_cells: [enabled: true]` (design §8.15,
[how-to-place-hot-cells.md](how-to-place-hot-cells.md)). Rates are per second.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :hot_cell, :sample]` | `cpu` (from 0 to 100: the larger of `scheduler`, the use of the VM's schedulers, and `os`, the use of the machine from `/proc/stat`, `nil` without it), `scheduler`, `os`, `reads`, `writes` (all the cells this node counted), `hot` (hot cells tracked). Once per `interval_ms` | `instance`, `node`, `pressured` (the node is between `cpu_enter` and `cpu_exit`) |
| `[:atanor, :hot_cell, :decision]` | `hot_ms` (how long the cell has been hot) | `instance`, `cell` (`{namespace, key}`), `action`: `:move` or `:stay`, `reason`: with `:move`, `:load` or `:affinity`; with `:stay`, `:residence`, `:cap`, `:cooldown`, `:on_dedicated`, `:not_pressured`, `:no_target` or `:no_margin`, `target` (the node, with `:move`), `reads`, `writes`, `queue`, `cpu`. For a cell hot for `sustain_ms`; a `:stay` is emitted when its reason changes, a `:move` every time |
| `[:atanor, :hot_cell, :move]` | `duration` (the whole `Alambique.move/4`: hibernate on the source and wake on the target) | `instance`, `cell`, `from`, `to`, `reason` (`:load`, `:affinity`, `:manual` or `:rebalance`), `result`: `:ok` or `{:error, reason}` |

| `[:atanor, :hot_cell, :replicas]` | `reads` (the cell's reads per second in the cluster, when the change was made) | `instance`, `cell`, `action`: `:on` or `:off`, `result`: `:ok` or `{:error, reason}`. With `hot_cells: [replicas: true]` (design §19.4); a failed change is tried again at the next sample, so an error that repeats is a store problem |

Alert on `:move` with an `{:error, _}` result that repeats for one cell, and on
`:move` events for one cell closer than the residence time (they are manual or
`:rebalance`).

## Rebalance on join

Emitted by every node unless `rebalance: [enabled: false]` (design §8.1,
[how-to-run-a-cluster.md](how-to-run-a-cluster.md#what-happens-when-a-node-joins)). A rebalance move also
emits `[:atanor, :hot_cell, :move]` with the reason `:rebalance`.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :rebalance, :start]` | `cells` (the cells the first round will move) | `instance`, `node`, `epoch` (counts the changes of the membership this node saw), `members` |
| `[:atanor, :rebalance, :move]` | `duration` (the whole move, in native time units) | `instance`, `cell` (the Alambique id), `from`, `to`, `result`: `:ok` or `{:error, reason}`. A cell with a call in flight refuses the move (`{:error, :busy}`): it is tried again in this or a later round and emits no move event until the move ends |
| `[:atanor, :rebalance, :stop]` | `moved`, `failed`, `deferred` (cells left for a later round in the last one), `duration` (milliseconds since the plan started) | `instance`, `node`, `epoch`, `members`, `reason`: `:done` (a round found nothing to move) or `:membership_changed` (the plan was dropped and starts again) |

The same state is in `GET /runtime`, under `rebalance`: `phase` (`idle`, `waiting`, `running`,
`between_rounds` or `done`), `members`, `last_membership_change_ms`, `starts_in_ms`, `pending`,
`moved`, `failed`, `deferred`, `moving` and `total` since the node started.

Alert on `:move` with an `{:error, _}` result that repeats, and on a `:stop` with
`failed` above 0 at every join.

## Crash reports

`[:atanor, :crash, :detected]` is emitted once when the diagnostics process
finds the busy breadcrumbs of a previous VM and writes a report (design
§17.2). It is emitted even when the store write failed and the report stayed
in the local pending directory.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :crash, :detected]` | `count` (1) | `instance`, `node`, `release` (the release id), `id` (the report id), `units` (number of units in the report), `truncated` (units or files dropped by `diagnostics.max_units`/`:max_files`) |

The report itself is at `<prefix>/crashes/<node>/<id>`; `GET /crashes` reads
it. A report with no units (for example only unreadable files) is not written.

## Node events

The failure detector (design §8.6 to §8.10) emits these on the node that decides,
about one of its peers. Every event has `phi` as measurement (phi of the peer at
that moment; 300 is the cap) and `instance` and `node` (the peer) in the metadata.

| Event | Metadata | Meaning |
| --- | --- | --- |
| `[:atanor, :node, :suspect]` | `reason`: `{:phi, value}` or `{:nodedown, reason}` | phi reached the threshold, or the connection dropped; a probe round starts |
| `[:atanor, :node, :down]` | `reason`: `{:phi, value}`, `{:nodedown, reason}`, `:left` (the node announced that it stops) or `:platform_hint` | nobody reached the peer; calls are no longer forwarded to it and it is disconnected (not when it left) |
| `[:atanor, :node, :link_broken]` | `via` (the node that reached the peer) | this node cannot reach the peer, but another can; it stays in the cluster and calls are not forwarded to it from here |
| `[:atanor, :node, :alive]` | `from` (the previous state) | heartbeats are back |

Discovery through the store (design §8.16) emits these, with no measurements:

| Event | Metadata | Meaning |
| --- | --- | --- |
| `[:atanor, :discovery, :joined]` | `instance`, `node_id`, `advertise` | a peer entered the registry's listing |
| `[:atanor, :discovery, :left]` | `instance`, `node_id`, `advertise` | a peer left it (stopped, or expired); the node stays connected |
| `[:atanor, :discovery, :connect]` | `instance`, `node`, `result` (`:ok` or `:failed`) | one `Node.connect/1` to a listed peer |
| `[:atanor, :discovery, :invalid]` | `instance`, `advertise` | a peer advertises something that is not a node name |
| `[:atanor, :discovery, :ignored]` | `instance`, `node_id`, `advertise` | a peer of another group, not dialled |

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :cell, :take_over]` | `duration` (the whole step: quorum, lease read, `Alambique.take_over/4`) | `instance`, `cell` (the Alambique id, `<namespace>.<key>`), `node` (the lost owner), `reason` (why the detector has it down), `result`: `:ok` (the cell is served here now), `:moved` (another node won a concurrent takeover and serves it), `:stale` (the lease no longer named the lost owner), `:no_quorum` (this node is not in a majority, nothing was taken; rate-limited, see below) or `{:error, reason}` (the cell stays unavailable until its lease expires) |
| `[:atanor, :deployments, :loaded]` | `duration`, `workers` (heads read) | `instance`, `node` |
| `[:atanor, :node, :ready]` | none | `instance`, `node` |
| `[:atanor, :node, :drain, :start]` | `system_time` | `instance`, `node`, `trigger` (`:api`: `Atanor.drain/2`, the admin API or `atanor drain`; `:stop`: the instance stops) |
| `[:atanor, :node, :drain]` | `duration` (native units), `hibernated` (cells put to sleep, their leases released), `errors` (cells that could not be) | `instance`, `node`, `trigger`, `error_list` (`{cell, reason}`; `{:drain, :deadline}` when `stop.shutdown_ms` ended the drain) |

`:loaded` is emitted once per start, when the first load of the deployments
is complete, and `:ready` when `/health/ready` turns 200 (design §2.1). The
node joins the cluster between the two, so no cell wakes on it before
`:loaded`. `:take_over` is emitted by the node that took the cell, once per call that needed
it (design §8.10); a cell already awake here costs no event. A `:no_quorum` refusal is emitted at most once per
`takeover.no_quorum_event_interval_ms` (10 s by default) on the node: the first refusal at once, then the
next one after the interval, whose metadata `suppressed` counts the refusals left out since the last
event (it is 0 on the first). A partition emits one event per interval, not one per request. The
refusals after the last event stay uncounted when the partition ends before another interval. `:drain` is the end of the
drain of the node that hands its cells back, on demand or because it stops
(design §8.11); `:start` is its beginning. A non-empty `error_list` is also logged as
a warning.

Alert on `:down` and `:link_broken`; a `:suspect` that is followed by `:alive`
within seconds is a late heartbeat, and many of them say the settings are too
tight for the network.

## Disk events

Emitted by the disk monitor of a node that has a disk budget (design §4.4,
[configuration](configuration.md#cells-limits-memory-and-store-requests)).

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :disk, :sample]` | `used_bytes` (the files under `data_dir`), `budget_bytes` | `instance`, `level`: `:ok`, `:reclaim` (the use is at `evict_fraction` of the budget or above, until 5 points below) or `:refuse` (at `refuse_fraction`: the ingress answers 503 `overloaded`, counted by `[:atanor, :http, :reject]` with reason `:disk`). Every `disk: [sample_ms:]`, every second or less while the level is not `:ok` |
| `[:atanor, :disk, :reclaim]` | `candidates` (idle cells chosen for their `-wal` size), `hibernated` (the ones that went to sleep) | `instance`. One per sample at `:reclaim` or `:refuse` |

## Memory pressure events

Emitted by a node that has a memory limit while its working set is at `memory: [hibernate_fraction:]` of
the limit or more (design §4.3,
[configuration](configuration.md#cells-limits-memory-and-store-requests)).

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :memory, :pressure]` | `working_set_bytes` (the sample that started the batch), `candidates` (idle cells chosen, at most `hibernate_batch`, least recently used first), `hibernated` (the ones that went to sleep; a cell with a call in flight is skipped) | `instance`. One per `memory: [hibernate_interval_ms:]` while the working set stays at the mark or above |

`GET /runtime` returns the total as `pressure: {hibernated, hibernate_at_bytes}` (`null` when the node does not watch its working set).

## Counters of `GET /runtime`

* `admission.refused` counts every 503 the HTTP layer answers, once each: `memory`, `disk`, `in_flight`,
  `queue_timeout`, `worker_queue`, `nested_calls`, `wake_gate`, `awake_limit`, `busy` and `disk_full` for the
  overload refusals, and `unavailable` for every other 503. `awake_limit` also counts a wake that Alambique
  refuses because its wake slots and queue are full. A 503 `overloaded` that names no gate counts as
  `unavailable` (`unavailable_by_reason.overloaded_unattributed`).
* `admission.awake_limit_by` splits the wakes Alambique refused with `{:error, :overloaded}` by the `reason` of its
  `[:alambique, :admission, :overloaded]` event: `no_wait` (no free wake slot and no time to wait for one),
  `queue_full`, `wait_expired`, `crowded` and `max_children`. The event names no instance, so a VM that runs more
  than one instance counts the refusals of all of them in each. It counts wakes, and `awake_limit` counts calls
  (and also the awake-cells ceiling), so the sum of `awake_limit_by` can differ from `awake_limit`.
* `admission.unavailable_by_reason` splits `refused.unavailable` by the `reason` of the answer: for example
  `owner_unreachable`, `fenced`, `owner_unknown`, `store_unavailable`, `deployment_unavailable`, `draining`,
  `unknown_outcome`, `keys_unavailable` (a 503 of an `auth:` route) and `overloaded_unattributed` (an
  `overloaded` that names no gate). A reason that is not an atom counts as `other`. The sum of its values is
  `refused.unavailable`. The 503 of the ingress gates and of the call gates is not in it.
* `consent` says which operator ceilings the node enforces: `hosts`, `http_allow` and `namespaces` are
  `true` when the matching option is set, and `open` is `true` when none is, so any deployer may claim routes,
  namespaces and outbound hosts
  ([who may claim what](how-to-run-in-production.md#who-may-claim-what)).
* `wakes` is the number of cells woken on this node since it started, counted from Alambique's
  `[:alambique, :cell, :wake]` event with `result: :ok`. The event names no instance, so a VM that runs more
  than one instance counts the wakes of all of them in each.
* `wake_ms` is the time those wakes took, from the `duration` of the same event: `total` (the sum, in
  milliseconds) and `max` (the longest wake). `total / wakes` is the mean wake. It does not include the time
  a wake waited for a slot.
* `hibernations.compaction` counts the cells hibernated on this node since it started, by the outcome of the
  compaction Alambique runs on the WAL tail before it releases the lease: `none` (not tried, or the call had
  less than `release_reserve_ms` left), `done`, `deadline` (the deadline passed and the cell was released with
  its chain partly merged; the merges already made stay), `deadline_error` (the deadline passed while the cell's
  files were being listed, before the chain was known) and `error` (the pass failed and the cell was released
  anyway). `hibernations.tail_max` is the longest tail, in level-0 files, that was left after a release
  compaction (before Alambique 0.13.0 it was the tail found before it). They come from
  Alambique's `[:alambique, :cell, :hibernate]` event, which every hibernation emits (idle, on request, at
  shutdown), and the event names no instance, so a VM that runs more than one instance counts all of them in
  each. A `deadline`, `deadline_error` or `error` also logs `atanor: release compaction of "<cell>" ended with ...`, at most once
  per second per node.

## WASM events

`worker` is the manifest name and `deployment` the package id.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :wasm, :load]` | `duration` (to get the compiled component), `bytes` (size of the component) | `hash` (package id), `source`: `:memory`, `:disk` (compiled code read from the disk cache), `:compiled`, or `:recompiled` (a cache file existed but was unusable) |
| `[:atanor, :wasm, :prepare]` | `duration` (linking the granted imports) | `worker` |
| `[:atanor, :wasm, :invoke]` | `duration` (whole call, including the queue), `instantiate`, `run` (guest time after instantiation), `cpu` (CPU time of the pool thread), `memory_bytes` (peak linear memory), `fuel_used` (fuel mode only). The last five are absent when the call never ran (`:overloaded`) | `instance`, `worker`, `deployment`, `call`: `:http`, `:alarm`, `:ws_open`, `:ws_message`, `:ws_local` or `:ws_close`, `result`: `:ok`, `{:limit, :timeout \| :memory \| :cpu}`, `:overloaded`, `:response_too_large`, `:trap` or `:guest` |
| `[:atanor, :wasm, :limit]` | `count` (1) | `worker`, `deployment`, `call` (as above), `limit`: `:timeout`, `:memory` or `:cpu` |

`:invoke` is emitted by the process that ran the call: the request, the alarm
task or the socket process. `:limit` is emitted next to it when a limit
stopped the guest. These events have no `cell`: the `[:atanor, :call]` of the
same call names it, and its `reason` is `{:limit, kind}` when a limit stopped
it.

## TCP, WebSocket and alarm events

`worker` is the manifest name, `deployment` the package id and `cell` the
address `{namespace, key}` the connection or socket is bound to (`nil` when
unbound).

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :tcp, :connect]` | `count` (1) | `worker`, `deployment`, `listener`, `cell` |
| `[:atanor, :tcp, :disconnect]` | `duration`, `bytes_in`, `bytes_out` (ThousandIsland only) | as above, plus `reason`: `:peer`, `:worker` (the worker closed), `:timeout` (idle), `:shutdown` (listener closed), `:error` (callback failure or write error), `{:unavailable, reason}` (the cell could not be reached, for example `:draining` or `:held_elsewhere`; a TCP connection has no `Retry-After`, design §8.4). Ranch connections add `exit_reason` (the process exit reason) and have no byte counts |
| `[:atanor, :ws, :connect]` | `count` (1) | `worker`, `deployment`, `cell` |
| `[:atanor, :ws, :disconnect]` | `duration` | as above, plus `reason` (the WebSock terminate reason) |
| `[:atanor, :alarm, :fired]` | `duration` (claim to acknowledgment, including the handler) | `worker`, `deployment`, `cell` (here the cell id, `<namespace>.<key>`), `attempt` |
| `[:atanor, :alarm, :failed]` | `duration` | `worker`, `cell`, `reason`, `final` (`true` when the alarm was dropped after `max_attempts`); `deployment` and `attempt` are present unless the firing was killed at `timeout_ms` (then `reason` is `:timeout`) |

TCP events come from the connection process, WebSocket events from the socket
process and alarm events from the alarm task. Ranch listeners emit the same
connect and disconnect events per connection; their `reason` is mapped from
the process exit (`:peer` for `:normal`, `:shutdown`, `:error` otherwise), and
`exit_reason` keeps the exact term.

## Ephemeral channel events

Ephemeral channels (design §7.6). `cell` is the address `{namespace, key}`.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :channel, :publish]` | `count` (1), `bytes` (the message), `nodes` (the nodes the publisher sent to, itself included when it has members), `subscribers` (members on all nodes) | `instance`, `cell` |
| `[:atanor, :channel, :rejected]` | `count` (1) | `reason`: `:too_large` (the `max_message_bytes` limit of a publish), `:too_many_subscriptions` or `:too_many_channels` (a join), `cell` |
| `[:atanor, :channel, :dropped]` | `count` (members skipped in one delivery on this node) | `cell`, `node`. A member with more than `channels.max_queue` messages waiting misses the message. Also emitted for `send_to_cell/3` messages |

A publish event comes from the node that published. `handle_ws_local/3` calls
are `[:atanor, :call]` events with `kind: :ws_local`, emitted on the socket's
node with the socket's cell.

## TLS events

A TLS listener (design §7.3) reports each handshake and certificate reload.
`instance` is the instance name, `listener` the operator's name and `node` the
node that ran it.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :tls, :handshake]` | `duration` | `instance`, `listener`, `node`, `mode`: `:implicit` or `:starttls`, `result`: `:ok` or `{:error, reason}` |
| `[:atanor, :tls, :starttls]` | `count` (1) | as above, without `mode`: one STARTTLS upgrade was attempted |
| `[:atanor, :tls, :reload]` | `count` (1) | `instance`, `listener`, `node`, `cause`: `:poll` or `:admin`, `result`: `:ok` or `{:error, reason}` (the previous certificate stays in service) |
| `[:atanor, :tls, :validity]` | `seconds_left` (negative once expired) | `instance`, `listener`, `node`, `not_after` (Unix seconds), `status`: `:ok`, `:expiring` (within `tls.expiry_warn_days`, 14 by default), `:expired` or `:not_yet_valid` |

`:validity` is emitted when the listener starts, after each successful reload
and whenever the status of the served certificate changes between polls. Each
status other than `:ok` also logs a warning; the certificate is served in every
case.

An implicit TLS connection emits one `:handshake` and no `:starttls`; a
STARTTLS upgrade emits both. The events are emitted by the handshake itself,
before the worker sees the connection, so they also cover connections a
protocol library (gen_smtp) upgrades.

## Job and sweep events

A job attempt runs on the cell owner; a sweep page is emitted by the node that
drives the operation, and an undo report, apply and rewind by the node that made it.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :job, :enqueued]` | `count` (1) | `worker`, `cell`, `kind`, `operation_id`, `unique`, `node` |
| `[:atanor, :job, :started]` | `count` (1) | `worker`, `deployment`, `cell`, `id`, `kind`, `attempt`, `operation_id`, `claimed_until_ms` (when the claim expires), `node` |
| `[:atanor, :job, :unconfirmed]` | `count` (1) | `worker`, `cell`, `id`, `attempt`, `reason`, `node` |
| `[:atanor, :job, :finished]` | `duration` (the attempt) | `worker`, `cell`, `id`, `kind`, `attempt`, `result` (`:ok` or `:error`), `reason`, `infrastructure` (`true` when the attempt ended in an error of the store or the cell, which does not count as an attempt), `final` (`true` when the job became dead), `node` |
| `[:atanor, :job, :dead]` | `count` (1) | `worker`, `cell`, `id`, `kind`, `reason`, `cause` (`:max_attempts`: the handler failed `max_attempts` times; `:infrastructure`: errors of the store or the cell lasted `jobs.infrastructure_timeout_ms`, and `reason` starts with `infrastructure: `), `node` |
| `[:atanor, :handler, :fenced]` | `count` (1) | `kind` (`:job` or `:alarm`), `worker`, `cell`, `reason` (`:local_deadline`: the node's lease on the cell ended; `:lost`: a read showed another owner or epoch; `:unreadable`: the lease could not be read, so the handler did not start; `:stopped`: the instance is stopping), `deadline_ms` (the deadline on the lease clock, for `:local_deadline` and `:lost`), `node` |
| `[:atanor, :job, :released]` | `count` (jobs released) | `cell`, `from` (the node that was taken over), `epoch` (the epoch the takeover raised; `nil` when a draining node released its own claims, and `from` is then the node itself), `node` (the node that released) |
| `[:atanor, :sweep, :started]`, `:paused`, `:resumed`, `:cancelled`, `:done`, `:failed` | `count` (1) | `operation`, `selector`, `driver`, `node` |
| `[:atanor, :sweep, :continued]`, `:awaiting_confirmation`, `:canary_passed` | `count` (1) | `operation`, `selector`, `driver`, `node` |
| `[:atanor, :sweep, :halted]` | `count` (1) | `operation`, `selector`, `driver`, `node`, `reason` (`"error_rate"`, `"canary_timeout"` or `"guard_unavailable"`) |
| `[:atanor, :sweep, :page]` | `dispatched`, `skipped`, `failed` | `operation`, `cursor`, `node` |
| `[:atanor, :sweep, :lease_lost]` | `count` (1) | `operation`, `node` |
| `[:atanor, :sweep, :undo_report]` | `count` (1), `duration_ms`, `cells` (target cells walked) | `operation`, `state` (`"done"` or `"failed"`), `node` |
| `[:atanor, :sweep, :undo_apply]` | `count` (1), `duration_ms`, `cells` (cells in the record), `rewound` (cells rewound so far, over all passes) | `operation`, `state` (`"done"` or `"failed"`), `node` |
| `[:atanor, :sweep, :undo_rewind]` | `count` (1), `duration_ms` (one cell) | `cell`, `result` (`"rewound"`, `"data_written"`, `"failed"`, `"unknown"` or `"skipped"`), `node` |
| `[:atanor, :admin, :action]` | `count` (1) | `action`, `target`, `remote_ip`, `node` |
| `[:atanor, :admin, :audit]` | `count` (1) | `instance`, `action`, `result` (`"ok"`, `"denied"` or `"failed"`), `worker`, `node`, `stored` (`false` when the entry could not be written) |

`duration` is in native time units like every other event. A job attempt that
waits for a slot has no `:started` event until it is claimed; an attempt that
times out (`jobs.timeout_ms`) emits `:finished` with `reason: :handler_timeout`. `:released` is emitted
when a takeover frees the claims of a node confirmed down (design §15.11); the
jobs then start with `:started` like any other attempt. An attempt that is
stopped because its node lost the cell emits no `:finished`. `:unconfirmed` is emitted
when the write that ends an attempt failed and may or may not have been applied (the owner
was lost or too slow while it ran, design §8.4); the job may be pending again, so it can start
again with no `:finished` and no `:released`.

## Change feed events

A read is emitted by the process that reads: `Atanor.Env.changes/4` or the
node's feed tailer. `namespace` is `nil` for the tailer's shared stream, which
reads all namespaces before filtering.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :feed, :read]` | `duration` (native units), `records` (feed records read), `kept` (records of a worker namespace), `rejected` (objects Alambique could not decode, left out) | `instance`, `namespace`, `result`: `:ok` or `:error`, `reason` with an error |
| `[:atanor, :feed, :rejected]` | `count` (1) | `instance`, `namespace` (`nil` for the tailer's shared stream), `reason`, `key` (the object's key in the store). One event per object Alambique could not decode. `reason` is `:invalid_json`, `:bad_object`, `:bad_record`, `{:bad_op, op}`, `{:unsupported_format, version}` (a format version this Alambique does not read), `:bad_format` (not a feed object), `:too_large` or `:bad_compression`. The tailer and `Atanor.Env.changes/4` emit it; a subscriber that catches up reads its own pages, so an object can be reported again. The tailer also logs a warning, at most one per `feed.max_backoff_ms` |
| `[:atanor, :feed, :error]` | `count` (1), `retry_ms` (the wait before the next read) | `instance`, `reason`. Emitted by the tailer when a read fails; subscribers stay |
| `[:atanor, :feed, :subscriber, :dropped]` | `count` (1), `backlog` (messages in the subscriber's mailbox) | `instance`, `namespace`, `reason`: `:backlog` |

A subscriber that is dropped receives `{:atanor_feed_dropped, ref, position}`
and can resubscribe from that position (design §16.3).

## Native counters

`Atanor.Wasm.Stats.emit/0` sends `[:atanor, :wasm, :native, :stats]` with the
counters of the native library, which `read/0` returns as a map. Use it as a
`:telemetry_poller` measurement:

```elixir
{:telemetry_poller,
 measurements: [{Atanor.Wasm.Stats, :emit, []}], period: :timer.seconds(10)}
```

| Measurement | Kind | Meaning |
| --- | --- | --- |
| `alloc_bytes`, `free_bytes` | counters | Rust heap bytes allocated and freed; live bytes are the difference. Guest memories are mapped, not allocated: see `memory_bytes` of `:invoke` |
| `compiled_components` | counter | Components compiled (not loaded from disk) |
| `live_components` | gauge | Compiled components alive |
| `disk_cache_hits`, `disk_cache_misses` | counters | Compiled-code files used, and lookups that found none or an unusable one |
| `live_instances` | gauge | Guest instances running now |
| `queued_calls` | gauge | Calls waiting for a pool thread |
| `calls`, `calls_ok` | counters | Calls taken by a thread, and those that returned a response |
| `rejected_calls` | counter | Calls refused because the queue was full, or taken back or dropped because they waited too long |
| `traps_timeout`, `traps_memory`, `traps_cpu`, `traps_other` | counters | Calls stopped by each limit, and by any other trap or error |
| `fuel_interrupts`, `epoch_interrupts` | counters | CPU limits hit in fuel and in epoch mode |
| `host_calls` | counter | Calls from guests into Elixir (cells, secrets, worker calls, outbound HTTP) |
| `instantiate_ns_total`, `call_ns_total` | counters | Time spent instantiating and running guests, in nanoseconds |
| `memory_peak_bytes_total` | counter | Sum of the peak linear memory of every call |
