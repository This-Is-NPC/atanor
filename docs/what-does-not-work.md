# What does not work

Known defects and limits that are still open. Each entry says what happens,
what to do about it, and where the evidence is. Entries are removed when they
are fixed.

## A deploy token is still the authority of its manifest for some grants

**What happens.** Cell namespaces and calls between workers need the other
side's consent ([design §3.3](design.md#33-what-a-manifest-may-grant)), but
`hosts:`, a listener's `workers:`, `http_allow:` and `modules:` are ceilings that
exist only when the operator sets them. Without them, a holder of a deploy and
activate token for one worker can route any host, claim any configured listener,
reach any host in `http.allow` and bind any module of the release. Two
workers that share a namespace (which the operator must allow) can still read and write each other's `_atanor_*` tables (jobs, alarms,
cron, undo positions): a worker can insert a job row that runs another worker's
`handle_job/2`, or rewrite an undo position. Sharing a namespace puts the
workers in one trust domain. A check that a job's worker grants jobs and the
namespace was tried and not kept: a worker that has both still runs a planted
row, and a refused row at the head of a cell with `cell_concurrency` 1 blocks
the jobs behind it.

**Workaround.** Set the four ceilings on every node where several teams deploy,
and cap the component with `package: [max_component_bytes: ...]`. Give each
tenant its own namespaces and share one only between workers you trust.

**Evidence.** `test/atanor/grants_test.exs`, `test/atanor/package_limits_test.exs`.

## The audit log has no retention

**What happens.** A forbidden call on an audited endpoint writes an audit object
that Atanor never deletes: the log is immutable by design.

**Workaround.** Give the `audit/` prefix of the bucket a lifecycle rule that
expires old objects.

**Evidence.** `lib/atanor/admin/audit.ex` writes entries and lists them; nothing
deletes them.

## A WebSocket costs a file descriptor and a marker file

**What happens.** With `diagnostics: [breadcrumbs: :durable]` (the default) each
WebSocket opens a marker file for its whole life, so it holds two descriptors
(the connection and the marker) and one file in `data_dir/diagnostics/units/`.
A node at the default `http.max_connections` (16 384) can need more than the
1 024 descriptors that a service manager often allows.

**Workaround.** Raise the limit (`LimitNOFILE=65536` in the unit, or `ulimit
-n`) to at least twice `http.max_connections` plus the cells' files, or lower
`http.max_connections`. `diagnostics: [breadcrumbs: :off]` removes the marker at
the price of the crash reports of WebSocket handlers.

