# Atanor design

This page is for contributors. It describes the current model, the processes, the storage layout and the
guarantees. Section numbers are stable references: code comments cite them as "design §N.M".

## 1. Model

Atanor runs **workers** and their **cells** on a cluster of BEAM nodes.

| Concept | Meaning |
| --- | --- |
| Worker | Named unit of code that handles requests. Stateless by itself. |
| Cell | Named stateful unit with its own SQLite, provided by `alambique`. |
| Binding | A capability granted to a worker by its manifest. |
| Deployment | Immutable version of a worker, identified by the SHA-256 of its package. |
| Route | Maps traffic to a worker: an HTTP host and path prefix, or a TCP port. |

## 2. Processes on a node

```
Atanor.Supervisor
├── Atanor.Registry             ETS: config, node state, active deployments, routes, namespaces
├── <name>.Tasks                Task.Supervisor: migrations of awake cells, rehearsals
├── Atanor.Wasm.Cache           compiled components by package hash
├── Alambique instance          <name>.Cells (default Atanor.Cells), started with join: false
├── Atanor.Diagnostics          crash breadcrumbs and reports (§17.2)
├── Atanor.Drain                hands the cells off when the instance stops (§8.11)
├── Atanor.Detector             failure detector (§8.7)
├── Atanor.Admin                Bandit admin API, loopback by default; 503 until the node is ready
├── Atanor.Deployments.Watcher  loads the store heads, then polls and applies switches (§2.1)
├── Atanor.Jobs.Slots           per-node job concurrency slots (§15.5)
├── Atanor.Jobs.Drain           waits for local job tasks on a graceful stop
├── Atanor.Sweeps.Supervisor    drivers of bulk operations (§15.6)
├── Atanor.Sweeps.Manager       leases and starts those drivers
├── Atanor.Feed.Supervisor      starts one change feed tailer per instance, lazily (§16)
├── Atanor.Alarms.Scheduler     scans the alarm index shards this node owns
├── ready                       joins the cluster, then sets the node state to :ready (§2.1)
├── Atanor.TCP.TLS              TLS material and its reloadable cache, one entry per TLS listener
├── Atanor.TCP                  TCP listeners (ThousandIsland or Ranch), one per listener a deployment claims
├── Atanor.HTTP                 Bandit: HTTP and WebSocket ingress
└── Atanor.Dashboard.Supervisor only with the dashboard: option and its optional deps (§10.3)
```

Every request, connection, frame and alarm reaches a worker via `Atanor.Dispatch` (§7.2).

### 2.1 Starting: deployments first, then the cluster

Alambique starts with `join: false`. The `ready` task calls `Alambique.join/1` later.

1. The registry and admin listener start. `/health/ready` answers 503 `starting` until ready.
2. The watcher applies every worker head in `init/1`. A head that cannot be built
   is recorded in `Atanor.Deployments.status/1`. Store errors retry every
   `ready.retry_ms` (1 000); after `ready.timeout_ms` (60 000) the instance does not start.
3. `ready` joins the cluster and sets the node state to `:ready`. Then the TCP
   listeners and the HTTP ingress open.

## 3. Workers

A worker has a **manifest** (`atanor.json`), read by `Atanor.Manifest`.

* `manifest_version` must be `1`. Unknown keys are errors at every level.
* `kind` is `native` (with `module`) or `wasm` (with `component`).
* A route is active only when the operator allows it.

### 3.1 Native workers

Trusted Elixir code implementing `Atanor.Worker`, compiled into the release.
The module's MD5 must match the package, else `{:code_mismatch, expected, loaded}`.

### 3.2 WASM workers

A component implements `wasi:http/incoming-handler`, runs in Wasmtime behind
`Atanor.Wasm`, and sees only the imports its bindings grant. `Atanor.Wasm.build/2`
rejects at activation any import the manifest does not grant. Compiled components
are cached in `<data_dir>/wasm/`, HMAC-SHA256 keyed by `<data_dir>/wasm.key`.

### 3.3 What a manifest may grant

Another worker's resources need that side's consent, in its manifest or the
operator's config, never only the caller's manifest.

| Grant | Consent | Error |
| --- | --- | --- |
| Cell namespace | The owner, recorded at `owners/<namespace>`; the operator's `namespaces:` overrides it | `{:namespace_owned, ns, owner}` |
| Calling a worker | `callable_by` in the callee's manifest, or `callers:` | `{:not_granted, {:worker, callee}}` |
| HTTP routes | The operator's `hosts:` | `{:host_not_allowed, host, worker}` |
| TCP listener | The listener's `workers:` | `{:listener_not_allowed, listener, worker}` |
| Outbound hosts | The operator's `http_allow:` | `{:http_not_allowed, host, worker}` |
| Native module | The operator's `modules:` | `{:module_not_allowed, module, worker}` |

Owner records are conditional writes, so nodes agree whatever order they apply
heads in. Limits: see known-limitations.md.

## 4. Bindings

A binding is granted by the manifest. Native workers and WASM components use only
granted bindings; anything else fails with `{:error, {:not_granted, binding}}`.
Bindings: `cells.<namespace>` (`query`, `execute`, `transaction`, `changes`,
`subscribe`), `alarms`, `jobs`, `sockets`, `http.allow`, `workers` and `secrets`.
Denied forms are `{:cell, namespace}`, `{:secret, name}`, `{:http, host}`,
`{:worker, name}`, `:alarms` and `:sockets`.

- **Outbound HTTP.** `fetch(env, request)` through Req, default deny. `Atanor.Egress`
  refuses a host that resolves to a private, loopback, link-local, multicast,
  unspecified, documentation or reserved address (`{:private_address, host, ip}`),
  unless `allow_private_hosts` permits it. The request connects to the checked address.
- `http.allow` entries: `host`, `host:port`, `scheme://host`, `scheme://host:port`,
  or `*.domain` (never the apex). Redirects: at most 5, each hop checked.
- **Secrets.** `secret(env, name)` reads manifest names only, from the operator's `secrets:` option.
- **Worker calls.** `call(env, worker, request)` runs the callee's `handle_request/2`
  on the same node. The env pins each reachable worker's active deployment at
  ingress, so one request reaches one version. Depth limit 8.
- **WASM.** Each import is linked only when granted: `atanor:cell/sql@0.1.0`,
  `atanor:cell/alarms@0.1.0`, `atanor:cell/jobs@0.1.0`, `atanor:cell/sockets@0.1.0`,
  `atanor:config/secrets@0.1.0`, `atanor:worker/call@0.1.0`, and
  `wasi:http/outgoing-handler`. `batch` is one transaction; there are no interactive transactions.

### 4.1 Cells and schemas

A cell is addressed by `{namespace, key}`, with Alambique id `<namespace>.<key>`.
A namespace belongs to one worker unless the operator shares it (§3.3). Migrations
come from the manifest and run at wake, through `Atanor.Migrations.for_cell/2`.
Workers that grant one namespace must list identical migrations, and a shrinking list
is refused. A cell up to `:migration_window` versions ahead (default 1) is served.
Activation migrates awake cells in the background; asleep cells migrate at wake.
Limits: see known-limitations.md. Telemetry: [telemetry.md](telemetry.md).

### 4.2 Partitioned cells

A namespace with `"partitions": n` (2 to 1024) in its cell binding maps each logical
cell to `n` physical cells. Partition `i` is `{namespace, "<i>.<key>"}`. The index is
the first 8 bytes of the SHA-256 of the partition key, as an unsigned big-endian
integer, modulo `n`. Only physical keys are valid in such a namespace. A native
`route_key/2` may return `{:cell, ns, key, partition_key}`. `n` is fixed while data
exists; activation refuses a change with HTTP 409. Transactions stay in one physical
cell. Limits: see known-limitations.md.
Guide: [how-to-partition-a-cell.md](how-to-partition-a-cell.md).

### 4.3 Limits on cell calls and their errors

Atanor passes `alambique:` options through; an unknown key or a wrong value raises
`ArgumentError` at start. Defaults: `sql: [statement_timeout_ms:]` 10 000,
`sql: [max_result_rows:]` 100 000, `sql: [max_result_bytes:]` 64 MiB,
`awake: [max_cells:]` 20 000, `awake: [max_pending:]` 10 000, `awake: [cache_kib:]` 512,
`awake: [idle_cache_after_ms:]` `nil` (off; below `idle_timeout_ms` when set), `awake: [idle_cache_kib:]` 64
(below `cache_kib`), `awake: [idle_gc:]` `true`, `idle_timeout_ms` 300 000. `max_wakes` and `max_bytes` are derived from the memory limit.
`feed: false` is refused.

Memory: idle cells hibernate from 0.75 of the limit (`hibernate_fraction`); the ingress
refuses with 503 `overloaded` at 0.85 (`refuse_fraction`). Wakes beyond `max_wakes`
wait up to 500 ms, then get `{:error, :overloaded}`.

A native call gets Alambique's error unchanged; a WASM guest gets `failed("<code>: <text>")`.
`:overloaded` and `:busy` mean the call did not run; the ingress answers 503 with `Retry-After`.

The cookie grants code execution on every node. Keep distribution on a private network
or use TLS distribution, and set `RELEASE_COOKIE` in the environment, never in arguments.
See [how-to-run-a-cluster.md](how-to-run-a-cluster.md).

### 4.4 The disk budget

`disk: [max_bytes:]` bounds `data_dir`. Unset, it is `disk: [fraction:]` (0.8) of the
file system that holds `data_dir`, read with `df -Pk`; without a readable size, no
budget applies. The WAL checkpoint, the WAL allowance and the local cache derive from
the budget and `awake: [max_cells:]`.

`Atanor.Disk` sums `data_dir` every `disk: [sample_ms:]` (5 000). At 0.7 of the budget
it hibernates up to 64 idle cells per round; at 0.95 the ingress answers 503
`overloaded`. `SQLITE_FULL` becomes `{:error, :disk_full}`, also a 503.

## 5. Deployments and the store layout

Atanor keeps its metadata in the `Alambique.Store` behind `store:`, under the operator's `prefix:` (default `atanor`); cells live under `<prefix>/cells`. Prefixes that share a store must not be path prefixes of each other. With a `placement:`, `meta_store:` holds the rest.

| Key | Content |
| --- | --- |
| `<prefix>/packages/<sha256>` | package bytes, written once with `If-None-Match: *` |
| `<prefix>/owners/<namespace>` | the worker that owns a cell namespace, written once (§3.3) |
| `<prefix>/workers/<name>/head` | the head: active id, previous ids, revision; replaced with `If-Match` |
| `<prefix>/alarms/<minute>/<at_ms>/<shard>/<worker>/<cell-id>` | alarm and job index entries, empty objects (§7.4) |
| `<prefix>/meta/alarms/shards` | the alarm shard count, written on the first start |
| `<prefix>/operations/<id>` | one bulk-operation record and cursor (§15.6) |
| `<prefix>/crashes/<node>/<id>` | one crash report (§17.2) |
| `<prefix>/rehearsals/<id>` | one migration rehearsal record and report (§17.3) |
| `<prefix>/jobs/dead/<cell-id>/<job-id>` | dead-letter index entries (§15.4) |
| `<prefix>/versions/<worker>/id/<package id>`, `.../log/<unix microseconds>-<package id>` | version index: a guard object and a log entry per uploaded package (§10.2.1) |
| `<prefix>/audit/<time>-<random>` | one audit entry of the admin API (§10.2.1) |
| `<prefix>/tokens/<id>` | one scoped admin token: scopes, expiry, revocation, SHA-256 of its secret (§10.2.1) |
| `<prefix>/cells/...` | alambique, with `store:` (a placement decides its own layout) |

Listings of worker heads page with `metadata.page_size` (1,000 by default).

### 5.1 Packages

`Atanor.Package.build/2` makes deterministic bytes in Atanor's own format: the magic `"ATANORPKG1\n"`, then entries sorted by name, each `<<name_size::16, name, data_size::64, data>>`. Entries are `atanor.json` (canonical manifest, defaults filled in), then `module.md5` (native: hex MD5 of `module_info(:md5)`) or the file named by `component` (WASM). There are no timestamps, modes or owners.
The package id is the SHA-256 (hex) of the bytes. `Package.parse/2` accepts only what `build/2` produces, and refuses an `atanor.json` over `max_manifest_bytes` (262,144) or a component over `max_component_bytes` (8,388,608) before decoding them.

### 5.2 Heads

A head is JSON: `worker`, `active` (an id or `null`), `previous` (newest first), `revision` and `updated_at`. `Atanor.Deployments` works on any `Alambique.Store`:
* `publish(store, package)` writes a package once; `activate(store, worker, id)` checks that it is in the store and belongs to the worker. The old active id goes first in `previous`, which keeps at most 20 (`:deployments` option `max_previous`). Activating the active id changes nothing.
* `rollback(store, worker)` makes the newest previous id active, or returns `{:error, :no_previous}`; `deactivate(store, worker)` sets `active` to `null` and keeps the history. `head/2`, `list/1` and `workers/1` inspect heads.
Each change writes with `If-Match` on the etag it read, and retries on `:precondition_failed` up to 16 times before `{:error, :conflict}`. Other write errors are returned as they are.

### 5.3 Propagation

Each node runs `Atanor.Deployments.Watcher`. It loads all heads before the HTTP ingress opens, reloads them every `:poll_interval_ms` (default 5000), and listens on the `:pg` group `{Atanor.Deployments, prefix}`. An activation through a running instance (`Deployments.activate(MyApp.Atanor, ...)`, as the admin API does) sends `{:head_changed, worker}` to the group; a change made through a store handle reaches nodes at their next poll.
Applying a head fetches the package, verifies its hash and activates it through `Atanor.Workers.activate/2`. A head that fails leaves the previous deployment serving and is reported by `Atanor.Deployments.status/1` as `%{head:, applied:, error:}`. It is not retried until it changes, except store errors and `{:module_not_loaded, name}`, which are retried at the next poll.

### 5.4 Commands

The `atanor` command (`Atanor.CLI`, [cli.md](cli.md)) is a client of the admin API (§10.2.1): `login`, `logout`, `deploy`, `activate`, `rollback`, `status`, `versions` and `token`. Deployers hold an admin URL and a scoped token, never bucket credentials. It is an escript that needs only Erlang and keeps its profiles in `$XDG_CONFIG_HOME/atanor/config.json` (mode 0600).
`deploy --bucket s3://bucket/prefix` calls `Atanor.Deployments.Service.deploy/4`, the function the admin API calls, and needs no node; nodes apply the head at their next poll. It excludes `--url`, `--profile` and `--timeout`, and refuses native workers, since `Service.upload/5` checks that a node holds the module.
`deploy` builds the package with `Atanor.Package.from_project/3`; a native package holds the MD5 read from the module's `.beam` file. The node checks the size limit, hash and manifest before it stores anything.
**Guarantee D1.** A request resolves its deployment once, at ingress, and keeps it to the end, even when forwarded to another node. A switch affects only requests that start after the node applied it.

## 6. Local development

See [how-to-build-and-test.md](how-to-build-and-test.md) for the local dev node and the test setup.

## 7. Ingress and routing

### 7.1 HTTP

Routes match by host, then by longest path prefix over whole segments: the exact host, then wildcard hosts (`*.a.test` before `*.test`), then the catch-all `*`. The first host with a matching route decides. The route's deployment is read once and travels in the env (D1).
`hosts:` maps each worker to the host patterns it may claim (exact hosts, `*.domain`, or `*`); without it every host is allowed. A manifest route outside those patterns fails with `{:host_not_allowed, host, worker}`.
Routing sees one canonical request (`Atanor.Route`): a lower-case host without the trailing dot, and unreserved percent-escapes decoded. More than `http.max_path_segments` (64) segments, a host over 253 bytes or with more than `http.max_host_labels` (16) labels, or a bad escape is 400 `bad_request`.
*Admission* (`Atanor.Admission`) answers 503 `overloaded` with `Retry-After` when the disk gate (0.95 of the disk budget), the memory gate (0.85 of the cgroup limit) or the in-flight gate (`http.max_in_flight`, 1,024) refuses. Each admitted request has a `http.queue_wait_ms` (5,000) deadline. Limits: see [known-limitations.md](known-limitations.md).

### 7.2 Routing keys and dispatch

`Atanor.Dispatch` is the one path to a worker. `route_key(input, env)` returns `{:cell, namespace, key}` (or the four-element form for a partitioned namespace) or `:none`; a namespace the manifest does not grant, or a key invalid for the cell id, fails the work with 500.
`execute(env, cell, call)` runs one callback (`{:http, request}`, `{:tcp_data, data, state}`, `{:ws_in, message, state}`, `{:alarm, cell, payload}` and others) on the node that owns the cell (§8). WASM deployments have no routing key; `Atanor.Wasm.execute/2` runs their handlers, each in a fresh instance. `Env.call/3` between workers stays on the node.

### 7.3 TCP and WebSockets

`listeners:` maps names to ports (0 picks a free one). The long form adds `protocol` (`:thousand_island`, the default, or `:ranch`), `tls_mode` (`:implicit` or `:starttls`), `tls:`, `acceptors`, `max_connections`, `ip` and `workers:`. A listener runs while an active deployment has a matching `tcp` route.
A ThousandIsland worker exports `tcp_init(info, env)` and `handle_tcp(data, state, env)`; `route_key({:tcp, state}, env)` binds the connection to its first cell. A connection keeps the deployment it was accepted with. Limits (`tcp:`): `idle_timeout_ms` (60,000), `max_chunk_bytes` (65,536), `max_connections` (16,384).
WebSockets run `ws_init(request, env)`, then `handle_ws/3`; attached sockets (`Env.attach/2`) receive `Env.send_to_cell/3`. Limits (`websocket:`): `idle_timeout_ms` (60,000), `max_frame_bytes` (1,000,000), `max_frames_per_s` (100) with `frame_burst` (200); `permessage-deflate` is off. A TLS certificate is reloaded without restart: a watcher checks the files every `tls: :reload_ms` (5,000) and swaps them in when they load.

### 7.4 Alarms

`Env.set_alarm(env, {ns, key}, at_ms, payload)` gives a cell one alarm, replacing any earlier one; `cancel_alarm/2` removes it. Both need `alarms: true` and the namespace granted. The cell's `_atanor_alarms` row is authoritative.
The store index holds one empty object per pending alarm, at `alarms/<minute>/<at_ms>/<shard>/<worker>/<cell-id>` (`minute` is `at_ms / 60000` padded to 10 digits, `at_ms` padded to 15, `shard` the cell id hash modulo 64). Each node lists it every `tick_ms` (1,000) and fires the shards it owns.
Firing is at least once: the scheduler claims the row with a conditional update, then runs `handle_alarm({ns, key}, payload, env)` on the cell's owner, bounded by `timeout_ms` (30,000). A failed handler is retried with backoff (1 s, doubling to 60 s) up to `max_attempts` (5), so handlers must be idempotent. Jobs use the reserved row `@jobs` (§15.3).