**Evidence.** [design.md §17.2](design.md#172-crash-diagnostics).
Opening the marker for the length of a frame instead puts a file create and
delete on every frame, which was judged worse for a busy socket.

## Smaller gaps in tokens, cookies and the CLI

**What happens.**

* A route's `types:` defaults to any `typ`, so an ID token that the same issuer
  signs for the same audience passes as an access token. Many providers issue
  access tokens with `typ: JWT`, so a stricter default would break them.
* A Ranch protocol that starts TLS itself gets the listener's private key in its
  start options (gen_smtp `STARTTLS` needs it), so it is in that process's state.

**Workaround.** Set `types:` on every rule to what the provider issues. Run only
Ranch protocols you trust on a listener with a key.

**Evidence.** [design.md §7.3](design.md#73-tcp-and-websockets) and
[§7.5](design.md#75-bearer-tokens-on-a-route);
[how-to-protect-a-route-with-oidc.md](how-to-protect-a-route-with-oidc.md).

## Slow and many clients are bounded per read and per listener, not per client

**What happens.** `http.read_timeout_ms` (10 s by default) is the wait for the
next bytes of one read. A client that sends one byte of a header, or one chunk
of a chunked body, before each timeout keeps its connection for as long as it
keeps doing so; Bandit offers no deadline for the whole request. Connections
are capped for the listener (`http.max_connections`, `admin.max_connections`)
but not per client address, so one address can use the whole cap. The
dashboard listener has no cap.

**Workaround.** Put a reverse proxy or a firewall in front of the node: it
enforces header and body deadlines and per-address limits (nginx
`client_header_timeout`, `limit_conn`; `nft meter`). Keep the dashboard on
loopback.

**Evidence.** [design.md §7.1](design.md#71-http);
`test/atanor/http_ingress_test.exs` (the cap and the read timeout hold).


## A handler can run on two nodes at once around a takeover

**What happens.** A handler that started on a node before it lost a cell (a
takeover, a false positive, a move) runs to the end, and the new owner starts
others for the cell meanwhile. Alambique's fencing keeps every cell write correct:
the old handler's write is refused or goes to the new owner. Effects outside the
cell, such as outbound HTTP, e-mail or a message to a socket, can happen twice.
Atanor starts no new handler on a cell this node lost later than
`routing.owner_check_ms` (1 s by default) after the takeover. A job or alarm
handler is killed when the lease of its node on the cell ends (minus the skew
margin), or at once when a read shows the cell lost. Request, WebSocket and TCP
handlers are not interrupted. After an early takeover the new owner starts no job
or alarm handler until the old lease has ended plus the margin
(`routing.fence_defer_after_takeover`, default true), so those do not overlap
while clock skew stays below the margin. With the option off the overlap is
bounded by the lease the old owner has left. The deferral is in memory: a new
owner that restarts within it forgets it.

**Workaround.** Make effects outside the cell idempotent (an idempotency key the
receiver checks), or do them from a cell job
([design.md §15](design.md#15-jobs-per-cell-and-bulk-operations)), which runs on
the current owner and carries a stable job id.

**Evidence.** [design.md §8.13](design.md#813-a-handler-that-outlives-its-cell),
[§8.2](design.md#82-running-the-call-there); the C1 property and
`test/cluster/takeover_test.exs`.


## Cron has no time zones

**What happens.** Recurring jobs use five-field cron expressions evaluated in
UTC. A schedule such as `0 3 * * *` runs at 03:00 UTC, not in the operator's
local time, and there is no daylight-saving handling.

**Workaround.** Write the expression in UTC, or enqueue a one-off job with an
explicit `scheduled_at_ms`. A time-zone option would need a tz database, which
is not a dependency today.

**Evidence.** [design.md §15.4](design.md#154-execution-retries-cron-and-timeouts),
`test/atanor/jobs_test.exs`.

## A lost owner's cells wait for the detector, and without a majority for the lease

**What happens.** When a node is lost, the requests for its cells get 503
`{"error": "unavailable", "reason": "owner_unreachable"}` (or `owner_down` once
the detector confirms it) until the detector confirms it down (about 5 s for a
lost machine with the defaults, milliseconds for a killed process, a graceful
stop or a platform hint). Then the first request for each cell takes it over
([design.md §8.10](design.md#810-acting-on-a-confirmed-failure)). The cell waits
for the lease (30 s by default, `lease_ttl_ms`) instead when:

* the failure is not detected (the detector settings are too slack, or the
  failure is a slow node that never goes silent);
* this node and the peers it reaches are not a majority of the nodes it knows
  (`takeover.quorum`): a node cut off from the others, any survivor of a two-node
  cluster after a silent failure, and both halves of an even split. A platform
  hint or a graceful stop takes the peer out of the count, so those survive a
  two-node cluster; otherwise set `takeover: [quorum: false]` knowingly;
* the peer is only `link_broken`: it is alive and keeps its cells;
* `takeover: [enabled: false]`.

**Workaround.** Give clients a timeout and retries for 503 `unavailable`, which
means the call did not run. Run three or more nodes. Shorten `lease_ttl_ms` when
quicker takeover without a majority is worth more lease renewals.

**Evidence.** [design.md §12.7](design.md#127-failure-detection) and
[§12.8](design.md#128-detection-and-takeover-in-the-lab):
`test/cluster/takeover_test.exs` ("a node cut off from the others is a minority
and takes nothing").

## A partitioned node fails its requests for a few seconds

**What happens.** When a node is cut off from its peers but not from the store,
it keeps its leases until the peers declare it down (about 5 s) and take its
cells (about 6 s after the cut in the lab). During that time requests that need
the cut wait or fail. The isolated node declares its peers down, is a minority,
and takes nothing: its workers' cell calls for cells owned elsewhere fail at once
with 503 `unavailable`, reason `no_quorum` (the runtime maps the error even when
the worker answers 500), where before the detector they waited for the client's
timeout.

**Workaround.** A client timeout, and a load balancer that stops sending to a
node that is not in the majority (`/nodes` shows what it sees).

**Evidence.** `test/cluster/takeover_test.exs`.

## The detector cannot tell a cut from a death in a cluster of two

**What happens.** With no third node to ask, two nodes that lose each other
declare each other down, disconnect and each go on serving the cells it
holds. Nothing is corrupted, because leases are fenced by their epoch. Neither
takes the other's cells early, because one of two nodes is not a majority
(`takeover.quorum`), so a really dead peer's cells wait for the lease.

**Workaround.** Run three nodes, or set `detector: [indirect: [k: 0]]` and
`takeover: [quorum: false]` knowingly: then each side of a cut takes the
other's cells as requests arrive, and a cell that both sides use changes owner
at every request (safe, but slow). **Evidence.**
[design.md §8.8](design.md#88-indirect-probes-and-states) and
[§8.10](design.md#810-acting-on-a-confirmed-failure).

## A request that may have run is not repeated

**What happens.** When the connection to the node that was running a `POST`, a
TCP chunk or a WebSocket frame fails after the callback started, Atanor cannot
know whether the effect happened and answers 503 `{"error": "unknown_outcome", "reason": "unknown_outcome"}`
(HTTP) or closes the connection. An HTTP `GET`, `HEAD`, `OPTIONS` or an alarm
is repeated instead.

**Workaround.** Give the client a way to ask (an idempotency key stored in the
cell, or a read of the state) before it repeats a write.

**Evidence.** `test/cluster/routing_test.exs`, "a request that may have run is
not run again".

## WASM workers do not serve TCP, TLS or STARTTLS

**What happens.** WASM workers have no `handle_tcp/3` and no
`ranch_protocol/1`. A `tcp` route in a WASM manifest is refused with
`{:unsupported_for_wasm, :tcp}`. Implicit TLS and STARTTLS are properties of a
TCP listener the worker serves, so a guest cannot use them either: the host
never intercepts a guest socket to upgrade it.

**Workaround.** Keep the TCP/TLS edge in a native worker and call the WASM
worker from it with `Atanor.Env.call/3` (for example for parsing or a cell
write), or terminate TLS in a proxy in front of an HTTP route.

**Evidence.** [design.md §3.2](design.md#32-wasm-workers) and
[§7.3](design.md#73-tcp-and-websockets); `test/atanor/tcp_test.exs` ("WASM
manifests cannot claim listeners yet").

## WASM workers cannot read the change feed

**What happens.** `Atanor.Env.changes/4`, `Atanor.Env.feed_position/2` and
`Atanor.Env.subscribe/3` are native-only. The WIT packages in `wit/` have no
change feed import, so a WASM component cannot read changes directly and its
manifest cannot grant them.

**Workaround.** Keep the subscription in a native worker and call the WASM
worker with `Atanor.Env.call/3`, or query a cell from the guest on a timer. A
native worker can also maintain the cache and pass the result to the guest.

**Evidence.** [design.md §16](design.md#16-the-change-feed-for-workers),
`wit/`, `test/atanor/feed_test.exs`.

## Plug and WASM workers do not run on the owner of the cell

**What happens.** A Plug worker has no routing key and runs on the node that
received the request, as do WASM workers, which have no routing key. Their cell calls
are still routed to the owner by Alambique, so they are correct, but they pay
one network hop per call instead of one per request.

**Workaround.** Use `handle_request/2` in a native worker for latency-sensitive
paths.

**Evidence.** [design.md §8.5](design.md#85-tcp-websockets-alarms).

## A forwarded request needs the node to be able to build its deployment

**What happens.** A forwarded request runs on the deployment the ingress node
pinned. A node that does not have it fetches and builds the package; for a
native worker whose code it does not have (the release was not rolled to it)
that is `{:code_mismatch, ...}` and the request is 503 `unavailable`, in both
directions, while the two versions run side by side.

**Workaround.** Roll the release to every node before the deployment switch, as
[how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) says.

**Evidence.** [design.md §8.3](design.md#83-one-deployment-across-nodes-d1).

## A bounded read can be older than the last write, and a replica is a full copy

**What happens.** A `consistency: {:bounded, ms}` read
([design.md §19](design.md#19-reading-a-hot-cell-from-other-nodes)) can miss writes
acknowledged less than `ms` before it, and two reads of one caller, one served by
a replica and one by the owner, can see time go back by up to the bound. A
replica downloads the whole database before it serves, so the first bounded
reads of a node go to the owner, and each node that reads the cell keeps a full
copy (at most `max_bytes` of Alambique's `replicas:` per node, 1 GiB by default).
A request whose `route_key/2` declares a bound runs on the node that received it
and cannot write; only HTTP requests of native workers can be bounded (WebSocket
frames, TCP chunks, jobs and alarms run on the owner). The owner of a cell that
Atanor switched on moves it to another node: the marker stays on in the store
and the new owner decides again, so a cell that cooled down meanwhile keeps its
marker until somebody turns it off (`Atanor.Cell.replicas/3`).

**Workaround.** Use `:strong` (or `verify_lease: true`) for reads that must not go
back in time, keep replicas for cells that fit `max_bytes`, and turn a stale
marker off by hand.

**Evidence.** Alambique's `docs/what-does-not-work.md` and
`test/replica_properties_test.exs`; Atanor's
`test/cluster/replica_bound_property_test.exs`.

## A cell can run old schema until its owner applies a new worker version

**What happens.** A node hibernates its own awake cells of a namespace when it
applies a worker with more migrations for it, so the cells wake migrated. Until
the node that owns a cell has applied the head (seconds, set by the poll
interval), a request that reaches it on the new version, from a node that
applied first, runs against the old schema and can fail (`no such column`).

**Workaround.** Roll out additive migrations (design §4.1) and code that
tolerates the old schema for the seconds a rollout takes.

**Evidence.** [design.md §4.1](design.md#41-cells-and-schemas); the cluster
test "its cells wake migrated on the node that owns them" in
`test/cluster/routing_test.exs`.

## Nodes are connected by the operator

**What happens.** Atanor does not find other nodes. Nodes that are not
connected each serve the cells they can lease, and two partitions lease different
cells until they meet again; Alambique's fencing keeps each cell's data safe.

**Workaround.** Connect the nodes with a cluster library, `Node.connect/1` or
`mix atanor.dev --connect`.

**Evidence.** [how-to-run-a-cluster.md](how-to-run-a-cluster.md).

## Cluster behavior was measured on one machine

**What happens.** The cluster lab ([how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md))
runs three nodes and SeaweedFS in VMs, but all on one host, on one virtual
network. Latency and loss are injected, not measured on a real network; the
store is one SeaweedFS process, not a replicated bucket; and the clocks are
the host's, moved by hand.

**Workaround.** Run the lab scenarios on your own machines and network before
sizing.

**Evidence.** The scenarios of the cluster lab ([how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md)).

## A crash report does not survive a machine that never returns

**What happens.** Atanor writes a breadcrumb file for each durable unit (job,
alarm, sweep page, migration, deployment activation, WebSocket) into
`data_dir/diagnostics/units/`. The file is not fsynced: a VM crash keeps the
page cache and the next start reports it, but a whole-machine crash or a lost
disk may lose it. A node that never restarts writes no report. Alambique's
own quarantine has the same page-cache limit and is shown in the report when
its counter is readable.

**Workaround.** Treat `/crashes` as a best-effort record, not an audit log.
Keep the OS core and `erl_crash.dump` as described in
[how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md), and use
`mix alambique.inspect` for the cell's stored crash counter.

**Evidence.** [design.md §17.2](design.md#172-crash-diagnostics),
`test/cluster/diagnostics_test.exs`.

## `:durable` breadcrumbs do not cover HTTP requests

**What happens.** The default `diagnostics.breadcrumbs: :durable` records
jobs, alarms, sweep pages, migrations, deployment activation and WebSocket
connections. It does not record HTTP or TCP callbacks, native or WASM, so a
crash in an ordinary HTTP request may name only the cell (from Alambique) or
nothing. `:all` records every callback, at the cost of one marker file per
request; the measured cost is in design §12.

**Workaround.** Use `diagnostics: [breadcrumbs: :all]` while reproducing an
HTTP crash, then return to `:durable`. A WASM job or alarm is still covered by
its job/alarm unit.

**Evidence.** [design.md §17.2](design.md#172-crash-diagnostics),
`test/atanor/diagnostics_test.exs`.

## A crash with no Atanor unit writes no `/crashes` report

**What happens.** The Atanor crash report is built from breadcrumbs of
durable units (a job, alarm, sweep page, migration, deployment activation or
WebSocket). A VM crash inside a cell wake, a restore, a compaction or a
queries-only cell call has no such unit; Alambique still records the cell in
its quarantine counter and `[:alambique, :cell, :crash_recorded]`, but Atanor
does not know the cell list to enrich, so `/crashes` stays empty for that
death.

**Workaround.** Use `mix alambique.inspect CELL` for the stored crash counter
and the quarantine events in the node log. The next job, alarm or other
durable unit that touches the cell produces a report.

**Evidence.** [design.md §17.2](design.md#172-crash-diagnostics),
`test/cluster/diagnostics_test.exs`.

## A migration rehearsal checks a sample, and a killed one is not resumed

**What happens.** A rehearsal applies the migrations to `sample_size` cells
per namespace (10 by default, 100 in total), not to every cell, so a cell with
unusual data can still fail when the package is activated. The sample comes
from Alambique's schema index: a cell that has not woken since the index
exists is never listed, and a cell created after the listing is missed. The
copies are restored from the store, so writes a live cell has not uploaded yet
are not in them. The rehearsal runs on one node; if that node dies, the record
stays `running` and reads as `stale` after `rehearsal.stale_ms` (10 minutes by
default), and no other node resumes it.

**Workaround.** Raise `sample_size` and `max_cells` on the node for a package
that changes a lot, rehearse again with another `seed`, and start a new
rehearsal after a `stale` one. A migration that cannot be undone still needs a
backup or Alambique's point-in-time restore.

**Evidence.** [design.md §17.3](design.md#173-migration-rehearsal),
`test/atanor/rehearsal_test.exs`, `test/cluster/rehearsal_test.exs`.

## A WASM guest can hold pool threads while it waits

**What happens.** A guest keeps its pool thread for the whole call, also while
it sleeps (`wasi:clocks` and `poll`), waits for a slow host call or waits for a
nested worker call. CPU limits do not fire during a wait, so guests that wait
for `timeout_ms` (30 s by default) can occupy all `threads` and every other WASM
worker then gets `:overloaded` after `queue_wait_ms`. Nested calls hold the
caller's thread while the callee needs another one. Outbound HTTP now ends with
the call's deadline, but the wait is still a held thread.

**Workaround.** Lower `limits.timeout_ms` and the node's `max_timeout_ms`, and
raise `threads`. Deploy only packages you trust: the manifest author is
trusted code (design §3.2).

**Evidence.** Review finding WASM-5 (read from the sources, not measured).
Not fixed because a per-worker cap and running a callee on its caller's slot
change how the queue admits calls and need their own design and measurement.

## The compiled-code cache is checked, not authenticated

**What happens.** `<data_dir>/wasm/*.cwasm` files carry a SHA-256 of their
content, which detects damage but not tampering. Whoever can write that
directory can have the node load native code of their choosing. Compiled
components are not evicted while the instance runs.

**Workaround.** Keep the data directory writable only by the node's user (it
also holds the cells, which have the same trust), and restart nodes that
deploy many distinct packages.

**Evidence.** Review finding WASM-11 (read from `component.rs`). Not fixed
because authenticating the files needs a per-node key kept outside the data
directory, which Atanor does not manage yet.

## A late feed batch can be read behind a later one

**What happens.** Alambique orders the first occurrence of each idempotency key
of a cell by commit order. After a late publication, a batch that was stamped
before it but arrives after it can get a key that sorts before the late one.
Observed with `window_ms: 1`, where every batch is late: in 3 of 10 runs of 40
cells with 16 inserts each, a cell read TXIDs 3, 5, 6, 7, 4, 8.

**Workaround.** A consumer that needs the commit order sorts the changes of a
cell by `txid` ([how-to-follow-cell-changes.md](how-to-follow-cell-changes.md)).
The feed tests of Atanor keep their window above the publication time.

**Evidence.** `test/atanor/feed_test.exs`. Not fixed in Atanor: the key time is
chosen by Alambique's feed sender.