### 7.5 Bearer tokens on a route

`auth:` in the operator's `{Atanor, opts}` (never the manifest) lists rules with `host`, `path`, `issuer` (https unless `oidc: [allow_http: true]`), `audience`, `scopes`, `types`, `algorithms` (default `["RS256"]`), `leeway_s` (60) and `realm`. The most specific matching rule applies, to WebSockets and Plug workers too. Set `types` to the token type the provider issues: its default accepts any `typ`.
Rejections never reach the worker: no credentials is 401 with `WWW-Authenticate: Bearer`; a malformed header is 400 `invalid_request`; a bad token is 401 `invalid_token`; missing scopes are 403 `insufficient_scope`. Tokens and claims are not logged.
Keys come from `<issuer>/.well-known/openid-configuration` and are cached; an unknown `kid` refreshes the JWKS at most once per 60 s per issuer. Only asymmetric algorithms exist, and there is no introspection.
Verified claims reach workers as base64url JSON in the `x-atanor-claims` header (`Atanor.Request.claims/1`); the ingress strips any client copy. See [how-to-protect-a-route-with-oidc.md](how-to-protect-a-route-with-oidc.md).

### 7.6 Ephemeral channels

A cell's ephemeral channel delivers messages to the sockets joined to it on any node. Nothing is stored or retried, so delivery is at most once; a publish sends one message per remote node that has members. Membership is the `:pg` group `{Atanor.Channels, prefix, namespace, key}`. How to use it: [how-to-share-ephemeral-messages.md](how-to-share-ephemeral-messages.md).
Order holds per publisher process. `Env.channel_members/2` reads membership when asked, and fails with `{:error, :node_unreachable}` if a node does not answer within `sockets.attach_timeout_ms`.
An optional `handle_ws_local({:text | :binary, data}, state, env)` runs in the socket's process before the frame reaches the owner; it returns `:pass` or `:drop` and may call `Env.publish/3`. Its env has `local: true` and no cell access.
Limits (`channels:`): `max_message_bytes` (16,384), `max_subscriptions` (16), `max_channels` (10,000), `max_channels_per_namespace` (2,000), `max_queue` (1,000); a member over `max_queue` misses that message. Telemetry: `[:atanor, :channel, :publish]`, `[:atanor, :channel, :rejected]`, `[:atanor, :channel, :dropped]` ([telemetry.md](telemetry.md)).

## 8. Cluster

Nodes run an instance with the same `name`, `prefix` and placement over the same store. They find each other through the store ([§8.16](#816-discovery-through-the-store)), or the operator connects them (`Node.connect/1`, a cluster library, or `mix atanor.dev --connect`). Alambique forwards a cell call to the cell's owner, and Atanor runs the worker callback on the owner, so the owner's cell calls are local ([how-to-run-a-cluster.md](how-to-run-a-cluster.md)).

### 8.1 Finding the owner

`Dispatch.execute(env, cell, call)` with a cell and at least one connected node asks `Alambique.owner(instance, cell, hint: true)`. A sleeping cell (`:none`) is woken by `Atanor.Cell.owner/2` through `Alambique.touch/3` on the preferred node (rendezvous hashing). A lease held by a lost node gives `{:error, {:unavailable, owner, expires_at_ms}}`, and a retry drops a hint to a gone node before it calls `touch`.
`Atanor.Rebalance` (on by default, `rebalance: [...]`) moves awake cells to their preferred node after a join. Each node moves its own cells, `start_delay_ms` (30 s) after a membership change, coldest first, at most `max_moves_per_s` (5, capped at 20) a second, with `Atanor.HotCells.move/4` and `only_if_idle`.
A plan hands each cell out once while the membership stays, skips `Atanor.HotCells.pinned/1` cells, and shares the cooldown and cap of the hot-cell loop, which takes precedence. A busy cell answers `{:error, :busy}` and waits for a later round.

### 8.2 Running the call there

The call goes through `:erpc` to `Dispatch.remote/9` with plain data only: instance, worker name, deployment id, socket pid, nested-call depth, cell, call and a reference. The remote node checks that it owns the cell (`Alambique.owner/2`), or answers `{:moved, node}` and runs nothing. It resolves the deployment by id (§8.3), or answers `{:rejected, reason}`. It sends the caller `{:atanor_started, ref}`, runs the callback as a local call and answers `{:executed, result}`.
The owner check and the start are not atomic. Alambique's fencing stops cell effects on a node without the lease, but effects outside the cell can still happen (§8.13).
A request declared bounded (`route_key/2` returns `consistency: {:bounded, ms}`) runs on the receiving node and may only read.

### 8.3 One deployment across nodes (D1)

The request sends the id of the deployment resolved at ingress. The remote node uses its active deployment of the worker when the id matches. Otherwise `Workers.pinned/3` fetches the package from the store and builds it apart from the registry (no routes, no listeners, active deployment unchanged), and keeps it in a table of `routing.pinned_limit` pinned deployments (16 by default).
A node that cannot build the deployment (`{:code_mismatch, ...}`) rejects the request with 503. Every request reports one deployment at start and end, the one the ingress had applied on arrival.
Roll the release to every node before a deployment switch, as [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) says.

### 8.4 When the node is lost

Each forward ends with an outcome reported by `[:atanor, :forward]`. `:ok` returns the result. `:moved` (asks for the owner and retries) and `:rejected` (`{:error, {:unavailable, reason}}`) mean the node did not start the call. `:lost` means the call was never sent, and it is retried against the owner. `:unknown_outcome` means the connection failed after the call was sent, or the 60 s timeout ran out. A call counts as started once its connection exists, because the caller connects first.
Unknown outcomes are repeated only for HTTP `GET`, `HEAD`, `OPTIONS` and alarms. Other calls get `{:error, :unknown_outcome}`: HTTP answers 503 `{"error": "unknown_outcome", "reason": "unknown_outcome"}`, and a socket closes. A failed forwarded cell call in Alambique answers `{:error, :outcome_unknown}` and is repeated only with `idempotent: true` on `Env.execute/4` or `Env.transaction/4`. WASM writes are never repeated. Retries are three attempts 50 ms apart (`routing: [attempts:, retry_ms:]`), each with a fresh owner lookup.
A 503 `unavailable` means the call did not run and is safe to repeat. It carries `Retry-After` (`http.retry_after_s`, 1 by default) and one reason: `no_quorum`, `owner_unreachable`, `owner_down`, `draining`, `held_elsewhere` (a node outside this cluster holds the lease), `fenced`, `owner_unknown`, `overloaded` (WASM queue full), `store_unavailable` or `deployment_unavailable`. A worker that maps cell errors to 5xx still gets the 503; 500 stays for defects.
`{:foreign_store, node}` means the nodes disagree on the store. It is not retried and answers HTTP 500 `foreign_store` without `Retry-After`. Every node of an instance needs the same store location and placement.

### 8.5 TCP, WebSockets, alarms

TCP: the connection stays on the accepting node until it names a cell. After that, each `handle_tcp/3` runs on the cell's owner, with the worker state sent there and back with every chunk, so keep it small. WebSockets: `ws_init` and `handle_ws/3` run on the owner, and `Env.attach/2` joins the socket in the `:pg` scope of its own node.
Alarms run on the owner of their cell, claimed by the owner's shard scheduler. Alarm calls count as idempotent, and failures are retried by the scheduler's backoff (at least once). Plug and WASM workers have no routing key and run on the ingress node.
Guarantee C1: every request for a cell is served by its single current owner across node failures, through Alambique's lease and epoch fencing. Acknowledged requests run on the node that committed their transaction, never overlap in time across nodes and apply once. Unanswered requests may or may not have applied.

### 8.6 Classifying failures

A graceful stop (`Supervisor.stop`, a release stop, a deploy) is announced. Peers mark the node gone, and Alambique hibernates its cells and releases their leases.
A process that dies on a live host closes its sockets, so Erlang reports `nodedown` with `connection_closed` at once. A lost machine or network sends nothing, so calls wait until the heartbeats stop (§8.7) or the platform says so (§8.9).
A `nodedown` that the detector did not cause only makes the peer suspect: a cut cable and a reset look alike, and the probes of §8.8 decide.

### 8.7 The phi accrual detector

`Atanor.Detector` runs on every node, after Alambique in the supervision tree. It joins the `:pg` group of the prefix, sends a heartbeat to each peer every `interval_ms`, and keeps the last `window` intervals per peer. Phi is `-log10(P(the next heartbeat arrives later than now))` for a normal distribution of intervals, capped at 300. The deviation has a floor (`min_std_ms`), and `acceptable_pause_ms` is added to the mean. A new peer starts with two intervals around `interval_ms` (`seed_spread` apart). After a stall of this node (`stall_intervals`), it forgets its measurements.
Heartbeats are Erlang distribution messages, sent with `:noconnect` and `:nosuspend` to the peer's detector process, so they use the path that forwarded calls use. Bytes received from an alive peer (`recv_oct` of the distribution socket) also count as heard, so a large message does not look like a dead peer. Without that counter only heartbeats count.
Options (`detector:`, all optional, defaults): `interval_ms` 1000, `phi_threshold` 8 (above 300 never), `min_std_ms` 200, `acceptable_pause_ms` 2000, `window` 100, `indirect: [k:, timeout_ms:, round_timeout_ms:]` 3, 1000, 1500, `reprobe_ms` 1000, `reconnect_ms` 1000, `stall_intervals` 3, `seed_spread` 0.25, `forget_after_ms` 600000.

### 8.8 Indirect probes and states

Each peer is `alive` (heartbeats arrive; forwarded), `suspect` (phi reached the threshold or the connection dropped; forwarded while a probe round runs), `link_broken` (this node cannot reach the peer, another node can; not forwarded, answers 503 `unavailable`) or `down` (nobody reached it, or the platform or the node said so; not forwarded; disconnected). `GET /nodes` shows the states.
A probe round (SWIM style) starts on `suspect`. This node pings the peer's detector process (`indirect.timeout_ms`) and asks up to `indirect.k` alive peers to ping it. The first settling answer decides. This node's ping answered: alive again. A witness reaches the peer: `link_broken`, with `via` in `[:atanor, :node, :link_broken]`; the peer stays a member and is re-probed every `reprobe_ms`. No answer: `down`.
A two-node cluster has no witnesses, so phi over the threshold with a failed own ping means `down`. `indirect: [k: 0]` makes any cluster behave this way. A `down` peer that stays silent is forgotten after `forget_after_ms`.
A disconnected node comes back by itself. Every `reconnect_ms`, each unconnected peer gets one background attempt, and the first heartbeat from a `suspect`, `link_broken` or `down` peer makes it `alive` again. Two live nodes that confirmed each other down are alive again within about `reconnect_ms` plus `interval_ms` and the connect time.

### 8.9 The platform hint

The infrastructure can say a node is gone before any detector does: `POST /nodes/NODE/gone` on the admin API of any node (the admin token is required, and the listener is loopback by default). That node confirms `NODE` down at once without a probe, and tells its alive peers, which do the same without relaying further.
The answer is 404 for an unknown node, and the call is idempotent. The hint only makes Atanor stop using a node. It never moves a cell or changes a deployment, and the node's own heartbeats undo a wrong hint. Hinting a live node disconnects it, and it returns to `alive` within `reconnect_ms`.

### 8.10 Acting on a confirmed failure

`Atanor.Detector.confirmed_down/3` is the one place that marks a node down. `Dispatch` stops forwarding to it (its calls end as `:lost`), the node is disconnected (`:erlang.disconnect_node/1`, so in-flight calls fail with `noconnection` at once), and `[:atanor, :node, :down]` is emitted with reason `{:phi, value}`, `{:nodedown, reason}`, `:left` or `:platform_hint`. A leaving node is not disconnected, because its cells hand off over the connection.
Takeover is lazy and per cell. `Atanor.Takeover.recover/3` runs when a lookup answers `{:unavailable, owner, _}`, from `Atanor.Dispatch` and from `Atanor.Cell` (worker cell calls). It takes nothing unless the detector says `owner` is `down`. It reads the lease for its epoch and, if the lease still names `owner`, records the lease's `expires_at_ms` for the fence (§8.13), then calls `Alambique.take_over/4` with `epoch:`. That raises the epoch and fences the old owner. `epoch_changed` or `contended` reads the lease again, up to `takeover.attempts` times. It emits `[:atanor, :cell, :take_over]` and releases the jobs that node had claimed in the cell.
A `link_broken` peer is never taken over; the client repeats through another node (§8.8). A stale verdict costs availability, not correctness, because the epoch fences the old owner. Quorum (`takeover.quorum`, on) lets a node take over only when it and the peers it does not consider lost are a strict majority of the nodes it knows. A peer counts as heard only while `alive` with phi under the threshold, and the majority must hold for `settle_ms`. A node that cannot take over waits for the lease, which lasts `lease_ttl_ms` (30 s).
Options (`takeover:`): `enabled` true, `quorum` true, `settle_ms` 2000, `no_quorum_event_interval_ms` 10000, `attempts` 3, `timeout_ms` nil (Alambique's `call_timeout_ms`), `routing: [attempts:, retry_ms:, remote_timeout_ms:, leave_wait_ms:]` 3, 50, 60000, 3000.

### 8.11 Draining and stopping gracefully

`Atanor.drain/2` (`Atanor.Drain`) hands a node's cells back. It runs from `POST /drain`, `atanor drain`, SIGTERM or the instance stop. The node sets `:draining`: `/health/ready` and `/health/serving` answer 503 `draining`, and `/health` stays 200. The job runner stops claiming and waits `stop.jobs_ms` for running attempts, then releases the claims of unfinished jobs.
`Alambique.drain/2` leaves the membership, refuses wakes (`{:error, :draining}`) and hibernates each awake cell: pending writes are uploaded, the feed is published and the lease is released (`released: true`). Limits: `stop.drain_timeout_ms` (15000) per cell, `stop.drain_concurrency` (64) cells at a time, and `stop.shutdown_ms` (75000) for the whole step. A cell with 32 or more level-0 files compacts first, within `release_deadline_ms` (3000) and `release_reserve_ms` (2000).
`stop.exit` (true) then stops the VM with status 0, or 1 when a cell kept its lease. `POST /drain` answers first with `%{state, hibernated, errors, duration_ms}`. A cell that did not hibernate keeps its lease until it expires (30 s plus the 2 s skew margin by default), and the taking node answers 503 `held_elsewhere` until then. A drain is one way: a second call joins it or returns its status.
SIGTERM drains every instance whose `stop.sigterm` is `:drain` (the default), in parallel, and exits with 1 if a drain left a cell or failed. The container or unit grace period must exceed `stop.shutdown_ms` (75 s; the shipped scripts use 90 s, see [configuration.md](configuration.md#the-stop-grace-period)). SIGKILL leaves the leases to expire. Telemetry: `[:atanor, :node, :drain]`. Walkthrough: [how-to-replace-a-node.md](how-to-replace-a-node.md).
Stop order, children stopped in reverse: (1) the listeners close, and served connections get `stop.connections_ms` (15000); (2) the detector announces `leaving`, peers mark the node down with reason `:left` and keep forwarding idempotent calls, while other calls wait `routing.leave_wait_ms` (3000) for the handoff, then get 503 `unavailable`; (3) the drain above, with jobs already stopped; (4) Alambique stops. `Atanor.Tasks` cancels job attempts, alarm handlers, lease reads, moves and migrations before the detector stops, allowing `stop.tasks_ms` (5000) each. A cancelled job keeps its claim and runs again when the lease ends.

### 8.12 Reads that must not be stale

After a takeover, or in a partition, an old owner can answer a plain read from its own copy until it learns the new epoch. Native workers choose per read. `Atanor.Env.query(env, cell, sql, params, verify_lease: true)` (also `Atanor.Cell.query/5`) reads the lease object after the statement and answers only if the lease is still its own. The default is off, so a read costs no store request.
The WASM `sql` import has no lease flag. A read that accepts staleness says so with `consistency: {:bounded, ms}` and may be answered by a replica on another node. Guide: [how-to-read-from-replicas.md](how-to-read-from-replicas.md).

### 8.13 A handler that outlives its cell

Fencing protects the cell, not what a handler does outside it. After a takeover, a handler may run on two nodes at once. Cell writes stay safe, since the old owner's writes are refused with `:fenced`. Outbound HTTP, e-mail and socket messages can happen twice, so they need an idempotency key that the receiver checks, or they run as a cell job, which runs on the current owner and carries a stable job id.
Before a handler starts for an owned cell, the node reads the lease (`Alambique.query/5`, `verify_lease: true`) unless it did so within `routing.owner_check_ms`. A busy cell has its read refreshed ahead of time by `Fence.refresh_ahead/3`. A job or alarm handler is killed at the end of the node's lease, at `expires_at_ms - skew_margin_ms` on the cell clock.
A cell taken over early starts no job or alarm handler until the old lease has ended plus `skew_margin_ms`. The takeover records this hold, and each job or alarm claim checks it. Other handlers (requests, WebSocket and TCP callbacks) run to the end, since Atanor does not interrupt native handlers.
`Atanor.Fence` watches each job or alarm task. It kills the task with `:brutal_kill` at the lease deadline, or at once when a read shows another owner or epoch. The handler returns `{:error, :handler_fenced}`, and `[:atanor, :handler, :fenced]` is emitted with `reason` `:local_deadline`, `:lost`, `:unreadable` or `:stopped`. With clock skew below `skew_margin_ms` (2000 by default), the handlers of two nodes do not overlap. `routing.fence_check_ms` sets the read interval, and `routing.fence_defer_after_takeover` (on) keeps the early-takeover hold, which lives in memory only.

### 8.14 Ingress and owner: what runs where

HTTP, WebSocket and TCP connections end on the node the client reaches. Only the worker's callback goes to the owner. The ingress runs the listeners and TLS, HTTP parsing, body reading (413 limit), route match and deployment pin, the bearer token check (`Atanor.HTTP.authorize/4`, with claims in the `x-atanor-claims` header), response writing, the WebSocket process (`Atanor.HTTP.Socket`) and the TCP connection (`Atanor.TCP.Connection`).
The owner runs `handle_request/2`, `ws_init/2`, each `handle_ws/3` (one call per frame) and `handle_tcp/3`. `handle_ws_local/3` runs in the socket process on the socket's node, with no cell access. `Env.send_to_cell/3` runs `handle_ws/3` with `{:cell_message, message}` once per attached socket on the owner. `Atanor.Channels.broadcast/2` sends one message per remote node.
Plug and WASM workers run on the ingress node, so each of their cell calls pays one network hop. Use `handle_request/2` in a native worker for latency-sensitive paths. One cell still has one writer, on one node.

### 8.15 Placement of hot cells

`Atanor.HotCells` moves a hot cell to another node with `Alambique.move/4`: the owner hibernates the cell and the target wakes it. The loop is off by default (`hot_cells: [enabled: true]`). Each node samples and decides only for the cells it serves. Other nodes' load arrives in a message every `interval_ms`.
Metrics are reads and writes per second of a cell (counters in `Atanor.Cell`), `pending` of `Alambique.load/2` (calls waiting on the cell), and node CPU, the larger of the scheduler busy share and, on Linux, the machine's `/proc/stat` share (`os_cpu`). A cell is hot when a signal passes its enter threshold, and stays hot until all of them are under their exit thresholds.
The decision (`Atanor.HotCells.Policy`) covers a cell hot for `sustain_ms`, hottest first, one move at a time. Skip a cell moved within `residence_ms`, and respect `max_moves` in progress and `node_cooldown_ms` for both nodes. `affinity` sends a ruled namespace to a node with the tag. Otherwise only a pressured node (CPU from `cpu_enter` to `cpu_exit`) gives a cell to the least loaded node whose CPU is at least `margin` points lower. A target must have been heard within `stale_ms`, and be alive, not leaving and not cut off.
Safety does not depend on the loop: a move is hibernate then wake, and leases and epochs keep one writer per cell. The loop emits `[:atanor, :hot_cell, :sample]`, `[:atanor, :hot_cell, :decision]` and `[:atanor, :hot_cell, :move]` ([telemetry.md](telemetry.md)). `GET /hot-cells` shows one node's view. Guide: [how-to-place-hot-cells.md](how-to-place-hot-cells.md).
Options (`hot_cells:`): `enabled` false, `interval_ms` 1000, `sustain_ms` 10000, `write_enter`/`write_exit` 500/250, `read_enter`/`read_exit` 2000/1000, `queue_enter`/`queue_exit` 50/10, `cpu_enter`/`cpu_exit` 70/50, `os_cpu` true, `margin` 20, `residence_ms` 300000, `node_cooldown_ms` 30000, `max_moves` 1, `move_timeout_ms` 15000, `release_deadline_ms` nil, `stale_ms` 5000, `max_tracked` 100, `move` true, `replicas` false, `replica_enter`/`replica_exit` 1000/500, `replica_hold_ms` 60000, `tags` [], `affinity` [].

### 8.16 Discovery through the store

Nodes find each other through Alambique's registry (`alambique: [registry: [advertise:, ttl_ms:, renew_ms:, meta:]]`), which writes `<prefix>/nodes/<node_id>` and removes it on drain or stop. `Atanor.Discovery` calls `Node.connect/1` for the listed peers of its own group (`"group"` in `meta`, `ATANOR_GROUP`), on `peers_changed` and every `refresh_ms` (else `renew_ms`, else 10 s), in tasks. It never disconnects. The `advertise` value is an Erlang node name `name@host` (`ATANOR_ADVERTISE`). A value that is not is logged and counted (`[:atanor, :discovery, :invalid]`), and never dialled.
A peer that leaves the listing stays connected. The detector decides whether it is down (§8.7 to §8.10). Discovery reconnects a node that the detector disconnected while the registry still lists it. Discovery changes who is connected, never who owns a cell.
Whoever can write `<prefix>/nodes/` decides whom the nodes dial. The cookie still gates the handshake and is never in the bucket. Between nodes, `epmd` (4369) and the distribution ports (9100 to 9110 for the daemon) must be open.
A node of another group is logged and counted (`:ignored`) and left alone. A listed node that does not answer is retried every round and logged once.

## 9. Limits

Known limits are in [known-limitations.md](known-limitations.md).

## 10. Observability

### 10.1 Events

`telemetry` events per worker, deployment and cell ([telemetry.md](telemetry.md)). Each call into a worker emits `[:atanor, :call]` on the node that ran it, with `worker`, `deployment`, `cell`, `kind`, `node`, `forwarded`, `result`, `status` and `instance`.

### 10.2 Admin API

`Atanor.Admin` is a Bandit listener (option `admin:`); there is no listener without the option. Every request needs `Authorization: Bearer <token>`, compared in constant time.
An open store breaker does not make the node unready: `/health/ready` and `/health/serving` ignore it, and `/health` and `/runtime` show it as `store`. `Atanor.StoreLog` writes breaker changes and store failures to the node log.
Paths include `/health`, `/runtime`, `/deployments`, `/routes`, `/cells`, `/nodes`, `/jobs`, `/operations`, `/crashes`, `/rehearsals`, `/workers`, `/heads`, `/tokens` and `/audit`. Cluster-wide endpoints ask every node through `:erpc` with a 5 second timeout; a silent node shows `"status": "error"` and the response has `"partial": true`.
[how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) shows each endpoint.

#### 10.2.1 Deploys, scoped tokens and the audit log

Deploy writes go through `Atanor.Deployments.Service` (`deploy/3`, `upload/5`). The contract is [openapi/admin.json](openapi/admin.json).

* Scoped tokens are `atn_<id>_<secret>`. Only the SHA-256 of the secret is stored, in `tokens/<id>`. A request reads that object, so a revocation applies on the next request. A store read failure is 503, never an allow.
* Scopes are `cluster:admin` and `worker:<name>:<action>` with action `deploy`, `activate`, `rollback` or `read`; the worker may be `*`. `cluster:admin` implies no worker scope.
* Deploy writes and token create or revoke are audited in `audit/<time>-<random>`: actor, action, worker, version, result (`ok`, `denied`, `failed`), status, error code, time, node and remote address. Reads and 401s are not.
* `Atanor.Admin.Throttle` limits failed bearer tokens per client address (IPv6 by /64; `X-Forwarded-For` is never read). After `max_failures` in `failure_window_ms` the address gets 429 `too_many_attempts`, even with the right token. The state is per node.

### 10.3 Dashboard

A read-only Phoenix LiveDashboard with pages for workers, deployments, routes, cells, alarms and jobs, plus a Metrics page fed by `Atanor.Dashboard.Metrics` ([screens.md](screens.md)).

* `phoenix`, `phoenix_live_view`, `phoenix_live_dashboard` and `telemetry_metrics` are optional. `Atanor.Config` rejects `dashboard:` when they are missing.
* Option `dashboard: [token:, port:, ip:]`, port 4002 and loopback by default. The token is always required.
* `?token=` on a `GET` answers 303 and sets a signed `SameSite=Strict` cookie (`Max-Age` `cookie_max_age_s`, 86,400 s by default; `Secure` with `secure_cookie: true`). Requests without the cookie get 401.
* Cells and alarms page with `?after=` and `?limit=` (`page_size` 50, `max_page_size` 500). `Atanor.Dashboard.Poller` emits the native counters every `poll_ms` (5 s).

## 11. Test kit

`atanor_testkit` (in `testkit/`, compiled into the test build) starts nodes and clusters over the Alambique testkit store. `AtanorTestkit.Node` starts one node; `AtanorTestkit.Cluster` starts `:peer` nodes on `127.0.0.1` with `deploy/3`, `activate/4`, `rollback/3`, `kill/2`, `restart/2`, partitions, process pause and resume, clock skew and forwarded telemetry. Cluster tests carry `@moduletag :cluster` and run with `mise run test:cluster`.

Properties (StreamData) cover: a single owner across node failures (C1); no request split across deployments, on one node and across nodes (D1); every committed alarm fires at least once; a WASM worker cannot reach an ungranted binding (B1); runaway workers stop and the node stays healthy (L1).

## 12. Measurements

The cost of one awake cell is in [cell-cost.md](cell-cost.md).

## 14. WASM engine

The Rustler crate `native/atanor_wasm` runs Wasmtime 50 (`wasmtime`, `wasmtime-wasi`, `wasmtime-wasi-http`) on a pool it owns, off the BEAM schedulers.

### 14.1 Own pool, not dirty schedulers
The crate owns `max_calls` OS threads (default 4 per logical processor) fed from a bounded queue; `invoke/5` only enqueues. A call runs `block_on` of a current-thread Tokio runtime on its thread. A separate epoch ticker thread sleeps `tick_ms` (10) and increments the epoch.

### 14.2 Admission
Admission is in Rust (`admission.rs`); Elixir does not count requests. Four bounds apply:
- **Running:** at most `threads` guests run at once (default: logical processors, capped by the cgroup `cpu.max` quota, rounded up). A guest holds a permit only while it runs.
- **Queue:** `queue` calls wait for a pool thread; a full queue refuses at once. At most `max_calls` calls are busy, and at most `worker_calls` per worker (default three quarters of `max_calls`). A worker has at most `worker_queue` queued calls (default three quarters of `queue`, at least 1).
- **Waiting:** at most `max_waiting` guests that wait give their call slot back. A woken guest is never refused.
- **Nested:** a guest-to-guest call skips the queue and gets its own thread, up to `max_nested_calls` (default 1 per thread).

Refusals are `{:error, :overloaded}` (HTTP 503 with `Retry-After`), with `reason` `worker_queue` or `nested_calls`; `Atanor.Admission.stats/1` counts them. A queued call that waits longer than `queue_wait_ms` is withdrawn by its caller. With a memory limit, `max_waiting` and `queue` are `clamp(waiting_budget / waiting_bytes, 1, 256)`, where `waiting_bytes` (2 MiB) is what one waiting guest or queued call is counted to hold. Without a limit they are 2 and 4 per thread.

### 14.3 Allocator
The library's global allocator counts Rust heap bytes per thread (`alloc_bytes`, `free_bytes`). Guest memory is reported as `memory_bytes` in each `invoke` event. `Atanor.Wasm.Stats.emit/0` emits all counters.

### 14.4 CPU: epoch by default
Epoch (default): the store gets a deadline of one tick, and the callback stops the guest at the wall deadline (`:timeout`) or when the pool thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`) since the call began reaches `cpu_ms` (`:cpu`). Fuel: the store gets `fuel` units (manifest `limits.fuel` or the node setting) and traps with `OutOfFuel` (`:cpu`). The engine is built in one mode per VM (`:cpu` in `:atanor, :wasm`). A Tokio `timeout_at` also bounds the whole call.

### 14.5 Compiled code cache
`Atanor.Wasm.Cache` keeps compiled components per package id in ETS and compiles a missing one once. On a miss the crate reads `<data_dir>/wasm/<id>-<engine>.cwasm`, where `<engine>` fingerprints Wasmtime's compatibility hash. The file holds a SHA-256 of the payload, then the `Component::serialize` output; a failed read recompiles and rewrites the file by atomic rename. The digest detects damage, not tampering. The `[:atanor, :wasm, :load]` event reports `:memory`, `:disk`, `:compiled` or `:recompiled`. Compiles run on `compile_threads` (default 2) with a queue of `compile_queue` (default 16); a full queue answers `:overloaded`, and a deployment waits at most `compile_timeout_ms` (60,000). Entries are not evicted while the instance runs.

### 14.6 Linking and WASI
Each component gets WASI preview 2 with an empty context: no preopened directories, environment, arguments, stdin or stdout. Sockets and IP name lookup are denied by default. The `atanor:*` interfaces and `wasi:http/outgoing-handler` are linked only when granted; guests built with any `wasi 0.2.x` bindings link against the host's 0.2.12. Guest stderr is captured up to `stderr_bytes` (4 KiB) and logged as one line with control characters escaped (see [how-to-write-a-wasm-worker.md](how-to-write-a-wasm-worker.md)).

### 14.7 Host calls and outbound HTTP
A granted import sends a host message to the process that called `Atanor.Wasm.invoke/3`, which answers it with `Atanor.Wasm.Host` using the request's `Atanor.Env`, so a WASM worker runs the same functions as a native one. The guest waits without holding a run permit. Outbound HTTP goes through the `send_request` hook, which buffers the body and calls `Atanor.Env.fetch/3`; the allowlist, address checks and redirects are those of `Atanor.Env` and `Atanor.Egress`. Bodies are buffered, not streamed, within `max_body_bytes` and `max_response_bytes`. `Native.host_reply/2` uses a DirtyCpu NIF for replies of `host_reply_dirty_bytes` (default 262,144) or more, and a normal NIF below that. Cell host calls are the `Atanor.Env` functions of the same names, plus `partition` (`Env.partition/3`). A WASM worker calling another holds its call slot while it waits; the callee runs on a nested-call thread.

### 14.8 Alarms, sockets and what is left out
`Native.invoke/5` takes a tagged call (`:http`, `:alarm`, `:ws_open`, `:ws_message`, `:ws_close`) and runs it with the same store, limits and host-call link as an HTTP request. `prepare` finds the `atanor:worker/alarm-handler@0.1.0` and `atanor:worker/socket-handler@0.1.0` exports by type; a manifest that grants `alarms` or `sockets` without its export is refused with `{:missing_export, name}`. `wasi:http/incoming-handler` is always required. Results: `nil` (alarm, close), `accept` or `{reject, {status, headers, body}}` (open), `{frames, close?}` (message). `atanor:worker/socket-local` is an optional export, called as `{:ws_local, socket, :text | :binary, data}`, returning `pass` or `drop`. WASM workers do not serve TCP: a `tcp` route is refused with `{:unsupported_for_wasm, :tcp}`. Limits: see known-limitations.md.

### 14.9 Pooled instance slots
The pooling allocator is the default; `pooling: false` maps memory on demand. The pool holds `max_calls + max_waiting + max_nested_calls` component instances, and one store may hold 8 core instances, 8 memories and 16 tables (`Limiter`). A memory slot holds `max_memory_bytes` (at most 4 GiB) and a table slot `table_elements`; a component that needs more fails to instantiate. Each memory slot reserves 4 GiB of address space, so the pool reserves `(max_calls + max_waiting + max_nested_calls) * 8` of them. Lower those settings or set `pooling: false` to reduce it. A host with an address-space limit (`ulimit -v`, `vm.overcommit_memory=2`) must use `pooling: false`, or fewer `threads` and `max_calls`.

## 15. Jobs per cell and bulk operations

A job is a row in the cell's SQLite, written in the same transaction as the worker's data, and the earliest due job is the cell's wake-up alarm. A bulk operation (sweep) enqueues one job in each cell of a selector.

### 15.1 Atanor's per-cell schema
Schema version 1 is the presence of the base tables `_atanor_alarms` and `_atanor_jobs`; there is no version row. `Atanor.Jobs.Schema.ensure!/2` runs in the cell transaction and creates what `sqlite_master` lacks, in one `Alambique.Tx.script/2`. `_atanor_cron`, the due and done indexes and `_atanor_undo` are created lazily. `Atanor.Config` sets `internal_prefixes: ["_atanor_"]`, so these tables stay out of the change feed; `_atanor_` names are reserved. A job row has `id` (32 hex), `worker`, `kind`, `payload`, `state` (`pending`, `running`, `done`, `dead`, `cancelled`), `due_at_ms`, `claimed_until_ms`, `claimed_by`, `attempts`, `max_attempts`, `unique_key`, `unique_period`, `idempotency_key`, `operation_id`, `last_error` and `completed_at_ms`.

### 15.2 Enqueue and unique keys
Native workers call `Atanor.Jobs.enqueue(tx, env, cell, job)` inside `Env.transaction/4`, so the job and the data commit together; `Env.enqueue/3` is the one-transaction form. WASM workers import `atanor:cell/jobs@0.1.0` (`enqueue`, `enqueue-batch`), export `atanor:worker/job-handler@0.1.0` (`handle-job`), and need `"jobs": true` plus the namespace under `cells`; without the grant the result is `{:error, {:not_granted, :jobs}}`. The job id is the default idempotency key. A unique key is scoped to `(cell, worker, unique_key)`, with `:until_done` (default), `{:seconds, n}` or `:forever`; a conflict inserts nothing and returns `{:ok, {:duplicate, id}}`. Per cell, `jobs:` refuses with `{:error, :queue_full}` at `max_pending` (10,000) pending and running jobs or `max_cell_bytes` (64 MiB) of payloads, and `:forever` keys with `:too_many_tombstones` at `max_tombstones` (10,000). `cron` is refused with `:too_many_crons` at `max_cron` (100).

### 15.3 The wake-up alarm
Jobs reuse `_atanor_alarms` through a reserved row `@jobs`, whose `at_ms` is the minimum of pending `due_at_ms`, running `claimed_until_ms` and cron `next_at_ms`. Its index entry `alarms/<minute>/<at_ms>/<shard>/@jobs/<cell-id>/<nonce>` is written before the row and removed by whoever moves the row; `Alarms.expire/2` removes entries left by a rollback after `alarms.timeout_ms`. `Atanor.Alarms.fire/4` branches on `@jobs`, and `Atanor.Jobs.run/3` claims due jobs and re-arms `@jobs` in one cell transaction. `Alarms.pending/3` hides `@jobs`, and no alarm event is emitted for it.

### 15.4 Execution, retries, cron and timeouts
A runner claims up to `jobs.batch_size` due jobs per cell transaction and starts one supervised task per job. A claim lasts `claim_ms` (60,000), longer than `timeout_ms` (30,000); delivery is at least once. Success sets `done`. A handler failure records `last_error` and retries at `now + min(backoff_ms * 2^(attempts-1), max_backoff_ms)`, or becomes `dead` after `max_attempts` (20); a `jobs.timeout_ms` expiry (`:handler_timeout`) is a handler failure. An availability error of the store or the cell (an `Atanor.Unavailable` reason) returns the job to `pending` with `attempts` unchanged, and its delay grows with the time waited; after `jobs.infrastructure_timeout_ms` (3,600,000) the job is `dead` with `last_error` starting `infrastructure: `. A handler must return an Atanor error unchanged to count as infrastructure. A WASM guest's error always counts as a handler failure, except `:overloaded` and a dispatch crash. A write that ends an attempt with an unknown outcome is not repeated and emits `[:atanor, :job, :unconfirmed]`. A cron row is a schedule: when due, the runner inserts a normal job with key `<cron id>:<fire ms>` in the same transaction. Cron takes five fields with `*`, lists, ranges, steps and `@hourly` to `@yearly`; times are UTC.

### 15.5 Concurrency
`Atanor.Jobs.Slots` holds per-node slots: `jobs.concurrency`, `jobs.worker_concurrency` and `jobs.cell_concurrency` (default 1). A job with no slot is not claimed; its wake is re-armed to `now + jobs.wait_ms` (1,000), and no attempt is used. A slot is released when its holding process exits. With `jobs.claim_on_finish` (default true), the transaction that ends a job also claims the cell's next due job if it is first in `(due_at_ms, id)` order, has the same worker and fits under `cell_concurrency`. A scan claims up to `jobs.batch_size` (20) jobs of a cell, and the claim transaction counts live claims again. A stopping node claims nothing.

### 15.6 Bulk operations (sweeps)
An operation record at `<prefix>/operations/<id>` in the metadata store holds state, selector, action, rate, concurrency, page size, cursor, driver, `lease_id`, `lease_until_ms`, counters and `last_error`; per-cell outcomes stay in the target cells. `Atanor.Sweeps.Manager` polls every `sweeps.poll_ms` (5,000). A running operation without a live driver is claimed with an `If-Match` write, every checkpoint is conditional, and an expired lease resumes from the saved cursor. Selectors are `{:namespace, ns}`, `{:prefix, p}` and `{:index, cell, ns, sql}`; a sweep is not a snapshot. Each target cell gets one transaction that inserts the job and the `@jobs` alarm unless a job with this `operation_id` exists. A token bucket enforces `rate_per_s` (50); at most `concurrency` (8) cell transactions run at once, and at most `sweeps.max_active` (4) operations are driven per node.

### 15.7 Observability, options and measurements
Events are `[:atanor, :job, :enqueued | :started | :finished | :dead]`, `[:atanor, :sweep, ...]` and `[:atanor, :admin, :action]` (see [telemetry.md](telemetry.md)). `jobs:` defaults: `max_attempts` 20, `timeout_ms` 30,000, `claim_ms` 60,000, `backoff_ms` 1,000, `max_backoff_ms` 300,000, `concurrency` 64, `worker_concurrency` 8, `cell_concurrency` 1, `batch_size` 20, `wait_ms` 1,000, `max_pending` 10,000, `max_cron` 100, `max_tombstones` 10,000. `sweeps:` defaults: `poll_ms` 5,000, `lease_ttl_ms` 30,000, `renew_ms` 10,000, `cell_timeout_ms` 10,000, `page_size` 100, `rate_per_s` 50, `concurrency` 8, `max_active` 4, `retry_ms` 1,000, `reread_ms` 600,000, `max_records` 1,000. Config validation requires `claim_ms > timeout_ms`, `renew_ms < lease_ttl_ms`, `cell_timeout_ms < lease_ttl_ms`, `worker_concurrency <= concurrency` and `cell_concurrency <= worker_concurrency`.

### 15.8 Canary and error-rate guard
An operation starts with a canary of the first `canary_size` cells (10; 0 disables it). With `canary_gate` `"auto"` (default), the canary cells are sampled after `canary_window_ms` (60 s); a tripped guard halts the operation, and pending jobs are waited for up to `canary_timeout_ms` (300 s) before the halt with `canary_timeout`. With `"pause"`, the operation waits in state `awaiting_confirmation` for `POST /operations/:id/continue`. The guard keeps the last `guard_window_cells` (50) target cells and samples their job rows every `guard_poll_ms` (5 s): `done` is a success, `dead` a failure, pending jobs are not counted. At least `guard_min_cells` (10) outcomes with `failed / (done + failed) > guard_error_rate` (0.1) halt with `halt_reason: "error_rate"`. A sample that cannot be read counts as a failure; after `guard_attempts` (3) in a row the operation halts with `guard_unavailable`. `resume` of a halted operation clears the window and sets `canary.passed`.

### 15.9 Undo positions
An operation created with `undo: true` (instance default `sweeps: undo`, false) inserts its job in an isolated transaction. It records `Alambique.Tx.before/1` in `_atanor_undo (operation_id, job_id, before_txid, before_at_ms)`, in the same transaction as the job. A replay finds the operation marker and adds no second row. The record gets `"undo": {"enabled": true, "positions": n}`. A cell's first batch records position 0, and `{:txid, 0}` restores an empty database.

### 15.10 The undo report and the undo
`POST /operations/:id/undo` with `{"mode":"report"}` or `{"mode":"apply"}` answers 202 and runs as a task; both share `<prefix>/undos/<operation-id>`. The report restores each cell at `before_txid` and at `:latest` into files under `data_dir/undos/<operation-id>/` and compares them table by table (row count and SHA-256 of the rows, plus a schema hash); `_atanor_*` tables are listed in `host_tables` and left out of the schema hash. A cell that cannot be read, restored or compared within `undo_timeout_ms` is `restorable: false`. Apply refuses with 409 `undo_not_enabled`, `operation_active`, `report_required`, `report_truncated`, `jobs_active` or `already_running`. It rewinds each cell with `Atanor.Cell.rewind/4` at the report's head (`if_head`), with `keep: :internal` and `schema: :same`. A cell written since the report is left as `data_written`. Ledger states are `rewound`, `data_written`, `failed`, `unknown`, `rewinding` and `skipped`. Settings under `sweeps:`: `undo_concurrency` (2), `undo_timeout_ms` (120,000), `undo_max_cells` (1,000), `undo_stale_ms` (600,000).

### 15.11 The claims of a node confirmed down
When `Atanor.Takeover` completes a takeover, `Atanor.Jobs.release_claims/4` runs as a task. In one owner transaction it checks that the lease still names the takeover's epoch and the new owner. It then sets `claimed_until_ms` to now on the `running` jobs claimed by the node taken over, re-arms `@jobs`, asks the owner to run them, and emits `[:atanor, :job, :released]`. Only that node's claims are released, and only at the fenced epoch; claims of a runner that is alive are never released. A running attempt on a fenced node stops at its next fence check (`jobs.fence_check_ms`, 1 s) with `{:error, :handler_fenced}`. The release is lazy, per cell. With `jobs.release_claims` (default true) off, claims expire at `claim_ms`.

### 15.12 The claims of a node that hands its cells back
On drain, after `stop.jobs_ms`, `Atanor.Jobs.Drain.release/1` lists the cells with a process on the node and calls `Atanor.Jobs.release_own/2` on each (up to `stop.drain_concurrency`). It sets this node's `running` claims to now and re-arms `@jobs`. Nothing is released while a job still runs on the node; those claims expire at `claim_ms`. Finished, dead and pending rows are not touched. The next node's tick (`alarms.tick_ms`, 1 s) starts the released jobs. `claimed_by` is the Erlang node name, so every node needs a distinct name.

## 16. The change feed for workers
Native workers read Alambique's change feed through `Atanor.Env.changes/4`, `feed_position/2`, `subscribe/3` and `unsubscribe/2`; the namespace must be granted under the manifest's `cells` binding. WASM workers have no feed import.

### 16.1 Reading changes
- `changes/4` returns `{:ok, changes, next_position}` with the records and rewind markers (16.6) of `namespace`; an ungranted one is `{:error, {:not_granted, {:cell, namespace}}}`. `_atanor_*` tables are not in the feed (16.5).
- The position is opaque and instance-wide; `nil` starts at the oldest object and `feed_position(env, :now)` at the current time. Store `next_position` and pass it back. A page can hold fewer changes than `limit`.
- A change can repeat; `Atanor.Change.id` is the idempotency key. Undecodable objects are skipped for all readers and emit `[:atanor, :feed, :rejected]`.
- `Atanor.Change` fields: `namespace`, `cell`, `table`, `op` (`:insert`, `:update`, `:delete`), `key` (column map or `%{"rowid" => n}`), `row` (new row, `nil` on delete; an absent column was left out of the feed, `nil` is NULL), `txid`, `at` (Unix ms), `id`.

### 16.2 The tailer and subscriptions
- `subscribe/3` monitors the caller and returns `{:ok, ref}`, with `from:` a position or `:now`. The first subscriber starts one tailer per node and instance; it stops with the last subscriber.
- The tailer polls every `feed.poll_ms`, reads `feed.page_size` objects, and reads again at once while the shared position moves or a subscriber catches up.
- Messages `{:atanor_changes, ref, changes, position}` carry only non-empty pages for the namespace. Delivery is at least once; order is kept per cell and by publication across cells.
- `:now` drops records with `at` before the subscription time minus `skew_margin_ms`, so it can repeat changes from that margin. A subscriber from an older position catches up alone, one page per read, then joins the shared stream.

### 16.3 Backpressure, drops and errors
- A subscriber with more than `feed.max_backlog` messages waiting is removed and gets `{:atanor_feed_dropped, ref, position}`; it resubscribes from `position`. `unsubscribe/2` is idempotent.
- A read error keeps the shared position and drops no subscriber. The tailer retries after `feed.retry_ms`, doubling up to `feed.max_backoff_ms`; a success resets the wait.

### 16.4 Telemetry
- `[:atanor, :feed, :read]`: `duration`, `records`, `kept`, `rejected`; `instance`, `namespace` (`nil` for the shared stream), `result`, `reason`.
- `[:atanor, :feed, :rejected]`: `count`; `instance`, `namespace`, `reason`, `key`. Reasons: `:invalid_json`, `:bad_object`, `:bad_record`, `{:bad_op, op}`, `{:unsupported_format, version}`, `:bad_format`, `:too_large`, `:bad_compression`.
- `[:atanor, :feed, :error]`: `count`, `retry_ms`; `instance`, `reason`. `[:atanor, :feed, :subscriber, :dropped]`: `count`, `backlog`; `instance`, `namespace`, `reason` (`:backlog`).

### 16.5 Limits and options
- Atanor starts Alambique with `feed: [internal_prefixes: ["_atanor_"]]`, a fixed prefix every node uses. Each node runs one tailer per instance.
- Alambique's feed settings (`window_ms`, `retention_ms`, `shards`, ...) live under `:alambique`; a record is readable after `window_ms` + `op_timeout_ms` + 2 × `skew_margin_ms`. `:now` uses `skew_margin_ms` (default 2 000 ms).
- Atanor's `:feed` options, checked by `Atanor.Config`: `:poll_ms` 1 000, `:page_size` 100, `:retry_ms` 1 000, `:max_backoff_ms` 30 000, `:max_backlog` 1 000.
- WASM workers cannot read the feed. Limits: see known-limitations.md.

### 16.6 Rewind markers
- `Alambique.rewind/4`, used by operation undo, publishes an `Atanor.Change.Rewind` after the undone records, delivered in the same list as changes and filtered by namespace.
- Fields: `namespace`, `cell`, `from_txid`, `to_txid`, `txid` (`from_txid + 1`), `target`, `kept`, `at`, `id` (`"<namespace>.<cell>:<txid>:rewind"`). Changes with `txid` above `to_txid` and at most `from_txid` are undone; a copy goes back to `to_txid` and continues after the marker.
- The marker is published when the cell next wakes. Match `Atanor.Change.Rewind` explicitly; a `%Atanor.Change{}` comprehension drops it.

## 17. Release identity and crash diagnostics

### 17.1 Release identity
- `:release` `:id` is an operator-supplied immutable image digest or commit; the default `"atanor-" <> vsn` is a development value.
- `Atanor.Release.info/1` returns the id, the Atanor, Elixir, OTP and Alambique versions, `built_at`, and the path and SHA-256 of `atanor_wasm.so` and `alambique_nif.so`. `GET /deployments` shows it per node; nothing is stored. Options: `:id`, `:built_at` (`nil`, ISO 8601), `:hash_nifs` (`true`).

### 17.2 Crash diagnostics
- A breadcrumb file in `data_dir/diagnostics/units/` marks each durable unit: first byte `1` while busy, `0` otherwise; a JSON body with `unit_id`, `kind`, `worker`, `deployment`, `cell`, `job_id`, `operation_id`, `release`, `started_at_ms`. The tracker removes it when the holder ends, so only a VM crash leaves a busy file.
- `:breadcrumbs`: `:off`, `:durable` (default: job attempts, alarms, sweep driver pages, migration tasks, deployment activation, WebSocket connections) or `:all` (also every HTTP and TCP callback). `:durable` does not cover WASM HTTP requests.
- After `:settle_ms`, the busy files of the previous boot become one report, enriched for named cells with `Alambique.crashes/2` and `Alambique.frozen?/2`, written to `<prefix>/crashes/<node>/<id>`. A failed write stays in `data_dir/diagnostics/pending/` (capped by `:max_bytes`, oldest removed first) and is retried every `:pending_retry_ms`.
- `GET /crashes` (`?node=`, `?after=`, `?limit=`) and `GET /crashes/:node/:id` read reports. `POST /cells/:ns/:key/unfreeze` calls `Alambique.unfreeze/2`, logs the admin action and clears the crash counter.
- Options: `:enabled` true; `:breadcrumbs` `:durable`; `:dir` `data_dir/diagnostics`; `:settle_ms` 1 000; `:max_files` 10 000; `:max_units` 1 000; `:max_bytes` 33 554 432; `:pending_retry_ms` 60 000; `:retention_ms` 2 592 000 000; `:cleanup_ms` 3 600 000.
- A clean stop writes no report. A crash with no Atanor unit (a cell wake, restore, compaction or query-only call) writes no report. Markers are not fsynced. A WebSocket holds a marker file and two descriptors for its life.

### 17.3 Migration rehearsal
- `POST /rehearsals` with `{worker, id}` runs `Atanor.Rehearsal` as a task on the receiving node, under a `rehearsal` breadcrumb. It changes no head, registry entry or live cell.
- Sampling pages `Alambique.list_cells/2` per namespace with migrations, in each location, and keeps `sample_size` ids by reservoir sampling seeded by `seed` (random when absent, recorded in `options.seed`); scans stop at `max_scan` ids per namespace, sampling at `max_cells`.
- `Alambique.Ops.restore/5` copies each cell to `<dir>/<rehearsal-id>/<n>.db` without touching the live cell. `Atanor.Rehearsal.Cell` applies migrations on `Alambique.Sqlite`: one `BEGIN IMMEDIATE` per version, `PRAGMA user_version = N`, `COMMIT`; a failed version rolls back and later ones are skipped. Each migration string runs as in a live cell: one statement, and `BEGIN`, `COMMIT`, `END` or `ROLLBACK` are refused. Every statement gets what is left of the cell's `timeout_ms` as its SQLite deadline. Then the integrity check, row counts and a `sqlite_master` hash.
- Each cell has `timeout_ms` from its start; a failed cell does not stop the rehearsal. Record `<prefix>/rehearsals/<id>` with states `running`, `done`, `failed`, `cancelled` (`POST /rehearsals/:id/cancel`) and `stale` (a `running` record older than `stale_ms`). A `running` newest record gives 409 `already_running`, best effort.
- Options: `:sample_size` 10; `:max_cells` 100; `:max_scan` 10 000; `:page_size` 1 000; `:concurrency` 2; `:timeout_ms` 120 000; `:integrity_check` `:quick_check`; `:strict_schema` false; `:seed` nil; `:dir` nil; `:stale_ms` 600 000; `:retention_ms` 604 800 000.
- Usage: [how-to-run-a-migration-rehearsal.md](how-to-run-a-migration-rehearsal.md).

### 17.4 The release as the product artifact
- One Mix release, `atanor`, built from `daemon/` (`atanor_daemon`), holds the runtime, `atanor_wasm.so`, `alambique_nif.so` and the dashboard; it holds no worker. Native workers need a derived image.
- `Dockerfile` targets: `runtime` (default), `harness` (adds curl, iproute2, iptables, procps) and `artifact`. Images run as user `atanor` (uid 10001) with data in `/var/lib/atanor/cells`. Entrypoint `/opt/atanor/bin/atanor-entrypoint`; CLI commands run through `bin/atanor eval`.
- Derived images: `Atanor.Daemon.children/1` gives a node's processes; `mix atanor.release` writes a `Dockerfile` from the dependency's `daemon/rel` overlay. A native worker reaches a node only through `atanor deploy --url` or a profile. See [how-to-build-a-derived-image.md](how-to-build-a-derived-image.md).
- Publication: release-please triggers `.github/workflows/release.yml`, which builds `runtime` per architecture and pushes to `ghcr.io/this-is-npc/atanor` with `<version>` and `latest` tags, and attaches `atanor-<version>-linux-<arch>.tar.gz` with `.sha256`. See [how-to-build-the-release.md](how-to-build-the-release.md).
- Platforms: Linux with glibc, amd64 and arm64.

## 18. Node releases
A new node build replaces the whole cluster at once; there is no staged node rollout. Worker deployments roll one node at a time. A native deployment needs its module in the node build: a node without it refuses the head with `{:code_mismatch, expected, loaded}` and keeps the old deployment serving. A WASM package with an unknown import or manifest key is refused the same way. Use expand/contract migrations, because `migration_window` lets an old node serve a cell one schema version ahead.

## 19. Reading a hot cell from other nodes
Bounded reads let a worker read a cell from a local replica on a node that does not own it. The cell's writes still go through one writer.

### 19.1 The guarantee
- `Alambique.query(..., consistency: {:bounded, ms})` returns a state with every write acknowledged more than `ms` before the read started. It may miss newer writes. `:strong` (default) is unchanged.
- A fresh replica serves the read when there is one; otherwise the owner does. Two reads by one caller can see time go back by up to the bound.

### 19.2 The API of a handler
- Native: `Atanor.Env.query(env, cell, sql, params, consistency: :strong | {:bounded, ms})`. Invalid values return `{:error, {:invalid_option, key}}`; `execute/5` and `transaction/4` take no `consistency:`.
- WASM: `query-bounded(cell, sql, params, max-lag-ms: u32)` in `atanor:cell/sql`; a bound of 0 is `failed("invalid option: consistency")`.

### 19.3 Bounded requests: the reads that leave the owner
- `route_key/2` may end with `consistency: {:bounded, ms}` or `:strong`. Such an HTTP request of a native worker runs on the ingress node without forwarding. Its reads default to the bound; its writes (`execute/5`, `transaction/4`, alarms, `enqueue/3`, `cron/3`) return `{:error, :read_only}`.
- A failure of the cell is handled as for any call. WebSocket frames, TCP chunks, jobs and alarms run on the owner. A replica's schema is the owner's, so a new deployment can fail with SQL errors until the owner migrates.
- Telemetry: `[:alambique, :replica, :read]` with `source` (`:replica` or `:owner`).

### 19.4 Replicas for a hot cell, by themselves
- The owner turns a cell's replica switch on when its reads reach `replica_enter` (1000) a second cluster-wide for `sustain_ms`, and off when they stay under `replica_exit` (500) for `replica_hold_ms` (60 s). Peers report rates for cells they do not serve in load messages, within `stale_ms`.
- `Atanor.HotCells.Policy.replicas/4` is the pure decision. Failed changes repeat at the next sample. A moved or sleeping cell drops the old owner's entry; the marker stays. `move: false` keeps the loop from moving cells while replicas still switch.
- `hot_cells: [replicas: true]` needs `alambique: [replicas: ...]`, else start fails. Defaults: `hot_cells.replicas` false; `alambique: [replicas:]` off. Manual: `Atanor.Cell.replicas/3`. Telemetry: `[:atanor, :hot_cell, :replicas]`; `GET /hot-cells`.

### 19.5 Pipelined commits
- `alambique: [pipeline_depth: n]` (1 to 16, default 8) is passed to Alambique and checked at start. Callers are answered in TXID order, each after its batch and all earlier ones are durable.

### 19.6 Tests
- Property tests cover the replica read bound, and cluster tests cover replica reads, switching and moves.

### 19.8 What it does not do
- Writes still go through one writer. A WebSocket frame, TCP chunk, job or alarm runs on the owner ([§19.3](#193-bounded-requests-the-reads-that-leave-the-owner)). Limits: see known-limitations.md.
