# Atanor design

This page is for contributors. It describes the model, the processes, the
storage layout and the guarantees. Section numbers are stable references.

## 1. Model

Atanor runs **workers** and the **cells** they use on a cluster of BEAM
nodes, with compute and S3-compatible storage only.

| Concept | Meaning |
| --- | --- |
| Worker | Named unit of code that handles requests. Stateless by itself. |
| Cell | Named stateful unit with its own SQLite, provided by `alambique`. |
| Binding | A capability granted to a worker by its manifest. |
| Deployment | Immutable version of a worker, identified by the SHA-256 of its package. |
| Route | Maps traffic to a worker: an HTTP host and path prefix, or a TCP port. |

Atanor knows no organizations, tenants or regions. Cell placement is the
operator's `Alambique.Placement`; routing keys and identity come from the
worker or the operator's configuration.

Scale target: zero to millions of cells per continent. Nothing in Atanor holds
per-cell state for cells that are asleep. Per-worker state (routes,
deployments) is small and replicated to every node.

## 2. Processes on a node

```
Atanor.Supervisor         children start in this order and stop in the reverse order
├── Atanor.Registry           ETS: config, node state, active deployment per worker, routes, namespaces (read without a process hop)
├── <name>.Tasks              Task.Supervisor: migrations of awake cells, rehearsals
├── Atanor.Wasm.Cache         compiled components by package hash
├── Alambique instance        one per node, named <name>.Cells (default Atanor.Cells); started with `join: false`
├── Atanor.Diagnostics        crash breadcrumbs and reports (§17.2)
├── Atanor.Drain              hands the cells off when the instance stops (§8.11)
├── Atanor.Detector           failure detector (§8.7)
├── Atanor.Admin              Bandit: admin API, loopback by default; answers 503 until the node is ready
├── Atanor.Deployments.Watcher  first load of the store heads (§2.1), then polls, applies switches, hears :pg notices
├── Atanor.Jobs.Slots         per-node job concurrency slots (§15.5)
├── Atanor.Jobs.Drain         waits for local job tasks on a graceful stop
├── Atanor.Sweeps.Supervisor  drivers of bulk operations (§15.6)
├── Atanor.Sweeps.Manager     leases and starts those drivers
├── Atanor.Feed.Supervisor    lazily starts one change feed tailer per instance (§16)
├── Atanor.Alarms.Scheduler   scans the alarm index shards this node owns
├── ready                     one task: joins the cluster, then the node state becomes `:ready` (§2.1)
├── Atanor.TCP.TLS            TLS material and its reloadable cache, one entry per TLS listener
├── Atanor.TCP                TCP listeners (ThousandIsland or Ranch), one per operator listener that a deployment claims
├── Atanor.HTTP               Bandit: HTTP and WebSockets ingress
└── Atanor.Dashboard.Supervisor  only with the `dashboard:` option and the optional deps: PubSub, the native-counter poller and the Phoenix endpoint (§10.3)
```

`Atanor.TCP` starts after the watcher's first load, so it opens the listeners
that the registry already holds when it starts; later activations open them
through `Atanor.TCP.open/2` as before. Every HTTP request, TCP connection, WebSocket frame and alarm
reaches a worker through `Atanor.Dispatch` (§7.2). The VM also runs, outside
the instances, the `:pg` scope `Atanor.PG`. Each instance has its own task
supervisor, `<name>.Tasks` (`Atanor.Tasks`), that runs alarm handlers, job
attempts, lease reads, moves and migrations; it stops before the detector (§8.11).
The detector runs its own connects and probes from a smaller supervisor that starts
before it, since they use no table and its first tick needs them.
A migration rehearsal (§17.3) is a task of that supervisor, not a child of its own.

### 2.1 Starting: deployments first, then the cluster

A node must not take a cell before it has applied the workers that grant the
cell's namespace: the migrations callback (§4.1) has nothing to answer
otherwise and the wake fails. Alambique starts with `join: false`, so no peer
prefers the node, picks it as an owner or moves cells to it, and the node joins
with `Alambique.join/1` when it can serve:

1. The registry, the task supervisor, the WASM cache, Alambique (not joined),
   the detector and the admin listener start. The admin listener answers
   `/health/ready` with 503 `starting` and the reason, and every other endpoint
   with 503 `not_ready`.
2. The watcher lists the workers in the store, reads each head and applies it,
   in its `init/1`. The load is complete when every head was read and either
   applied or recorded as failed in `Atanor.Deployments.status/1`: a worker
   that cannot be built (`code_mismatch`, a route the operator does not allow,
   a package that does not parse) does not keep the node out, since it would not
   serve with or without the wait. A store error is not a result: the load
   repeats every `ready.retry_ms` (1 000) and the node stays `starting`, with the
   last error as the reason. After `ready.timeout_ms` (60 000) the watcher stops
   with `{:deployments_not_loaded, reason}` and the instance does not start; the
   supervisor above it, or the orchestrator, decides about trying again. The
   watcher then joins its `:pg` group and `[:atanor, :deployments, :loaded]` is
   emitted.
3. The job slots, the sweeps, the feed and the alarm scheduler start.
4. The `ready` task calls `Alambique.join/1`, sets the node state to `:ready`
   and emits `[:atanor, :node, :ready]`. Peers may choose the node from here, and
   every process it needs runs. Then the TCP listeners and the HTTP ingress open
   (the ingress is never open on a node that is not ready), then the dashboard.

A stop does not go through the state: the listeners, the admin among them,
close first (§8.11). Nothing calls `Alambique.join/1` after the start, so a node
that drains is not brought back.

The state is in `Atanor.Registry.state/1`: `{:starting, reason}`, `:ready`,
`:draining` (a drain was asked for, §8.11) or `:stopping` (the instance is
stopping, §8.11). A
worker head that changes later is applied by the watcher while the node is
ready, as before (§5.3). A TCP listener that cannot be bound when the node
starts is logged and left closed (§7.3), where a later activation would refuse
the deployment.

## 3. Workers

A worker has a **manifest** (`atanor.json` in its project). Both kinds share
the manifest, the bindings and the cells.

```json
{
  "manifest_version": 1,
  "name": "notes",
  "kind": "native",
  "module": "Elixir.MyApp.NotesWorker",
  "bindings": {
    "cells": {"notes": {"migrations": [[1, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"]]}},
    "secrets": ["API_TOKEN"],
    "http": {"allow": ["api.example.com", "https://pay.example.com", "*.cdn.example.com"]},
    "workers": ["auth"],
    "alarms": true,
    "sockets": true
  },
  "routes": [{"http": {"host": "notes.example.test", "path": "/"}}, {"tcp": {"listener": "smtp"}}],
  "limits": {"timeout_ms": 30000, "memory_bytes": 67108864, "cpu_ms": 5000, "fuel": 1000000000}
}
```

Rules, enforced by `Atanor.Manifest` (the only module that knows the keys):

* `manifest_version` is required and is `1`. A future format change bumps it;
  a node refuses versions it does not know.
* `name` matches `[a-z0-9_-]+`. `kind` is `native` or `wasm`. A native
  manifest has `module` (`Elixir.` plus the module name) and no `component`;
  a WASM manifest has `component`, a file name inside the package, and no
  `module`. Only `manifest_version`, `name`, `kind` and the code key are
  required.
* Unknown keys are errors at every level. Errors are
  `{:error, {:invalid_manifest, path, reason}}` with the path of the first
  invalid input.
* Migrations are `[version, sql]` pairs, `sql` being a statement or a list of
  statements, with versions contiguous from 1. A function is not JSON, so
  there are no function migrations.
* Route `path` defaults to `/` and loses its trailing slash. A route `host` is
  lowercase and exact, `*.host`, or `*` for every host (§7.1). A TCP route names a listener
  (`{"tcp": {"listener": "smtp"}}`), never a port: the operator maps the name
  to a port (§7.3). `"protocol": "ranch"` names a listener that a Ranch
  protocol serves instead of `handle_tcp/3`; the route and the operator's
  listener must agree. A `tcp` route is native-only for now (§3.2); `limits`
  apply to WASM workers (§9).
* The manifest declares intent. A route is active only when the operator
  allows it (§7.1, §7.3); otherwise the activation fails with a clear error
  and the previous deployment keeps serving.
* A `kind: "wasm"` manifest names a `component` (§3.2).

The prior art behind these format choices is in [prior-art.md](prior-art.md)
section 6 (6.1 version and unknown keys, 6.4 `http.allow`, 6.6 routes). The
format has a version field, an `http.allow` syntax with an address check, and
operator-approved routes.

### 3.1 Native workers

Trusted Elixir code implementing `Atanor.Worker`. Native code is **compiled
into the node release**; it is not loaded from the bucket. A native package
holds the manifest and the MD5 of the worker module's object code
(`module.module_info(:md5)`). A node activates a native deployment only when
the loaded module has that MD5, otherwise the deployment is reported as
`{:code_mismatch, expected, loaded}` on that node and the previous one keeps
serving. New native code therefore ships as a release roll first, then a
deployment switch; configuration, bindings, limits and routes switch without
a release.

The behaviour has two HTTP shapes:

* `handle_request(%Atanor.Request{}, env) :: %Atanor.Response{}` - plain data
  (`Atanor.Request`: method, scheme, host, port, path, raw query, headers as
  `{lowercase_name, value}`, binary body; `Atanor.Response`: status, headers,
  binary body), so the request can be executed on the node that owns its
  cell (§8).
* `plug(env) :: {module, opts}` - a Plug served on the ingress node, for
  Phoenix and LiveView, with the env in `conn.private[:atanor]`. Its cell
  calls are routed by alambique. Atanor does not read or limit its body.

A worker implements at least one. When both exist, HTTP uses `plug/1` and
`Atanor.Env.call/3` uses `handle_request/2`. Activation checks that the module
is loaded and declares `@behaviour Atanor.Worker`.

Optional callbacks: `route_key/2` (§7.2), the TCP and WebSocket callbacks
(§7.3) and `handle_alarm/3` (§7.4); `Atanor.Worker` documents each shape. A
module needs at least one of `plug/1`, `handle_request/2`, `handle_ws/3`,
`handle_tcp/3` and `handle_alarm/3`. Activation checks the manifest against
the module: a `tcp` route needs `handle_tcp/3` and `"alarms": true` needs
`handle_alarm/3`, otherwise `{:missing_callback, module, {name, arity}}`.
Callbacks return fixed shapes; anything else, a raise or an exit is logged
with the worker and deployment and fails that request, connection, socket or
alarm attempt (the node and the other connections keep serving).

A deployment's id is the id of its package (§5). A node compares the MD5 in
the package with the loaded module's and records the mismatch in
`Atanor.Deployments.status/1`.

### 3.2 WASM workers

WASM workers are trusted code, like native workers. Running a worker is the
administrator's decision and responsibility: Atanor assumes that every
package, module and NIF it loads was chosen by the operator for this instance.
The WebAssembly boundary is a portability and least-privilege mechanism, not a
security boundary against hostile code. A component that must be treated as
hostile needs a separate VM or container per tenant, outside Atanor's process
model; Atanor deliberately does not start one OS process per component.

A component implements `wasi:http/incoming-handler` and runs in Wasmtime
through Atanor's own Rustler NIF (`native/atanor_wasm`), behind the
`Atanor.Wasm` module. No V8 and no JavaScript runtime. The component sees
only the imports for its granted bindings (§4); there is no ambient network,
filesystem, environment or arguments, and no inherited stdio. That keeps a
buggy or over-broad component from reaching outside its grants; it does not
make an arbitrary component safe to run. Compiled components are cached by
package id, in memory and on disk. Each request gets a fresh store and
instance under the limits of §9. The limits contain faults and runaway
guests; they are not an attacker boundary. The package holds the component
bytes (§5.1); `Atanor.Wasm.build/2` compiles and links it when the node
activates the deployment, so a component that imports something the manifest
does not grant is never activated (B1, §11).

A component also serves the other kinds of work through exports, each call in
a fresh instance under the limits of §9 (so state lives in cells):
`atanor:worker/alarm-handler` for alarms (§7.4) and
`atanor:worker/socket-handler` for WebSockets (§7.3). A manifest that sets
`alarms` must export the first and one that sets `sockets` the second; the
check runs at activation and fails with `{:missing_export, "<interface>"}`.
A component that exports the socket handler is upgraded on WebSocket
requests, as a native worker with `handle_ws/3` is. Raw TCP is not available
to WASM workers (§14.8).

`Atanor.Wasm.invoke(deployment, request, env)` returns `{:ok, response}`,
`{:error, {:limit, :timeout | :memory | :cpu}}`, `{:error, :overloaded}` or
another error. HTTP ingress maps them to 200 and the guest's status, 504,
500 (`limit_exceeded`), 503 and 500. The format of the interfaces a
component may import is in `wit/`; §14 records the engine decisions.

Section 13 records the prior art and the format choices.

### 3.3 What a manifest may grant

A manifest is written by whoever holds a deploy token for the worker (§10.2.1), so
what it declares is a request, not a right. The rule: **access to anything that
belongs to another worker needs the consent of that other side (its own
manifest or the operator's config), never only the caller's manifest.** A grant
that reaches only the worker itself (its own egress, its own module) is free
unless the operator sets a ceiling. All checks run when a head is written
(`Deployments.activate/4` and `rollback/3`, against this node's registry) and
again when a node applies a head (`Workers.activate/2`), so a head that got into
the store another way is refused on every node.

| Grant | Whose consent | Default | Error |
| --- | --- | --- | --- |
| Cell namespace (`bindings.cells`) | The owner: the first worker that activated it, recorded in the store at `owners/<namespace>` with a conditional write. The operator's `namespaces: %{namespace => [workers]}` replaces the owner for that namespace | First activation owns the namespace for good, also while its worker is inactive | `{:namespace_owned, ns, owner}`, `{:namespace_not_allowed, ns, worker}` |
| Calling a worker (`bindings.workers`) | The callee: `callable_by` in its manifest, or the operator's `callers: %{callee => [callers]}`. A worker may call itself | Nobody but itself | `{:not_granted, {:worker, callee}}` at call time |
| HTTP routes | The operator: `hosts:` (§7.1) | Any host when `hosts:` is absent | `{:host_not_allowed, host, worker}` |
| TCP listener | The operator: the listener's `workers: [...]` (§7.3) | Any worker when absent | `{:listener_not_allowed, listener, worker}` |
| Outbound hosts (`bindings.http.allow`) | The operator, as a ceiling: `http_allow: %{worker => [host patterns]}`, each entry exact, `*.domain` or `*`; a wildcard entry of a manifest needs a wildcard pattern at least as wide (`example.com` does not cover `*.example.com`) | No ceiling when absent; with the map, a worker not in it may reach nothing | `{:http_not_allowed, host, worker}` |
| Native module (`module`) | The operator, as a list: `modules: %{worker => ["Elixir.MyApp.Worker"]}` | Any module of the release when absent | `{:module_not_allowed, module, worker}` |

Jobs, alarms, sockets and secrets reach only the worker's own namespaces and
the secret values the operator supplied for that worker name, so they need no
consent of their own; the namespace rule covers the cells they use. A job
always runs as the worker that enqueued it, and a bulk operation's action
worker must be active, grant `jobs` and grant every namespace its selector reads
(§15.6).

**Why the store decides.** Two nodes that apply the same heads in different
orders, or after a restart, must reach the same registry. The owner record is a
conditional write, so the store picks one claimant, and a node refuses the
others whatever the order of its apply loop. A conflicting head is refused
before it is written; one that is already there (written before this rule, or
straight into the bucket) is refused by the node with the same error and
shown in `GET /deployments`.

**Migration of an existing deployment.** A single worker needs nothing: it
becomes the owner of its namespaces the next time its head is applied. Workers
that share a namespace, or call each other, need explicit consent:

1. List the sharing workers with `namespaces: %{"ledger" => ["billing", "reports"]}`. The first
   worker to be applied would own the namespace otherwise and the others would
   be refused.
2. Add `"callable_by": ["web"]` to the manifest of each callee, or set
   `callers: %{"billing" => ["web"]}`. Until then `Env.call/3` answers
   `{:not_granted, {:worker, "billing"}}`.
3. Optionally set `http_allow:` and `modules:` to bound what deploy tokens can grant themselves.

To hand a namespace to another worker, name that worker in `namespaces:` (it
overrides the record), or delete `owners/<namespace>` in the bucket while no worker
that declares it is active. Without `namespaces:`, `callers:`, `http_allow:`
and `modules:` the packages are trusted for everything but cell namespaces
and calls, as in §3.2.

A manifest that does not set `callable_by` has the canonical form, and the
package id, it had before. A node that does not know `callable_by` refuses
manifests that set it, so roll the nodes before you use it.

#### Limits

**A deploy token is still the authority of its manifest for some grants.**
The table above shows that `hosts:`, a listener's `workers:`, `http_allow:` and
`modules:` are ceilings that exist only when the operator sets them. Without them, a holder of a deploy
and activate token for one worker can route any host, claim any configured
listener, reach any host in `http.allow` and bind any module of the release.
Two workers that share a namespace (which the operator must allow) can read and
write each other's `_atanor_*` tables (jobs, alarms, cron, undo positions): a
worker can insert a job row that runs another worker's `handle_job/2`, or
rewrite an undo position. Sharing a namespace puts the workers in one trust
domain. A check that a job's worker grants jobs and the namespace was tried and
not kept: a worker that has both still runs a planted row, and a refused row at
the head of a cell with `cell_concurrency` 1 blocks the jobs behind it.
Workaround: set the four ceilings on every node where several teams deploy, cap
the component with `package: [max_component_bytes: ...]`, give each tenant its
own namespaces and share one only between workers you trust. Evidence:
`test/atanor/grants_test.exs`, `test/atanor/package_limits_test.exs`.

## 4. Bindings

A binding is granted by the manifest. `env` (native) and the component's
imports (WASM) expose only granted bindings. Using anything else fails with
`{:error, {:not_granted, binding}}`; for WASM the import does not exist.

| Binding | Operations |
| --- | --- |
| `cells.<namespace>` | `query`, `execute`, `transaction` on cell `<key>` of that namespace; `changes` and `subscribe` over the namespace |
| `alarms` | `set_alarm(cell, at_ms, payload)`, `cancel_alarm(cell)`; fires `handle_alarm` |
| `jobs` | `enqueue(cell, job)`; fires `handle_job`; unique keys and retries (§15) |
| `sockets` | `attach(cell)` the calling WebSocket to a cell; `send_to_cell(cell, message)` to the sockets attached to it |
| `http.allow` | outbound HTTP to allowlisted hosts only, never to private addresses |
| `workers` | call another worker's active deployment |
| `secrets` | read named secrets supplied by the operator, never stored in packages |

A denied binding is `{:error, {:not_granted, binding}}` with `binding` one of
`{:cell, namespace}`, `{:secret, name}`, `{:http, host}`, `{:worker, name}`,
`:alarms`, `:sockets`. `alarms` and `sockets` also need the cell's namespace
granted, and are described in §7.3 and §7.4.
Native workers use them through `Atanor.Env`:

* **cells**: `query`, `execute` and `transaction` on `{namespace, key}`, for
  the namespaces of the manifest's `cells`. The same grant reads the change
  feed of the namespace with `changes(env, namespace, position, limit)` and
  follows it with `subscribe(env, namespace, from: ...)` (design §16).
* **secrets**: `secret(env, name)`. Values come from the operator's
  `secrets: %{"worker" => %{"NAME" => "value"}}` option of `{Atanor, opts}`;
  only names in the manifest are readable, and a granted name without a value
  is `{:missing_secret, name}`. The config's `Inspect` hides the secrets.
* **outbound HTTP**: `fetch(env, request)` through Req. Default deny; an
  entry of `http.allow` is one of:

  | Entry | Matches |
  | --- | --- |
  | `api.example.com` | that host, any scheme, any port |
  | `api.example.com:8443` | that host and port, any scheme |
  | `https://api.example.com` | that scheme and host on the scheme's default port (`http` 80, `https` 443) |
  | `https://api.example.com:8443` | that scheme, host and port |
  | `*.example.com` | any subdomain at any depth, never `example.com` itself; the domain needs at least two labels (`*.com` is invalid) |

  Entries combine with the same scheme, port and wildcard forms; hosts are
  lowercase and the request's host is compared in lowercase. Redirects are
  followed up to 5 times and every hop is checked, so a redirect to another
  host is `{:not_granted, {:http, host}}`. A redirect never goes from `https`
  to `http` (`{:error, :insecure_redirect}`), and `authorization`, `cookie`
  and `proxy-authorization` are dropped from a hop that changes scheme, host
  or port. Only `http` and `https`, and the
  usual methods. The grant is checked first; then `Atanor.Egress` resolves the
  host and refuses it with `{:private_address, host, ip}` when any resolved
  address is private (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7),
  loopback, link-local, multicast, unspecified, documentation or reserved
  (IPv4-mapped, NAT64 and 6to4 IPv6 forms are judged by their IPv4 part;
  Teredo, `::/96` and the local-use NAT64 prefix are refused), unless the operator's
  `allow_private_hosts` permits it: a host name (all of its addresses), an IP
  address or a CIDR block, and every blocked address must be permitted. The
  request connects to the address that was checked, with no second lookup, and
  keeps the name for the `Host` header and TLS. `{:unresolved, host}` when the
  name does not resolve. Why: a name that an attacker controls could resolve
  to the node's own network (SSRF), as `workerd` guards against by default
  (prior-art.md §6.4). The whole fetch, redirects and name lookups included,
  is bounded by `calls.fetch_timeout_ms` (30 000; `{:error, :timeout}`), and
  the body by `calls.fetch_max_bytes` (8 000 000;
  `{:error, :response_too_large}`); a WASM guest's fetch also ends with its
  own deadline. A fetch opens one connection (Mint, HTTP/1.1) and closes it,
  so no connection pool or atom is created per host name a worker reaches.
  Req keys a Finch pool on the connect options, and the options carry the
  host name that TLS verifies while the request goes to the checked address;
  every distinct name therefore started a supervisor tree and an atom that
  were never freed (40 names started 40 pools), which a wildcard `http.allow`
  entry and wildcard DNS turn into memory and atom exhaustion. The price is a
  TCP and TLS handshake for each request. Measured with `mise run bench:fetch`
  (2000 sequential fetches of a local plain-HTTP target, on a shared laptop
  with a load average of about 8; two runs each): p50 248 and 268 us and p99
  565 and 943 us with one connection per fetch, against p50 166 and 216 us
  and p99 611 and 713 us with the pooled Req it replaced, so about 50 to
  80 us more per fetch on loopback. The runs are noisy and overlap at the
  tail. The TLS handshake was not measured (the client trusts only system
  certificates, so a local TLS target does not verify); against a remote
  host expect a round trip or two more per request.
* **worker calls**: `call(env, worker, request)` runs the callee's
  `handle_request/2` in the same node, with the callee's own env and grants.
  The env pins the callee at ingress, with the deployment of the request
  itself (D1): `Env.new/2` reads the id of the active deployment of every worker
  reachable through `workers` bindings from a small registry table (`pins`; only
  ids and worker names are copied, no store read), so every call of one request
  to a worker reaches one version, whatever is activated meanwhile. A call uses
  the active deployment when its id is the pinned one. Otherwise the deployment
  is no longer active and is rebuilt from its package by id, as for a forwarded
  request (`Workers.pinned/3`, §8.3): one store read, then it is kept in the
  pinned table. If that fails (package gone, code mismatch) the call returns the
  error and does not run another version. A callee that was not active at
  ingress is resolved at call time. The depth is limited to 8; deeper is
  `{:error, :max_call_depth}`.
For WASM the binding is the import. The WIT packages are in `wit/`:
`atanor:cell/sql@0.1.0` (`query`, `execute`, `batch`), `atanor:cell/alarms@0.1.0`
(`set-alarm`, `cancel-alarm`), `atanor:cell/jobs@0.1.0` (`enqueue`,
`enqueue-batch`), `atanor:cell/sockets@0.1.0` (`attach`, `send-to-cell`),
`atanor:config/secrets@0.1.0` (`get`) and `atanor:worker/call@0.1.0` (`call`);
outbound HTTP is the standard
`wasi:http/outgoing-handler`. Each is linked only when the manifest has the
binding (cells, secrets, workers, `http.allow`, `alarms`, `sockets`, `jobs`). The
alarms and sockets interfaces take a cell as namespace and key, so they also
need the namespace under `cells`, checked at call time. The import check names the
first ungranted import: `{:not_granted, {:import, "atanor:cell/sql@0.1.0"}}`.
A granted import still goes through the `Atanor.Env` checks at call time, so
a namespace, secret, worker, host or job binding the manifest does not list
fails with a `not-granted` error value (the `Env` result for native workers). Alarms and
sockets call the same `Env.set_alarm/4`, `cancel_alarm/2`, `attach/2` and
`send_to_cell/3` as native workers.
`batch` runs a list of statements in one transaction; there are no
interactive transactions across host calls, because a transaction holds the
cell's single writer and a guest could hold it until its deadline.

### 4.1 Cells and schemas

A cell is addressed by `{namespace, key}`. The alambique cell id is
`<namespace>.<key>`, so namespaces must match `[a-z0-9_-]+` and keys follow
the placement's id rule. Alambique applies the migrations of a cell when it
wakes (`migrations: {module, function}` calls `module.function(cell_id)` on
every wake, in the sweeper and in `check_deploy`) and records the version in
the cell's `PRAGMA user_version`. A deployment that lowers a namespace's
migration list is refused.

A migration is a SQL statement or a list of statements, written in the
manifest; each becomes one Alambique migration, a function of an
`Alambique.Tx` that executes the statements in order, and a failing statement
fails the migration. Namespaces come from the cell bindings of the active
workers, not from the instance options. A namespace belongs to one worker
unless the operator shares it (§3.3). Two workers that grant the same
namespace must list identical migrations, otherwise the second activation is
refused with `{:namespace_conflict, namespace, worker}`; a worker's new version
with fewer migrations than its previous one is `{:migrations_lowered,
namespace}`. A namespace disappears with its last worker. A namespace can
declare `partitions` to spread one logical cell over several physical cells
(§4.2); two workers that grant it must declare the same number.

Alambique calls `module.function(cell, extra_args...)`, and a VM can run
several instances (the tests do). The `:migrations` option is therefore
`{Atanor.Migrations, :for_cell, [name]}`: `for_cell(id, name)` parses
`<namespace>.<key>`, reads that instance's namespace from `Atanor.Registry` (an
ETS lookup, no process hop) and returns the namespace's migrations. The
registry answers from the active workers and, failing that, from the pinned
deployments (§8.3). An id that is not an address gives `[]`. A namespace that no
deployment of the node grants raises, which fails the wake with
`{:error, {:bad_migrations, message}}`: a node that has not applied the worker
yet must not create a cell without tables. A node does not get there at start:
it joins the cluster only after its first load of the deployments (§2.1). The
error remains for a namespace that no worker grants, which a client cannot fix
by retrying.
Alambique's sweeper (off by default in Atanor) and `check_deploy` call the
function for every cell they find, so they report the cells of a namespace that
no worker grants as errors.

Alambique's rules apply: a cell up to `:migration_window` versions ahead of the
list (default 1) is served as it is, so code one version behind keeps serving
during a rollout; a cell further ahead fails with `{:schema_too_new, version}`;
a failing migration fails the wake. An awake call costs one Alambique call.

Migrations run at wake, so a cell that is awake would keep its schema. When an
activation adds a namespace or gives one more migrations, and the registry
holds the new list, `Atanor.Workers.activate/2` starts a background task
(under the instance's `Task.Supervisor`, so it never blocks the activation)
that pages through this node's awake cells whose id starts with `<namespace>.`
(`Alambique.cells/2`) and calls `Alambique.migrate/3` on each, without a wake
cycle: the cell keeps serving, and calls that arrive during a migration wait for
it. A cell that is asleep migrates at its next wake (`{:ok, :asleep}`, not
counted). Alambique keeps the migrations that ran before a failing one, uploaded,
so a cell whose migration fails stays at the version before it and keeps
serving; the failure is logged and counted. `migrate: [concurrency:, page_size:,
timeout_ms:]` (defaults 8, 100, `nil` for Alambique's `call_timeout_ms`) set how
many cells are migrated at once, how many are listed per page and how long each
may take. Every node does this for its own cells when it applies the head, so a
cell owned by a node that applies later keeps the old schema until then.
`[:atanor, :cells, :migrate]` reports the counts ([telemetry.md](telemetry.md)).

#### Limits

**A cell can run old schema until its owner applies a new worker version.** A
node hibernates its own awake cells of a namespace when it applies a worker with
more migrations for it, so the cells wake migrated. Until the node that owns a
cell has applied the head (seconds, set by the poll interval), a request that
reaches it on the new version, from a node that applied first, runs against the
old schema and can fail (`no such column`). Workaround: roll out additive
migrations and code that tolerates the old schema for the seconds a rollout
takes. Evidence: the cluster test "its cells wake migrated on the node that
owns them" in `test/cluster/routing_test.exs`.

### 4.2 Partitioned cells

A cell has one writer, so one cell has a ceiling that no placement lifts (§8.15
only chooses which node it is). A namespace can instead be **partitioned**: for
each logical cell `{namespace, key}` there are `n` physical cells, and a write
goes to the one that holds its *partition key*. Each partition has its own
writer, owner and node, so the writes of one logical cell are spread over up to
`n` writers. It is optional and per namespace; a namespace without `partitions`
behaves exactly as before. How to use it:
[how-to-partition-a-cell.md](how-to-partition-a-cell.md).

*Declaration.* `"partitions": n` in the cell binding, `n` an integer from 2 to
1024 (`Atanor.Partition.max_partitions/0`):

```json
"bindings": {"cells": {"events": {"migrations": [["..."]], "partitions": 6}}}
```

The migrations apply to every physical cell. It is the same declaration for
native and WASM workers. A manifest without `partitions` has the same canonical
JSON, and so the same package hash, as before.

*The mapping.* `Atanor.Partition.index(partition_key, n)` is the first 8 bytes of
the SHA-256 of the partition key, read as an unsigned big-endian integer, modulo
`n`. It is a hash that is specified outside Erlang and has the same value on
every node, OTP version and language, so a guest or a tool can compute it, and
the data never moves because a runtime changed. Considered: `:erlang.phash2/2`
(portable across machines today, but its definition belongs to the VM and
is not promised for a future release), CRC-32 (its low bits are weak on short
keys) and xxHash or MurmurHash (a dependency for no gain: the cost is 1 to 2
microseconds a call, which is small next to a cell call). The modulo bias of a
64-bit value is below `n / 2^64`. Test vectors are pinned in
`test/atanor/partition_test.exs`, so changing the function breaks a test.

*Naming.* The physical cell of partition `i` is `{namespace, "<i>.<key>"}`, the
index in decimal without leading zeros: `{"events", "3.stream"}`, the Alambique
cell `events.3.stream`. The separator is a dot because every placement accepts
`A-Za-z0-9_.-` and `#` is not accepted. It cannot collide with a user key
because in a partitioned namespace **only physical keys are valid**: a key that
does not start with `<i>.`, `i` below `n` and canonical, is refused with
`{:partition_required, namespace}`. The index is read up to the first dot, so any
valid logical key (even one with dots) has exactly one physical form, and
`Atanor.Partition.split/1` returns the logical key and the index of any
physical key. This check is in `Atanor.Cell` (every cell call, so queries,
writes, transactions, jobs, alarms and the sweeps) and in `Atanor.Env` for the
sockets and channels, which do not touch the cell.

*Routing.* `Env.partition(env, {ns, key}, partition_key)` returns the physical
address, and `Env.partitions(env, {ns, key})` all `n` of them. A native worker's
`route_key/2` can return `{:cell, ns, key, partition_key}`: `Atanor.Dispatch`
resolves it to the physical address before it routes (§7.2), so the request
runs on the owner of that partition, and a request for another partition key runs
on the owner of another cell, perhaps on another node. Beyond the routing key
nothing in the cluster knows about partitions: forwarding, takeover, fencing,
hot cell placement (§8.15, which counts and moves each partition as its own
cell) and rendezvous placement see `n` ordinary cells, so the partitions of one
logical cell spread over the nodes by Alambique's placement. WASM workers have
no routing key; their cell calls are forwarded to the owner of the physical cell
like any other (§8.14). The host call is `partition` in
`atanor:cell/sql@0.1.0`, which runs `Env.partition/3` (§14.7).

*The number is fixed.* `n` cannot change while the namespace has data, because
every key would map elsewhere. There is no resharding. `Atanor.Deployments`
enforces it when a package is activated (`activate/4`, and the package a
`rollback/3` returns to), for each namespace the package grants:

| The store has | The package declares | Result |
| --- | --- | --- |
| nothing, and the namespace has no cell | `n` | records `n` in `partitions/<namespace>` (create-if-absent), then activates |
| nothing, and the namespace has cells in any location | `n` | `{:namespace_has_data, namespace}` (HTTP 409) |
| `n` | `n` | activates |
| `n` | `m` or nothing | `{:partitions_changed, namespace, n, m}` (HTTP 409; `m` is `nil` for nothing) |
| nothing | nothing | activates, no record |

The record is an object `partitions/<namespace>` under the instance's prefix in
the metadata store. The check of cells needs a running instance
(`Alambique.list_cells/2` in every location); an activation through a store
handle (a tool without a node) checks the record only. As a second line, two
active workers that grant a namespace must declare the same number, otherwise the
second is `{:namespace_conflict, namespace, worker}` (§4.1), which is also what
a node answers when it applies a head activated by other means. To change `n`,
use a new namespace and copy the data through the change feed (below); an
operator who is certain that a namespace holds no data can delete its record.

*Transactions.* A transaction is within one physical cell: Alambique has no
transaction across cells, and neither does a partitioned namespace. Everything
that must commit together shares one partition key. This is the design rule that
decides the partition key: it is the unit of atomicity and of serialization.

*Reading across partitions.* Two ways, both without a new mechanism:

* Scatter-gather: `Env.partitions/2` lists the `n` cells and the worker queries
  each one, merging the rows. It reads `n` cells, possibly on `n` nodes, each
  at its own point in time, so the result is not a snapshot of the logical
  cell. Use it for small `n` and not for a hot read path.
* The change feed (§16): `Env.changes/4` and `Env.subscribe/3` take the
  namespace, and the cell of an `Atanor.Change` is the physical key;
  `Atanor.Partition.split/1` gives the logical key. A worker that follows the
  feed builds the read model it needs (a table in another namespace, a cache)
  with one input from all `n` partitions, at least once and in order per
  partition, and not between partitions.

*Jobs, alarms, sockets, channels.* They attach to the physical cell, because the
address they take is the cell's. A job (§15) is a row in its partition cell and
runs on that cell's owner; enqueue it in the same transaction as the write it
belongs with, through `Jobs.enqueue/4` on the partition's `Tx`. An alarm (§7.4)
is one per worker per physical cell, so one logical cell has up to `n` alarms.
A socket attached with `Env.attach/2` receives `send_to_cell/3` only for that
partition, and the ephemeral channel (§7.6) of a partition is separate from the
others: to give every viewer of a logical cell one channel, publish to the
channels of the partitions the viewers joined, or join them all (`Env.partitions/2`
gives the cells). A bulk operation (§15.6) over the namespace runs once in every
physical cell, as it does for any namespace; there is no operation on a logical
cell. Telemetry and the admin API show physical cells.

*Measured.* In the lab (cluster lab, host load 25 to 50) 6
partitions spread the writes and the CPU of one cell over the three nodes and lost
no write, but did not raise the throughput over one cell; the store VM went from
56 to 71% to 150 to 184% of its CPU. The cause is inferred (more, smaller
replicated batches), not measured.

*Not done.* Resharding, a transaction across partitions, a unique constraint
across partitions (a unique index holds inside one cell), and a rule that picks
the partition from the request by itself (the worker chooses the partition key,
in `route_key/2` or in the handler).

### 4.3 Limits on cell calls and their errors

Alambique bounds what one call, one cell and one node may use. Atanor passes the
options through `alambique:` (unchanged, and checked at start: a key Atanor
does not know under these names, or a value of the wrong kind, raises
`ArgumentError`; `feed: false` is refused, see "Feed retention and what
reads it" below). Alambique's defaults apply to what is not
given, and Atanor keeps them, except for the feed groups below: they were chosen
and measured by Alambique, and they protect the node without a change in any
worker.

| Option under `alambique:` | Default | Meaning |
| --- | --- | --- |
| `sql: [statement_timeout_ms:]` | `op_timeout_ms` (10 000) | a statement of a worker that runs longer is interrupted; the cell keeps serving |
| `sql: [script_timeout_ms:]` | 60 000 | the longest a migration, a script and Alambique's own statements may run; a migration over it fails the wake with `{:error, {:migration, version, :statement_timeout}}` |
| `sql: [max_result_rows:]` | 100 000 | rows one statement may return (also `RETURNING`) |
| `sql: [max_result_bytes:]` | 67 108 864 (64 MiB) | bytes one result may hold (text and blobs by length) |
| `sql: [max_concurrent_statements:]` | dirty IO schedulers minus two, at least 1 | the most reads (owner, replica and cross-cell) running on the node at once, so commits keep dirty IO schedulers; a read over it gets `{:error, :busy}` at once, a 503 `overloaded` at the ingress. The count is shared by every instance in the VM: give them the same value |
| `awake: [max_cells:]` | 20 000 | cells with a process on this node; a partition counts as a cell. A call that would wake one more hibernates the least recently used cell with no caller waiting, and gets `{:error, :overloaded}` only when every awake cell has callers waiting |
| `awake: [max_wakes:]` | derived from the node's memory, else 256 (§4.3, memory of the wakes) | cells waking at once on this node; one more waits in Alambique's queue (`awake: [wake_queue_ms: 500, max_wake_queue: 4 × max_wakes]`, Alambique's defaults, checked by Atanor) and is `{:error, :overloaded}` when the queue is full or its time is up |
| `awake: [max_pending:]` | 10 000 | calls queued, running or waiting for an upload on one cell (other messages do not count) |
| `awake: [cache_kib:]` | 512 | SQLite page cache of each awake cell, in KiB (Alambique's `PRAGMA cache_size`; SQLite's own default is 2 000) |
| `awake: [max_bytes:]` | derived from the node's memory, else `nil` (no ceiling); see "Memory of the awake cells" below | ceiling on the page cache, schema and statements of all awake cells; past it the least recently used cells without callers hibernate before another wakes, and a call that finds none gets `{:error, :overloaded}` |
| `idle_timeout_ms` (top level of `alambique:`) | 300 000 | time without calls before a cell hibernates; a positive integer |
| `local_cache: [max_bytes:]` | derived from the disk budget (§4.4); Alambique's 21 474 836 480 (20 GiB) when the budget is unknown | size of `data_dir` above which the files of hibernated cells are removed, the least recently used first |
| `local_cache: [interval_ms:]` | `disk: [sample_ms:]` (5 000) with a disk budget, else 60 000 | time between those rounds; `local_cache: false` keeps every file |
| `wal: [checkpoint_bytes:]` | derived from the disk budget, 1 to 64 MiB (§4.4); Alambique's 67 108 864 (64 MiB) when the budget is unknown | size of an awake cell's `-wal` file above which it is checkpointed |
| `wal: [max_bytes:, budget_interval_ms:]` | derived from the disk budget (§4.4), `nil` (none) and 1 000 when the budget is unknown | the most the `-wal` files of all awake cells may hold; past it Alambique checkpoints the biggest first, and how often it checks (`disk: [sample_ms:]`, at most 1 000) |
| `compaction: [hold_bytes:]` | 33 554 432 (32 MiB) per instance | memory that keeps the files a cell just replicated, so the compaction of an awake cell reads them from memory and not from the store; 0 turns it off |
| `compaction: [hold_object_bytes:]` | 1 048 576 (1 MiB) | largest file held; a larger one is read back |
| `compaction: [snapshot_ratio:]` | 2.0 | a snapshot is taken when the level-0 bytes written since the last one reach this many times its size; a number above 0 |
| `compaction: [snapshot_interval_ms:]` | 604 800 000 (7 days) | longest time between snapshots of a quiet cell |
| `compaction: [snapshot_keep_ms:]` | 259 200 000 (3 days) | a new snapshot deletes the previous one unless that is at least this long after the one before it; 0 keeps every snapshot |
| `compaction: [delete_superseded:]` | `true` | delete the merged files once the next level replaces them |
| `compaction: [moved_scan_ms:]` | 60 000 | time between the scans of the store for the cleanups of moved cells that still wait |
| `compaction: [moved_scan_page:]` | 100 | markers listed per request of that scan (one request per tick) |
| `compaction: [max_level:]` | 2 | highest merge level (at most 8); a higher one keeps fewer, larger files for a restore |
| `replicas: [poll_max_ms:]` | 5 000 (Alambique's) | longest time between refreshes of a replica nobody reads: the interval grows to a quarter of the idle time up to it. Passed through, not checked by Atanor |
| `query: [reflink:]` | `true` (Alambique's) | refresh a cached replica from a copy-on-write clone where the file system has them; `false` always copies. Passed through, not checked by Atanor |
| `restore: [edge_bytes:, fetch_concurrency:, max_inflight_bytes:]` | 65 536, 16, 67 108 864 (64 MiB) | bytes read at each end of a file before the rest, files fetched at once, and the most bytes one restore holds from the store; the last two are derived from the node's memory when it has a limit (§4.3, memory of the wakes) |
| `lazy_restore: [min_bytes:]` | 4 194 304 (4 MiB) | a database smaller than this is restored whole; a larger one is restored lazily, page by page on the first queries. A cell of 5 MB whose first query reads most of it restores faster whole (166 against 215 ms in Alambique's bench): `16_777_216` does that. 0 is always lazy; `lazy_restore: false` turns lazy restore off. Its other keys are `concurrency` (4), `batch_bytes` (4 MiB) and `miss_pages` (16) |
| `feed: [object_batches:]` | 16 (Atanor's default; Alambique's is 1) | replicated batches one feed object may carry; 1 is one object per batch |
| `feed: [linger_ms:]` | 250 (Atanor's default; Alambique's is 0) | how long the publisher waits for more batches while a group is short; 0 never waits. At most a tenth of `feed: [window_ms:]` (10 000 by default) when `object_batches` is above 1; otherwise the instance does not start |
| `feed: [stop_publish_ms:]` | 5 000 (Alambique's) | how long a stopping cell waits for its sender to publish what it holds; 0 turns that off |
| `feed: [retention_ms:]` | 604 800 000 (7 days, Alambique's) | feed objects older than this are deleted; `nil` keeps them for ever. `feed: false` is refused |
| `feed: [tables:]` | `%{}` (Alambique's: every table captured) | `%{"table" => true \| false \| [omit: [columns]] \| [only: [columns]]}`: a table captured whole, not at all, without some columns, or with its key and only some. Table and column names are non-empty strings. The key columns are always captured. See "Feed selection" below |
| `feed: [other_tables:]` | `:capture` (Alambique's) | `:capture` or `:skip`: what happens to the tables `tables:` does not name |
| `feed: [max_object_bytes:]` | 268 435 456 (256 MiB, Alambique's) | the most a feed object may inflate to when read (objects are always zlib-compressed); a larger one is rejected as `:too_large` |

*Caps on the host calls of WASM workers.* A guest's calls cross the BEAM heap and
the NIF before the guest's memory limit applies, so `Atanor.Wasm.Host` caps two
of them with the node option `wasm:` (`Atanor.Config`):

| Option under `wasm:` | Default | Meaning |
| --- | --- | --- |
| `max_batch_bytes` | 67 108 864 (64 MiB) | total size of the results of one `batch`, text and blobs by length, 8 bytes for other values, column names included. The sum is kept while the statements run, without copying a result; the statement that passes it rolls the transaction back and the guest gets `failed("batch_too_large: ...")`. A batch holds at most this much plus one statement's result (itself under `max_result_bytes`) |
| `max_cell_message_bytes` | 1 048 576 (1 MiB) | largest message `send-to-cell` accepts from a guest; over it the guest gets `failed("message_too_large: ...")` and no socket receives it |

The limit on `send-to-cell` is only on the WASM host path. A native worker runs
inside the node, sends any term and shares the BEAM heap with the node, so it
is trusted like the node code; its message is not copied across a boundary. The
guest's message is bytes copied out of a sandbox, which is what the cap protects
(`channels.max_message_bytes` is the matching limit for `publish`). The rule
lives in one place, the `:send_to_cell` clause of `Atanor.Wasm.Host`; `Env`
does not check it, so what native workers may send is unchanged.

Snapshot, restore and lazy-restore defaults are Alambique's; Atanor keeps them and checks the keys above at start. They
bound what the store receives and what a wake reads: Alambique's
`docs/how-to-size-storage.md` and `docs/how-to-speed-up-a-wake.md` explain how
to size them, and `local_cache` (20 GiB) is what lets a node wake the same cell
again from its local file (about 114 ms against 166 ms for a full restore in
that bench).

*Feed retention and what reads it.* Atanor reads the change feed (§16: the
tailer, `Atanor.Env.changes/4`, rewind markers), so `alambique: [feed: false]`
(no triggers, nothing published) raises `ArgumentError` at start. Nothing in
Atanor reads feed history by age. A new tailer starts at the position of `:now`
(`lib/atanor/feed.ex`, `subscribe/3`) and only follows the end of the feed
(`lib/atanor/feed/tailer.ex`, `read_live/1`); a subscriber that starts earlier
catches up from the position it gives (`catch_up/1`). The undo of an operation (§15.10) does not read
the feed: it rewinds a cell to a TXID (`lib/atanor/sweeps/undo/rewind.ex`),
which depends on Alambique's `retention: [pitr_window_ms:]` (7 days), not on
`feed: [retention_ms:]`; only the rewind marker it publishes is a feed record.
So the only readers of old feed objects are the workers that store a position
and resubscribe with `from: position`: a worker that is down for longer than
`retention_ms` starts at the oldest object left and misses what was pruned
(§16.5). Seven days is enough for Atanor's own readers; raise `retention_ms`
when a worker must be able to be away longer.

*Feed selection.* Alambique lets the
instance choose what enters the feed. Atanor sets none
of it (every table captured) and checks the keys above at
start (`Atanor.Config`, same rules as Alambique's own check; a wrong shape raises
`ArgumentError` with the key and the expected shape). An app that does not want
a large column in the feed declares it, for example for a mail store whose
subscribers need only the headers:

```elixir
{Atanor,
 alambique: [feed: [tables: %{"messages" => [omit: ["body"]], "attachments" => false}]]}
```

An omitted column is never written to the cell's feed table, to the replicated
segments or to the objects. It is **absent** from `Atanor.Change.row` (not
`nil`), an `UPDATE` that changes only omitted columns publishes nothing, and a
subscriber that needs the value reads it from the cell. The key is unaffected.
Atanor has no consumer of its own that needs a column of a worker's table in the
feed, so start never refuses a selection: the only readers of `Change.row` are
the workers' (`Atanor.Env.changes/4`, `subscribe/3`); the tailer, the undo, the
dashboard and the CLI do not read it (`lib/atanor/feed.ex` builds the change and
`lib/atanor/feed/tailer.ex` only fans it out). Rewind markers (§16.6) do not
depend on `tables:`. A `tables:` entry that names an `_atanor_` table does
nothing: those tables are internal and never in the feed.

*Compaction and feed groups.* Holding is a local
optimization: with no row for a file, compaction reads it from the store as
before; nothing changes in the store. The feed
groups change the store: an object of a group is
`{"cell", "batches": [...]}`, not one batch. A reader outside the instance
(Alambique's feed API, Broadway) must use the same Alambique as the nodes.
Atanor groups by default: 16 and 250 unless
the operator sets them. §12.13 shows the requests fall (49% at 25 ms) and §12.14
that the delivery of a lone change grows by exactly `linger_ms`, on top of the
feed's settling time of about 14 s. Every stop with a valid lease hands the sender all
confirmed batches and waits for it to publish them, up to `stop_publish_ms`. A
crash, an expired lease or a failed hydration still leave the rows in the
cell's file for the next wake, as with `object_batches: 1`; the window in which a batch is
only in the file grows from about one store round trip to at most 250 ms plus
one. One condition: `linger_ms` stays well below `window_ms`. Atanor defines
"well below" as at most a tenth, checked in `Atanor.Config.build/1` whenever
`object_batches` is above 1: the default 250 is a fortieth of 10 000, and the
rule keeps an operator who lowers `window_ms` from lingering across it (a
`window_ms` of 1 needs `linger_ms: 0` or `object_batches: 1`; the tests do
that). The compaction hold needs
no such condition. The tailer needs
no change: `feed.page_size` already counts objects, so a page of a grouped feed
returns more changes than `page_size`, and the position stays that of the last
object read (`test/atanor/feed_test.exs`, "groups of batches"). A rewind drops
the batches of the rewound range that are still queued, so a worker may never
see them before the marker. To keep one object per batch, set `alambique: [feed: [object_batches: 1]]`. The
tests are in `test/atanor/alambique_limits_config_test.exs`.

A node with user-chosen cell ids should set `awake: [max_cells:]` for its memory
and file descriptors, and `data_dir` should have room for `local_cache:
[max_bytes:]` plus the cells awake.

*Memory of the awake cells.* The memory of a node grows with the cells awake on
it, not with its load (Alambique's design §12 measures it, and its
`docs/how-to-size-a-node.md` gives the rule and the options for 512 MB, 2 GB and
8 GB nodes). Atanor lowers the page cache to 512 KiB through Alambique's
default and derives the ceiling `awake: [max_bytes:]` from the memory limit of
the node, so a container with a limit needs no option:

| Option | Default | Meaning |
| --- | --- | --- |
| `memory: [limit_bytes:]` | `nil` | the memory limit of the node, when it is not the cgroup's. Overrides the detection |
| `memory: [awake_fraction:]` | 0.5 | share of that limit given to `awake: [max_bytes:]`, a number above 0 and at most 1. The rest is for the BEAM, the 150 KiB per cell that `max_bytes` does not count, the stores and the file cache |
| `memory: [cgroup_path:]` | `/sys/fs/cgroup/memory.max` | the cgroup v2 file read when `limit_bytes` is `nil`: a byte count, or `max` for no limit |
| `memory: [wake_fraction:]` | 0.5 | share of the headroom between the refuse mark and the limit that the wakes in flight may fill, a number above 0 and at most 1; derives `awake: [max_wakes:]`, `restore: [fetch_concurrency:]` and `[prefetch_bytes:]` unless given (below) |
| `memory: [refuse_fraction:]` | 0.85 | the ingress refuses with 503 while the working set is at least this share of the limit (§7.1, Admission); `nil` turns it off |
| `memory: [sample_ms:]` | 100 | how often the working set is sampled |
| `memory: [current_path:]`, `[stat_path:]` | `/sys/fs/cgroup/memory.current`, `memory.stat` | the cgroup v2 files of the working set |

The ceiling is, in order: the `awake: [max_bytes:]` the operator gave (`nil`
there means no ceiling), `limit_bytes * awake_fraction`, the cgroup limit
times `awake_fraction`, or none when the node has no limit, or the file is
missing or unreadable (`Atanor.Memory`). The node logs the value and where it
came from when it starts: `atanor: awake cells limited to 1073741824 bytes
(cgroup)`. In the container cluster (`cluster/compose.yml`) each node has
`mem_limit` (`ATANOR_CLUSTER_NODE_MEMORY`, 2g), so with the default fraction its
ceiling is 1 GiB. With `ATANOR_CLUSTER_TMPFS=1` the cell files count against
that limit too; give the node more memory rather than a larger fraction.
*Memory of the wakes.* A wake restores the state of a cell from the store, and
a store that fails makes it worse: an upload that fails stops the cell, and every
request that was waiting for it wakes it again, all at once. Admission cannot
see that, because the requests are already in. Reproduced on a node with a limit
of 768 MiB, 64 awake cells and about 520 requests in flight: when its store
began to answer 500, the BEAM memory grew by 215 MiB in 3 seconds and the
container was killed before the gate at 85% turned on. Alambique's defaults
(`awake: [max_wakes: 256]`, `restore: [fetch_concurrency: 16, max_inflight_bytes:
67_108_864]`) allow 256 wakes of up to 64 MiB each. So Atanor
derives the three from the node's memory unless the operator gives them, one by
one. Alambique 0.5 bounds what one wake holds, `max(max_inflight_bytes, largest file) + (fetch_concurrency + 2) × edge_bytes` (its design §6.3), so the
worst case of the wakes in flight is that times `max_wakes`:

```
budget         = limit * (1 - refuse_fraction) * wake_fraction     (nil when the node has no limit)
max_inflight_bytes = clamp(budget / 16, 1 MiB, 64 MiB)
fetch_concurrency  = clamp(max_inflight_bytes / 2 MiB, 1, 16)
max_wakes          = clamp(budget / (max_inflight_bytes + (fetch_concurrency + 2) * edge_bytes), 1, 256)
```

`edge_bytes` is the operator's `restore: [edge_bytes:]` or 65 536. From a budget
of one wake's cost (about 1.2 MiB) the worst case, `max_wakes` times that cost,
is at most the budget; below it the minimum of one wake stays over it. One file
larger than `max_inflight_bytes` is read alone and costs its own size, which no
option bounds: the derivation does not know the largest file of a cell, so a node
with larger files sets `max_inflight_bytes` to match (Alambique's how-to-size-a-node).
A wake over `max_wakes` waits in Alambique's FIFO queue (`awake: [wake_queue_ms:
500, max_wake_queue:]`) and holds no memory there; after the 500 ms, or when the
queue is full, it is `{:error, :overloaded}`, a 503 at the ingress. A wake that fails on the store backs
off (`wake: [backoff_ms: 200, ...]`, Alambique's defaults) and starts no new
restore during the delay, so the queue and the backoff add nothing to the wakes
in flight. Alambique's store breaker (`breaker: [failures: 5, cooldown_ms: 5_000]`,
`retry: [max_attempts: 10]`, defaults, not derived by Atanor) is what stops the
requests of a store that is down: with it open, calls and wakes get
`{:error, :store_unavailable}` at once, which `Atanor.Unavailable` reports as a 503
`store_unavailable` (§8.4), and a cell that failed on the store stays in backoff.

| Node | Budget | `max_wakes` | `fetch_concurrency` | `max_inflight_bytes` |
| --- | --- | --- | --- | --- |
| 512 MiB | 38.4 MiB | 14 | 1 | 2 516 582 (2.4 MiB) |
| 768 MiB | 57.6 MiB | 15 | 1 | 3 774 873 (3.6 MiB) |
| 2 GiB | 153.6 MiB | 15 | 4 | 10 066 329 (9.6 MiB) |

Cost, measured on Alambique 0.3.1 (before the wake queue, and with the derivation
of Atanor 0.3: 11 wakes), with the memory store and 25 ms added to every read (64 cells of
24 commits each, hibernated, then woken; 512 MiB node; the master-like row
gives the options Alambique defaults to: 256 wakes, 16 requests, 64 MiB). Not
measured again for 0.5, where a burst above `max_wakes` waits up to 500 ms in the
queue before it is refused:

| Options | One cold wake | 63 cells woken at once |
| --- | --- | --- |
| 256 wakes, 16 requests, 64 MiB (Alambique) | 89 ms | 147 ms, none refused |
| derived for 512 MiB (11, 1, 2.4 MiB) | 87 ms | 93 ms, 52 refused with `overloaded` |
| derived for 2 GiB (11, 4, 9.6 MiB) | 88 ms | 94 ms, 52 refused with `overloaded` |

With 150 commits a cell: 118 ms, 117 ms and 116 ms for one wake. The restore of
a cell takes about three round trips in sequence whatever `fetch_concurrency`
is, so one wake is not slower. The price is the number of wakes at once: a
burst of cold cells above `max_wakes` gets 503 `overloaded` with `Retry-After`
and the client retries, which is what bounds the memory. A node that wakes many
cells at once and has the room raises `awake: [max_wakes:]` or `memory:
[wake_fraction:]`.

The node logs them when it starts (`atanor: wakes limited to 11 at once; ...`).
A node that restores big cells and has the room can raise them, for example
`awake: [max_wakes: 32]`; a value in the option always wins. A node with a
limit also has the second guard of §7.1: while the memory gate refuses, a cell
call that would wake a cell (`Atanor.Cell`: no member of the instance holds it
awake, `Alambique.owner/3` with `peers: true` is `:none`) is a 503 `overloaded` with `Retry-After`
and starts no wake, and `Atanor.Admission.stats/1` counts them as `wake_refused`.
An admin call (hibernate, move) is not gated, so the node can still shed cells.
`owner/3` with `peers: true` asks the registries of the members, never the store
(a store that fails is how the node got here) and never wakes a cell, so a cell
owned by another node is forwarded, not refused; a cell that is still waking on
another node counts as held by nobody and is refused. Atanor does not build the store client (the operator
gives `Alambique.Store.S3` its config, whose `req_options` take the Finch pool),
so it bounds no queue of store calls. The tests are
`test/atanor/wake_burst_test.exs` (48 cells of 2 MB whose store fails: wakes in
flight 48 before the bound, at most 8 after, the 128 MiB node of the test), `test/atanor/wake_gate_test.exs`, `test/cluster/wake_gate_owner_test.exs` and
`test/atanor/memory_property_test.exs`.

Evictions are `[:alambique, :admission, :evict]` (telemetry.md), counted on the
dashboard's Metrics page, group Cells. The tests are
`test/atanor/memory_test.exs` and, for the node's memory staying flat as cells
wake, `test/atanor/awake_budget_test.exs` (about 12 seconds; it measures
`:erlang.memory/0`, so it is not async).

What a worker sees when a limit is reached. Native workers get Alambique's
error from `Atanor.Env` unchanged; a WASM guest gets the `failed` case of the
`error` variant of `atanor:cell/sql` (and of the jobs interface) with a message
that starts with the same code, `"<code>: <text>"`. The WIT variants are not
changed: a new case would not link with components built against the earlier
package.

| Alambique error | Native (`Env.query`, `execute`, `transaction`) | WASM `failed` message | Ingress, when the worker answers 5xx |
| --- | --- | --- | --- |
| `:statement_timeout` | `{:error, :statement_timeout}`; a transaction rolls back | `statement_timeout: ...` | the worker's own answer |
| `:result_too_large` | `{:error, :result_too_large}` | `result_too_large: ...` | the worker's own answer |
| `{:bad_params, message}` | `{:error, {:bad_params, message}}` | `bad_params: <message>` | the worker's own answer |
| `:overloaded` (`max_cells`, `max_wakes`, `max_bytes`) | `{:error, :overloaded}`; the call did not run | `overloaded: ...` | 503 `overloaded` with `Retry-After` |
| `:busy` (`max_pending`) | `{:error, :busy}`; the call did not run | `busy: ...` | 503 `overloaded` with `Retry-After` |

The first three are about the statement: repeating it fails the same way, so the
worker should narrow it (a `LIMIT`, an index, the right number of parameters) or
answer with a 4xx or 5xx of its own. The last two are backpressure: nothing ran,
and a retry after a moment is right. In a `transaction/4` function a statement
that returns `{:error, :statement_timeout}` (or the others) should be passed to
`Alambique.Tx.rollback/2` so that the call answers with the error. The tests are
in `test/atanor/cell_limits_test.exs`.

*`Alambique.Query` with `moved:`.* Alambique skips, by default (`moved: :skip`),
a cell that the placement has moved to another location when a query scans
`:all` cells or a `{:prefix, _}`, since the old copy is frozen at the move.
Atanor does not scan: its one use of `Alambique.Query` (the sample of an
operation at `at: :latest`, `Atanor.Sweeps`) gives the cell ids it wants, and
`moved:` does not apply to a list. The listings (`Alambique.cells/2`, used by
migrations and the overview) already list a moved cell once, in its new
location. So there is no call to change; a future scatter-gather over `:all` or
a prefix gets `:skip`, which is the right answer for it, without an option.

*The cluster cookie.* Atanor never prints it and commits none. Nodes of
`mix atanor.dev` take it from the `--cookie` of the `elixir` command (the
how-to uses the public value `atanor-demo` for a local demo); a release takes
it from `RELEASE_COOKIE` (the lab sets it from a file readable by the service
user only). Alambique's Mix tasks (`mix alambique.move`, `inspect`, ...) read
`ALAMBIQUE_COOKIE` when `--cookie` is absent, and the flag shows in the process
list: for a real cluster set the cookie in the environment of the process
(`RELEASE_COOKIE` for the nodes, `ALAMBIQUE_COOKIE` for those tasks), not in the
arguments. See [how-to-run-a-cluster.md](how-to-run-a-cluster.md).

*What the cookie protects.* The cookie is the only authentication between
nodes, and a holder runs any code on every node (`:erpc`), so it reaches every
tenant's data and secrets: it is a root password for the cluster. Distribution
is plain TCP: forwarded requests, with their `Authorization` headers and
bodies, and channel messages cross it unencrypted, and the nodes trust the
workers, deployments and cells that a peer names. Keep the distribution ports
(`epmd` 4369 and the range of `inet_dist_listen_min`/`max`) on a private
network, give the cookie its own random value (never the admin or dashboard
token), and use TLS distribution (`-proto_dist inet_tls` with
`-ssl_dist_optfile`, see the Erlang/OTP "Using TLS for Erlang Distribution"
guide) when the network is not private. The how-to has the steps.

### 4.4 The disk budget

*The problem.* Under continuous writes the `-wal` file of an awake cell grows
by 17 to 32 KiB a write. Alambique checkpoints it (SQLite `TRUNCATE`, so the
file shrinks to nothing) only when it passes `wal: [checkpoint_bytes:]` (64 MiB
per cell), SQLite's own autocheckpoint is off, the file is removed only when the
cell hibernates (`idle_timeout_ms`, which never comes under load), and the local
cache sweep never touches an awake cell. Its `max_bytes` is 20 GiB. Before
Alambique 0.4, nothing bounded the disk of a node: in a container with a 768 MiB `data_dir`, 20 cells
written without pause filled it in minutes, and the failed writes were 500s. With
Alambique's 64 MiB mark, 12 writers on 20 cells for 8 s (the load of
`test/atanor/disk_budget_test.exs`) made the files of `data_dir` 1.34 GB.

*The budget.* `disk: [max_bytes:]` is the number of bytes `data_dir` may hold.
When it is `nil` (the default) the node uses `disk: [fraction:]` (0.8) of the
size of the file system that holds `data_dir` (or its nearest existing parent):
`df -Pk`, run once when the options are built, through `disk: [probe:]`
(`path -> {:ok, bytes} | :error`, replaceable in tests). `df` was chosen over a
NIF for `statvfs`: Atanor's crate (`atanor_wasm`) is the WASM engine, a second
entry point would be one more thing to build and cover for a call made once at
start, and `df -P` is the same on GNU and busybox. When the size cannot be read
the node logs a warning and runs without a budget: Alambique's defaults stay, the
monitor is off, and the disk gate never refuses. The node logs the budget and
its source at start (`atanor: data_dir limited to 1073741824 bytes (option)`).
`Atanor.Disk.budget/2` is the function.

*The Alambique options it gives.* Unless the operator sets them:

| Option | Value |
| --- | --- |
| `wal: [checkpoint_bytes:]` | `budget / cells / 2`, at least 1 MiB, at most 64 MiB, and at most half the budget. `cells` is `awake: [max_cells:]` (20 000 by default) |
| `wal: [max_bytes:]` | the WAL allowance: `min(budget / 2, checkpoint_bytes * cells)`, at least 1. Alambique adds up the `-wal` files of the awake cells every `wal: [budget_interval_ms:]` (`disk: [sample_ms:]`, at most 1 000) and, at the allowance, checkpoints the biggest first (`Alambique.checkpoint/3`, which keeps the cell awake and truncates only what the store has) |
| `local_cache: [max_bytes:]` | the budget minus the WAL allowance, at least 1 |
| `local_cache: [interval_ms:]` | `disk: [sample_ms:]`: a cache that is trimmed once a minute cannot follow a small disk |

The allowance and the local cache never add up to more than the budget (the property tests in
`test/atanor/disk_property_test.exs`). With the default `max_cells` the floor of
1 MiB applies below about 39 GiB: every cell checkpoints at 1 MiB, about every 40
writes, which costs a checkpoint of a file that small. Lower `max_cells` to give
fewer cells a higher mark. The floor means that 20 000 cells at their mark can
hold more than the budget; the monitor below is what keeps the node under it.

*The monitor.* `Atanor.Disk` adds up the files under `data_dir` every
`disk: [sample_ms:]` (5 000; every second or less while escalated). It walks the
tree instead of asking the file system: that measures what the node holds
whether or not other files share the disk, and costs one `lstat` per file (the
local cache sweeps do the same each round). It escalates, with 5 points of
hysteresis, in a pure function (`Atanor.Disk.level/3`):

| Use of the budget | Action |
| --- | --- |
| `evict_fraction` (0.7) or more | hibernates idle cells (no call pending, `Alambique.load/2`), the ones used longest ago first (`last_used` of `Alambique.cells(instance, details: true)`), up to 64 per round, until the files of those cells would bring the use under the mark; the local cache then removes their files. The WALs are not its business: Alambique's budget keeps them under the allowance |
| `refuse_fraction` (0.95) or more | as above, and the ingress answers 503 `overloaded` with `Retry-After` to every new request (§7.1). Reads cannot be told from writes at the ingress, so all are refused until the use falls to `refuse_fraction - 0.05` |

*A full disk.* A write that SQLite refuses with `SQLITE_FULL` ("database or disk
is full", what an `ENOSPC` on the database or the WAL becomes) is Alambique's
`{:error, :disk_full}`, a 503 `overloaded`, not a 500: `Atanor.Unavailable`
maps the atom, also when a transaction function fails to match it
(`{:ok, _} = Tx.execute(...)`), as the `MatchError` carries the error.
A worker that handles that error inside a transaction and answers with a 5xx of
its own is not seen by the ingress: such a worker should roll back with the
error, as in §4.3. The test injects the full disk with `PRAGMA max_page_count`
(`test/atanor/disk_full_test.exs`).

*What bounds the use, and what does not.* The WAL mark bounds each awake cell;
the monitor bounds the node by the use it sees every sample, so the use can pass
the refuse mark by what the writes add between two samples (measured before the WAL
budget of Alambique 0.4, not again since: the budget test writes
to 20 cells at about 10 000 writes per second, 170 MB/s of WAL: with
`sample_ms: 100` a 12 MiB budget reached 18.8 MiB, with `sample_ms: 20` a 16 MiB
budget reached 14 to 15 MiB). Lower `sample_ms` for a disk that fast. The files of hibernated cells
are the local cache's to remove, so a node whose awake cells' database files
alone pass the budget (not their WALs) refuses until cells hibernate: raise the
budget or lower `awake: [max_cells:]`. The WAL allowance is checked once an interval, so the WAL files
can pass it by what the cells write in one.
Crash reports kept for a store that is down are capped by
`diagnostics: [max_bytes:]` (33 554 432), the oldest removed first (§17.2). The tests
are `test/atanor/disk_test.exs`, `disk_property_test.exs` and
`disk_budget_test.exs` (20 cells, 8 s of writes, budgets of 32 and 16 MiB).

## 5. Deployments and the store layout

Atanor writes its metadata through the `Alambique.Store` behaviour, in the
same store as the cells, under the operator's prefix (default `atanor`). With
`store:` and `prefix:` Atanor gives Alambique the prefix `<prefix>/cells`. With
a `placement:` the operator also names the `meta_store:` that holds the rest:

| Key | Content |
| --- | --- |
| `<prefix>/packages/<sha256>` | package bytes, written once with `If-None-Match: *` |
| `<prefix>/owners/<namespace>` | the worker that owns a cell namespace, written once with `If-None-Match: *` (§3.3) |
| `<prefix>/workers/<name>/head` | JSON: active id, previous ids, revision; replaced with `If-Match` |
| `<prefix>/alarms/<minute>/<shard>/<at_ms>/<worker>/<cell-id>` | alarm and job index entries, empty objects (§7.4, §15.3) |
| `<prefix>/meta/alarms/shards` | the alarm shard count, written on the first start (§7.4) |
| `<prefix>/operations/<id>` | one bulk-operation record and cursor (§15.6) |
| `<prefix>/crashes/<node>/<id>` | one crash report (§17.2) |
| `<prefix>/rehearsals/<id>` | one migration rehearsal record and report (§17.3) |
| `<prefix>/jobs/dead/<cell-id>/<job-id>` | dead-letter index entries (§15.4) |
| `<prefix>/cells/...` | alambique, with `store:` (a placement decides its own layout) |

Listings of the metadata store (worker heads) page with `metadata.page_size`
(1,000 by default).

### 5.1 Packages

`Atanor.Package` builds a package from a manifest and the worker's code. The
format is Atanor's own, not tar: `erl_tar` stamps entries with the current
time, and a simple format is easier to make deterministic and to validate.

```text
"ATANORPKG1\n"  then entries in byte order of their names:
  <<name_size::16, name, data_size::64, data>>
```

Entries: `atanor.json` (the canonical manifest JSON: sorted keys, defaults
filled in, including `manifest_version`); for a native worker `module.md5` (the
MD5, in hex, of `module.module_info(:md5)`, taken from the compiled project
by the deploy task); for a WASM worker the file named by `component`. There
are no timestamps, modes or owners, so the same inputs give the same bytes.
The package id is the SHA-256 (hex) of the bytes. `Package.parse/2` refuses an
`atanor.json` over the `package` option's `max_manifest_bytes` (262,144) and a
component over `max_component_bytes` (8,388,608) before decoding or compiling
them (options of `package:`, README). A native `module` is at most 255 bytes, and no atom
is created for it unless `<name>.beam` is on the code path:
`Package.load_module/1` uses an atom that exists, or creates it for such a file
and loads it, so an
upload (`Deployments.Service.upload/5`) that names a module the node does not
have is `{:module_not_loaded, name}`. `Package.parse/2` accepts
only what `build/2` produces: the magic, entries strictly sorted, exactly the
expected entries, a manifest that parses and is in canonical form, and a
valid MD5 or a component. A node verifies that the bytes it fetched hash to
the id it asked for.

### 5.2 Heads

```json
{"worker": "notes", "active": "<sha256>", "previous": ["<sha256>", "..."], "revision": 3, "updated_at": "2026-10-26T12:00:00Z"}
```

`Atanor.Deployments` works against any `Alambique.Store`:

* `publish(store, package)` writes the package once (an existing object with
  that hash is the same package);
* `activate(store, worker, id)` checks that the package is in the store and
  belongs to `worker`, then makes it active. The old active id goes first in
  `previous`, which keeps `:deployments`' `max_previous` (20). The same options
  can be passed to the function. Activating the active id changes nothing;
* `rollback(store, worker)` makes the newest `previous` active and removes it
  from the list; repeating it goes further back. `{:error, :no_previous}`
  when the list is empty;
* `deactivate(store, worker)` sets `active` to `null` and keeps the history;
  `rollback` then restores the last active package;
* `head/2`, `list/1`, `workers/1` inspect heads.

Every change reads the head, computes the new one and writes it with
`If-Match` on the etag it read (`If-None-Match: *` for the first head). On
`:precondition_failed` it reads again and retries, up to 16 times, then
returns `{:error, :conflict}`; so concurrent changes serialize, no update is
lost, and the revision grows by one per change. Any other write error is
returned as it is: the write may or may not have been applied.

### 5.3 Propagation

Every node runs `Atanor.Deployments.Watcher`. It loads all heads when the node
starts (before the HTTP ingress opens), reloads them every `:poll_interval_ms`
(default 5000), and listens on the `:pg` group `{Atanor.Deployments, prefix}`
of the scope `Atanor.PG`, which `Atanor.Application` starts. A change made
through a running instance (`Deployments.activate(MyApp.Atanor, ...)`, which
is what the admin API does) sends `{:head_changed, worker}` to the group, so
connected nodes switch at once; a change made through a store handle by a tool
outside the cluster reaches nodes at their next poll.
A lost notice is repaired by the poll.

Applying a head fetches the package (kept in memory while it is the active or
the newest previous package of a head), verifies its hash, parses it and
activates it through `Atanor.Workers.activate/2` into the registry. A head
that cannot be applied leaves the previous deployment serving and is recorded
per worker in `Atanor.Deployments.status/1` as `%{head: id, applied: id,
error: reason}`: `{:code_mismatch, expected_md5, loaded_md5}` when the node
runs other native code (ship the release first), `{:host_not_allowed, ...}`
or `{:listener_not_configured, ...}` when the operator does not allow a
route, a namespace or route conflict, or an invalid or missing package. The
head is not retried until it changes; store errors, and `{:module_not_loaded,
name}` (the node does not have the module yet), are retried at the next poll,
and the latter does not keep the node out of the first load. A native module
that is on the code path but not loaded is loaded on demand (an interactive
node does not load it at boot); its atom is created only when `<name>.beam` is
on the code path, so the atoms are bounded by the files the node has.

### 5.4 Commands

The `atanor` command (`Atanor.CLI`, reference in [cli.md](cli.md)) is a client of
the admin API (§10.2.1): `login`, `logout`, `deploy`, `activate`, `rollback`,
`status`, `versions` and `token`. Deployers hold an admin URL and a scoped
token, never the bucket credentials: the nodes write the store, through
`Atanor.Deployments.Service`. It is an escript (`mise run build:cli`) that needs
only Erlang, and keeps its profiles in `$XDG_CONFIG_HOME/atanor/config.json`
(mode 0600). The release and its image run the same module
(`bin/atanor-entrypoint`, §17.4), so there is one implementation.

`deploy --bucket s3://bucket/prefix` is the other way in, for a deployer that
holds the bucket credentials (a CI job in the same account as the cluster): it
needs no node. The command opens the store with `Atanor.Daemon.store/3`, which
applies the daemon's rules for the endpoint, the region and the AWS credential
chain, and calls `Atanor.Deployments.Service.deploy/4`, the same function the
admin API calls: the package, the version index (`atanor versions` lists it,
`uploaded_by` is `{"type": "bucket"}`) and, with `--activate`, the head. Nothing
tells the nodes: each applies the head at its next poll (`:poll_interval_ms`), the
way it applies one moved through a store handle (D1 holds as for any switch).
The two modes exclude each other (`--bucket` with `--url`, `--profile` or
`--timeout` is a usage error). A native worker is refused through the bucket:
`Service.upload/5` checks that the node holds the module, and with no node
nothing can, so a head could name a package no node can apply. WASM packages
carry their component and are always safe to publish this way. The cluster test
`test/cluster/deploy_bucket_test.exs` shows three peers serving a worker
deployed through a store handle with no peer told.

`deploy` builds the package on the deployer's machine with
`Atanor.Package.from_project/3`, the one implementation of package building. A
native package holds the MD5 of the module's object code; the command has not
loaded the project, so it reads the MD5 from the module's `.beam` file
(`:beam_lib.md5/1`, which equals `module_info(:md5)` of the loaded module; a test
checks it). It then uploads the bytes with their SHA-256, and the node checks
the size limit, the hash and the manifest before it stores anything. Deploying
a native worker needs the project compiled. `mix atanor.dev` and the test kit
deploy in-process through `Atanor.Dev.deploy/3`: they publish the package into
the node's store, activate it and wait for the node to apply it. The instance
has no `workers:` option.

**Guarantee D1.** A request resolves its deployment once, at ingress, and
carries it to the end, including when it is forwarded to another node. A
switch affects only requests that start after the node applied it. Nested
worker calls (§4) are pinned the same way, in the env, at ingress; the property
in `test/atanor/call_pinning_test.exs` interleaves activations with requests
that call a worker twice and checks that both calls see the version that was
active at the start. The StreamData property in
`test/atanor/deployments_property_test.exs` interleaves random activations and
rollbacks with requests that are held in the handler, and checks that each
request reports one deployment at its start and end, the one that was active
when it arrived.

## 6. Local development

`mix atanor.dev` also starts the dashboard (§10.3) unless `--no-dashboard`. It starts a single node with the workers of the current project,
over the alambique testkit memory store or the local SeaweedFS
(`--store seaweedfs`, container `atanor-seaweedfs` on port 18343, bucket
`atanor-dev` unless `--bucket`). It deploys `./atanor.json`, or each
`--manifest FILE`, into its store (§5.4) and prints the routes; without
manifests every request is a 404. To exercise `atanor deploy` and `rollback`
against a dev node, start it with `--admin-port` and `--admin-token`: the node
writes its own store, so the memory store works. The native module must be
compiled in the project that runs the dev node and in the one `atanor deploy`
reads. [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md)
walks through it.

## 7. Ingress and routing

### 7.1 HTTP

Routes match by host, then longest path prefix. The exact host is tried
first, then wildcard hosts from the most to the least specific (`*.a.test`
before `*.test`, never the bare `test`), then the catch-all host `*`, which
matches any `Host`, an IP address included; the first host with a route that
matches the path decides, so a host whose routes do not match the path falls
through to the catch-all. A prefix matches whole segments (`/api` matches
`/api` and `/api/x`, not `/apix`). The route's deployment is read once from
the routes table and travels in the env (D1). Operator configuration may add
routes to those of the manifests. The catch-all route is for a worker that
owns the whole ingress, or a load balancer or health probe that sends the
node's address as `Host`. It is an ordinary route key (`{"*", path}`), so it
conflicts only with another worker's route of the same host and path
(`{:route_taken, "*", path, worker}`), never with specific hosts.

Route hosts are subject to the operator's `hosts:` option, a map from worker
name to the host patterns that worker may claim (exact hosts, or `*.domain`
covering subdomains but not the bare domain, or `*`, which allows any host,
the catch-all route included; a route `*` is allowed by nothing else). A
manifest route outside its
worker's patterns fails the activation with `{:host_not_allowed, host,
worker}`; the other grants have their own consent (§3.3). A worker that is not in the map claims no host. When the option is
absent every host is allowed, which trusts the packages: do that only when
the operator deploys its own code (prior-art.md §6.6).

Routing and `auth:` rules (§7.5) see one canonical request (`Atanor.Route`),
which is also what workers receive. The host is lower case without the
trailing dot of a fully qualified name. In the path, a percent-escape of an
unreserved character (`%61` for `a`) is decoded and any other escape is kept
with upper-case hex; a Plug worker gets the same segments in `path_info`. The
request is 400 `bad_request` when the path has an invalid escape, an escaped
`/` or NUL, a `.` or `..` segment (escaped or not), more than
`http.max_path_segments` (64) non-empty segments, or when the host has more
than 253 bytes or `http.max_host_labels` (16) labels. The bound makes the
lookups a request costs at most (labels + 2) times (segments + 1), each over
sub-binaries of the same host and path, whatever the request line holds; a
request line of 8,000 bytes made of segments is answered 400 in a few
milliseconds.

*Admission.* A node refuses before it runs out of memory or disk (`Atanor.Admission`).
The first thing `Atanor.HTTP.call/2` does, before the route, the token and the
body, is ask three gates; a refusal is 503 `overloaded` with `Retry-After` and
the event `[:atanor, :http, :reject]` with `reason` `:memory`, `:disk` or
`:in_flight`. The disk gate refuses while `data_dir` holds `disk.refuse_fraction`
(0.95) of the disk budget (§4.4) and resumes 5 points below; `Atanor.Disk`
publishes each sample (`disk.sample_ms`) and the gate ignores one older than ten
periods, like the memory gate. A node with no budget has no disk gate.
The memory gate reads the cgroup every `memory.sample_ms` (100): the working set
is `memory.current` minus the `inactive_file` of `memory.stat`, so page cache
the kernel can drop never refuses, while tmpfs and shared memory still count.
It refuses at `memory.refuse_fraction` (0.85) of the limit and resumes 5 points
below, so the verdict does not flap. The limit is that of §4.3 (`limit_bytes`,
else `memory.max`); with none, or `refuse_fraction: nil`, the gate is off. A
sample older than ten periods is ignored (fail open): a dead sampler restarts
the node, since the supervisor is `one_for_all`, and a sampler that stalls
under CPU starvation must not keep a stale refusal; the in-flight gate still
bounds the node then. The in-flight gate refuses when `http.max_in_flight`
(1,024) requests are being served on the node. It is one ETS row per request
process and the table size is the count, so a handler that is killed (its
`after` does not run) is dropped by the sampler on its next tick and a slot
cannot leak. A WebSocket holds a slot only until the upgrade is answered; an
open socket is never closed by the gates. A request that is already in when the
gate turns on is not stopped, so while the memory gate refuses, a cell call for
a cell with no process on the node, which would wake it, is a 503 `overloaded`
(§4.3, memory of the wakes). The default of 1,024 is generous on
purpose: the memory gate is the guard, this one bounds handlers on a node whose
limit is large or unknown. In the load VM a node of 1 CPU and 512 MiB was
killed at 100 req/s native, 50 req/s WASM and 6,400 WebSockets with no
admission; `Atanor.Admission.stats/1` returns the counters for the admin
runtime page. The tests are `test/atanor/admission_test.exs` (the flood and
the cgroup files of a temporary directory) and
`test/atanor/admission_property_test.exs` (the pure decision function, the disk
gate included).

The listener is bounded: `http.max_connections` (16,384) is the total for the
listener, WebSockets included, divided among `http.acceptors` (10) because
ThousandIsland counts per acceptor; a client over the cap waits in the
accept queue of the operating system. `http.read_timeout_ms` (10,000) closes a
connection that does not send the next bytes of a header or a body in time.
It is a wait per read, not a deadline for the whole request: a client that
sends one byte every few seconds, or chunks of a chunked body, still keeps its
connection, and so many connections each. There is no limit per client
address; a reverse proxy or the firewall (`limit_conn`, `nft meter`) does that.
`http.http_2: false` serves HTTP/1.1 only. The admin listener has the same
settings under `admin:` (`max_connections` 128, `acceptors` 4); the dashboard
listener has none yet.

Failures are JSON and leak no internals: no route is 404, a body over
`max_body_bytes` (option of `{Atanor, opts}`, default 1,000,000) is 413, a
routing key that the placement cannot name as a cell (`invalid_key`: a
character outside `[A-Za-z0-9_.-]`, an id of more than 128 characters) is 400,
a
worker that raises, exits or returns something other than a valid
`Atanor.Response` is 500, logged with the worker and the deployment id.

#### Limits

**Slow and many clients are bounded per read and per listener, not per
client.** The bounds are described above. Bandit offers no deadline for the
whole request, so a reverse proxy or a firewall in front of the node must
enforce header and body deadlines and per-address limits (nginx
`client_header_timeout`, `limit_conn`; `nft meter`). `http.max_connections` and
`admin.max_connections` cap their listener only, so one address can use the
whole cap. Keep the dashboard, which has no cap, on loopback. Evidence:
`test/atanor/http_ingress_test.exs` (the cap and the read timeout hold).

### 7.2 Routing keys and dispatch

`Atanor.Dispatch` is the one path to a worker:

* `route(env, input)` asks the worker for `route_key(input, env) ::
  {:cell, namespace, key} | {:cell, namespace, key, partition_key} | :none`. The
  four-element form is for a partitioned namespace (§4.2): Dispatch turns it into
  the physical cell of the partition key (`Env.partition/3`) and routes to that
  cell's owner; a worker that returns the logical key of a partitioned namespace
  is as wrong as one that returns a namespace it is not granted. `input` is the `Atanor.Request` for HTTP
  and WebSocket upgrades, and `{:tcp, state}` for connections (§7.3). The
  namespace must be granted by the manifest and the key valid for the cell id;
  otherwise the work fails (500, closed connection) and the worker is logged.
  Plug workers have no routing key: the Plug runs on the ingress node.
* `execute(env, cell, call)` runs one callback: `{:http, request}`,
  `{:tcp_init, info}`, `{:tcp_data, data, state}`, `{:ws_init, request}`,
  `{:ws_in, message, state}`, `{:ws_close, state}` or `{:alarm, cell, payload}`. It takes plain data
  (the env holds the instance, the deployment and the socket pid; `cell` is the
  address or `nil`) and returns plain data, validated against the shapes of
  `Atanor.Worker`. It runs on the node that owns `cell` (§8); no caller keeps
  state that call needs. Without a cell, or on a node with no peers, it runs
  here. `{:ws_close, state}` runs when a socket ends: native workers have no
  callback for it (`{:ok, :ok}`), a WASM worker's `on-close` runs.
* The callback runs according to the deployment's kind. WASM deployments have
  no routing key and no TCP (activation refuses a `tcp` route with
  `{:unsupported_for_wasm, :tcp}`). Their HTTP goes through
  `Workers.invoke/2`; every other call goes to `Atanor.Wasm.execute/2`, which
  calls the exported handler in a fresh instance and returns what the native
  callback would return, so callers (`Atanor.Alarms`, `Atanor.HTTP.Socket`)
  do not know the kind. For WebSockets the state is the socket id (§7.3).

`Env.call/3` (worker to worker) goes straight to `Workers.invoke/2`: it stays
on the node, as §4 says.

### 7.3 TCP and WebSockets

**TCP.** The operator's `listeners: %{"smtp" => 2525}` maps names to ports
(0 picks a free port; `Atanor.TCP.port/2` tells which). The long form
`%{"smtp" => [port: 25, protocol: :ranch, tls_mode: :starttls, tls: [...],
acceptors: 10, max_connections: 16_384, ip: "127.0.0.1"]}` adds the server,
TLS, the bind address and per-listener limits. `:ip` is an IPv4 or IPv6
address, as a tuple or a string, and defaults to the ingress `ip`; an invalid
one raises `ArgumentError` at start, and an address the host does not own
fails the activation with `{:listener_failed, name, :eaddrnotavail}`; `:protocol` is `:thousand_island` (the default, the `handle_tcp/3`
path) or `:ranch`, and `:acceptors` and `:max_connections` default to their
`:tcp` values. A listener runs while an active deployment has a route
`{"tcp": {"listener": "smtp", "protocol": "thousand_island" | "ranch"}}`; a
route without `protocol` means ThousandIsland, and a route and listener that
disagree fail the activation. `workers: ["mail"]` in the long form says which
workers may claim the listener, and so its TLS certificate (`{:listener_not_allowed, name, worker}`
otherwise); without it any worker may, as with an absent `hosts:` (§3.3). A route to an unmapped name fails with
`{:listener_not_configured, name}`, a listener claimed by two workers with
`{:listener_taken, name, worker}`, and a port that cannot be bound with
`{:listener_failed, name, reason}`; in each case the previous deployment keeps
serving, except when the node starts: the watcher's first load (§2.1) runs
before `Atanor.TCP`, so the deployment is active and the listeners open when
`Atanor.TCP` starts, which logs one that cannot be bound as an error and leaves
it closed (`/routes` does not list it). `Atanor.Workers.activate/2` opens the new listeners before it
registers the deployment and closes the unclaimed ones after it, in the
watcher's apply path, so deployments switch listeners like they switch HTTP
routes. A switch keeps the listener; undeploying the worker closes it and ends
its connections.

**TLS.** A listener with `tls_mode: :implicit` runs ThousandIsland's SSL
transport, or `ranch_ssl` for a Ranch listener: the first byte the worker sees
is decrypted. `tls_mode: :starttls` accepts plain connections, and the worker
upgrades one when it wants (next paragraph). The `tls:` option holds
`:certfile`, `:keyfile` (required), `:cacertfile`, `:versions`, `:ciphers`,
`:verify` (`:verify_none`, or `:verify_peer` with `:cacertfile`),
`:fail_if_no_peer_cert` (true with `:verify_peer`, always passed to `:ssl`),
`:handshake_timeout_ms` (10 000) and `:reload_ms` (5 000). The files are read
and the key is checked against the certificate at start and at every reload; an
invalid listener config raises `ArgumentError`, so the instance does not start.
`Atanor.TCP.TLS` keeps the certificate, chain, key and CA certificates in
an ETS table; every new handshake passes the current ones to `:ssl`, which is what
makes a reload visible without restarting the listener. The process state
holds no key, so `:sys.get_state/1` and crash reports do not show it. Servers
refuse client-initiated renegotiation (`client_renegotiation: false`). A
thousand-island worker never sees the private key. A Ranch protocol that starts
TLS itself (gen_smtp `STARTTLS`) gets the `:ssl` options of the listener,
key included, in its start options and so in its process state: that module
is native code in the VM, which can read the key file anyway, but do not run a
Ranch protocol you do not trust on a listener with a key. WASM workers cannot serve TCP and therefore cannot use TLS
(§3.2).

A certificate is replaced without a restart. A per-instance watcher compares
the size, mtime and SHA-256 of the source files every `:reload_ms`; when they
change it validates the new pair and, if it loads, swaps the cache entries and
emits `[:atanor, :tls, :reload]`. A pair that does not load keeps the old
material, logs a warning and is reported with `result: {:error, reason}`; the
new signature is remembered, so a broken file is retried when it changes again
or when an operator asks. `POST /listeners/:name/reload-tls` on the admin API
forces one listener (§10.2). Connections that already handshook keep their
session; only new handshakes read the new material. This replaces the usual
`sni_fun` route: `sni_fun` is only called when the client sends SNI, and SMTP
clients often do not, so the per-handshake options cover every client.

**Ranch protocols.** A `"protocol": "ranch"` route needs a worker that exports
`ranch_protocol(env) :: {module, opts}`; without it the activation is refused
with `{:missing_callback, module, {:ranch_protocol, 1}}`. Atanor starts one
Ranch listener per claimed name, with `ranch_tcp` (plain or STARTTLS) or
`ranch_ssl` (implicit), `:ranch.start_listener/5`, the listener's acceptors and
max connections. Per connection `Atanor.TCP.Ranch` runs in Ranch's connection
supervisor: it resolves the deployment active at accept (the same D1 pinning),
builds the `Atanor.Env`, calls `ranch_protocol(env)` and starts the returned
`{module, opts}` through `start_link/3`. It adds `:atanor_env`,
`:atanor_listener` (the listener name, a string), `:atanor_tls_options` (the
current `:ssl` server options) and, on a STARTTLS
listener, `:tls_options` (the name gen_smtp reads) to the options; for the
gen_smtp `{callback, opts}` form it also puts `:atanor_env` and
`:atanor_listener` in `:callbackoptions`, which gen_smtp hands to `callback.init/4`. gen_smtp then
calls `ranch:handshake/1` and does its own STARTTLS with `ranch_ssl:handshake`
and those options, so Atanor's reloadable certificate reaches it too. Ranch is
optional like Phoenix: without the dependency the listener refuses the
activation with `{:listener_failed, name, {:missing_dependency, :ranch}}`.
Ranch connections emit the same `[:atanor, :tcp, :connect]` and `:disconnect`
events as ThousandIsland ones (`:disconnect` has the process exit reason as
`:reason`, without byte counts).

Each accepted ThousandIsland connection is a handler
(`Atanor.TCP.Connection`), and the worker API does not mention ThousandIsland:

* `tcp_init(info, env)` (optional) with `%{listener: name, peer: {ip, port}}`
  returns `{:ok, state}`, `{:reply, iodata, state}` or `{:close, iodata}`. The
  default state is `nil`.
* `handle_tcp(data, state, env)` gets each chunk of bytes as it arrives and
  returns `{:continue, state}`, `{:reply, iodata, state}`,
  `{:starttls, iodata, state}` or `{:close, iodata}` (send, then close).
  `{:starttls, bytes, state}` is only valid on a `tls_mode: :starttls`
  listener: the connection handler sends `bytes` (for example `220 Ready to
  start TLS`), runs `:ssl.handshake/3` with the cache's current options and
  the `tls.handshake_timeout_ms` bound, and continues with `state` over TLS.
  On a plain or implicit-TLS listener it closes the connection and logs it.
  Atanor does no framing; the worker keeps its buffer in `state` and decides
  what a line is.
* **Routing key.** While the connection is unbound, Atanor calls
  `route_key({:tcp, state}, env)` after every callback that continued the
  connection, with the state that callback returned. The first cell it names
  binds the connection: later callbacks run for that cell (§7.2) and the key is
  never asked again, so a rebind is not possible. A worker that needs the cell
  for a command (SMTP `RCPT TO`, IMAP `LOGIN`) stores the argument in `state`;
  the callback that parsed it runs unbound, the following ones bound. Asking
  after the callback and not before keeps Atanor from buffering or parsing
  protocol bytes.
* **Version pinning.** The connection resolves its deployment once, when it is
  accepted, and keeps it until it closes, like D1 for requests. A long-lived
  connection therefore keeps the old version after a switch; new connections
  get the new one.
* **Limits** (operator option `tcp:`, all positive integers): `idle_timeout_ms`
  (60,000) closes a connection that sent nothing for that long;
  `max_chunk_bytes` (65,536) is the most bytes one `handle_tcp/3` call gets
  (the socket's receive buffer; a longer line arrives in pieces, and the worker
  caps its own buffer by closing); `max_connections` (16,384) is the cap across
  the listener's `acceptors` (10). A listener overrides `acceptors` and
  `max_connections`; Ranch uses the same two numbers as its acceptor count and
  connection cap.
* A callback that raises, exits or returns another shape closes the connection
  and is logged; nothing of the error reaches the peer.

**WebSockets.** A request with `Upgrade: websocket` on a route of a worker that
exports `handle_ws/3` is upgraded through `WebSockAdapter` when `ws_init(request,
env)` (optional; default accept with state `nil`) returns `{:ok, state}`;
`{:reject, response}` answers the request instead. The request goes through
`route/2` and `execute/3` like any other, and the socket keeps the deployment
and the cell it started with. `handle_ws/3` gets `{:text, data}`,
`{:binary, data}` and `{:cell_message, term}` and returns `{:ok, state}`,
`{:reply, [{:text | :binary, data}], state}` or `{:stop, state}` (close 1000);
a failure closes with 1011. Limits (option `websocket:`): `idle_timeout_ms`
(60,000), `max_frame_bytes` (1,000,000, which also bounds a message spread
over continuation frames) and `max_frames_per_s` (100) with `frame_burst`
(200): a token bucket per socket, and a socket over it closes with 1008. A
socket on a protected route (§7.5) also closes with 1008 when the `exp` of its
verified token passes, a timer set at the upgrade from the claims header.

Attached sockets use the `:pg` scope `Atanor.PG`, group `{Atanor.Sockets,
prefix, namespace, key}`. `Env.attach(env, {ns, key})` joins the env's socket
process (the env carries it only inside WebSocket callbacks; elsewhere
`{:error, :not_a_socket}`), once however often it is called, and a socket leaves
when it ends. The node's `Atanor.Channels` server counts the attachments of a
socket with its monitors, and refuses one past `sockets.max_attachments` (16)
with `{:error, :too_many_attachments}`, because every `:pg` join is
replicated to every node. `Env.send_to_cell(env, cell, message)` sends `{:cell_message,
message}` to every attached socket on any node. Both need `sockets: true` and the
cell's namespace granted. Delivery is a plain message: it is not stored and not
retried, and a socket that is not attached at that moment misses it. `:pg`
joins only local processes. A WebSocket callback runs on the cell's owner (§8)
with the socket's pid in its env, and `Sockets.attach/3` then asks the
socket's own node to join it through `:erpc`, so sockets stay on the ingress
node and still receive `send_to_cell/3` from any node. The remote attach is
bounded by `sockets.attach_timeout_ms` (5 s); a timeout is
`{:error, {:unavailable, :owner_unreachable}}` and becomes the 503 of §8.4.

**WebSockets of WASM workers.** The host terminates the WebSocket exactly as
for native workers, and `Atanor.Wasm.execute/2` calls the exports of
`atanor:worker/socket-handler`, each in a fresh instance under the limits of
§9:

* `on-open(socket, request)` for the upgrade request returns `accept` or
  `reject(response)`; an error is a 500. The socket does not exist yet, so
  `attach` fails here with `not_a_socket`; a guest attaches in `on-message`
  (`join` in the test guest), as native workers do.
* `on-message(socket, message)` gets `text`, `binary` or `cell` (a message sent
  with `send-to-cell` to a cell the socket is attached to, always bytes) and
  returns the frames to send and whether to close afterwards (close 1000). An
  error, a trap or a limit closes with 1011 and is logged.
* `on-close(socket)` runs from the socket's `terminate`, for any reason; its
  failure is only logged.

*State lives in cells.* The socket process holds only the id, a random string
unique to the connection, which is passed to every call so the guest can
store it in a cell. This is the model of hibernatable WebSockets: the
connection is kept by the host and the guest wakes for each event, so no
instance is held for the life of a connection. The alternative, one
long-lived instance per socket, would hold a pool thread and its memory for
the whole connection and would not fit the per-call limits. The cost is that
a guest rebuilds what it needs from a cell on every message.

Cell messages are bytes for guests (`list<u8>`). A message that is not a
binary, sent by a native worker, is dropped for WASM sockets. Native and WASM
sockets attached to one cell are in the same `:pg` group and receive the
same messages. A WASM worker has no routing key, so its sockets are not
bound to a cell; the guest chooses cells with `attach`.

**Plug workers** (Phoenix, LiveView) upgrade inside their Plug with
`WebSockAdapter.upgrade/4`; the ingress returns the upgraded conn untouched
(`test/atanor/websocket_test.exs` proves it with a small Plug). Atanor's `ws_init`,
limits and attach do not apply to them. Phoenix and LiveView were not added as
test dependencies: a real LiveView mount needs an endpoint, a JavaScript client
or a hand-written socket protocol, which costs more than it proves beyond what
the Plug test does; this is a decision, not a limitation of the ingress.

### 7.4 Alarms

A worker has at most one alarm per cell, like Durable Objects: `Env.set_alarm(env,
{ns, key}, at_ms, payload)` replaces it, `cancel_alarm/2` removes it. `at_ms` is
milliseconds on the alarm clock (the system clock; the `alarms: [clock: ...]`
option takes any `Alambique.Clock` module, which tests drive with
`AlambiqueTestkit.ManualClock`). The payload is a binary. A time in the past
fires on the next tick. Both need `alarms: true` and the cell's namespace granted.

The row in the cell's table `_atanor_alarms(worker, at_ms, payload, attempts)` is
authoritative. The store's index holds one empty object per pending alarm, named
`alarms/<minute>/<shard>/<at_ms>/<worker>/<cell-id>`, where `minute` is
`at_ms / 60000` padded to 10 digits (lexicographic order is time order) and
`shard` is the hash of the cell id modulo 64. It lets a scheduler find due
alarms with list calls and without waking cells; the time in the name lets it skip
alarms of the current minute that are not due yet without touching their cells.

**Write order.** `set_alarm` writes the index entry first, then the row in a cell
transaction, then deletes the entry of the time it replaced. A crash between
the steps leaves a stale entry. An entry is valid only while the row has the
same `at_ms`; a stale entry (replaced, cancelled, finished, or never completed)
does nothing and is deleted once it is older than `timeout_ms`. The entry's
body is the time it was written. A scan that reaches an entry before its row
is committed cannot tell it from a stale one, and deleting it would lose the
alarm; the cluster suite found that (about one run in five, with a `set_alarm`
slowed by a node dying), so a due entry with a missing or different row waits
for `timeout_ms` after it was written, which bounds a `set_alarm`. `cancel_alarm` deletes the row and
then its entry.

**Scheduler.** Each node runs `Atanor.Alarms.Scheduler`, which every `tick_ms`
(1,000) lists `alarms/` oldest first, up to the current minute, page by page.
No cursor is kept: fired entries are deleted, so the next tick starts again at
the oldest. Only the shards the node owns are fired: the schedulers of a prefix
are the members of the `:pg` group `{Atanor.Alarms, prefix}`, and a shard
belongs to the member with the highest `phash2({shard, member})` (rendezvous
hashing), so one node owns all and a node that leaves moves only its shards. Views
of the group can differ for a moment, so ownership is an optimization and the
claim below is the safeguard. Two nodes that share a store and are not clustered (a node replacing
another, §8.11) each think they own every shard, and both scan. That is safe without a cluster: the claim is a
conditional `UPDATE ... WHERE at_ms = <the entry's time>` inside a cell transaction, which runs on the node that
holds the cell's lease. A node that does not hold the lease cannot run it (`held_elsewhere`, §8.4), so it fires
nothing and leaves the entry for its next scan; the node that holds it wins the claim once, and the entry is
deleted. When the first node hands the cell back, the second claims the entry at its next tick. Entries of a
worker with no active deployment on the node are left in place and wait.

**WASM workers.** The guest sets and cancels its alarm with
`atanor:cell/alarms` (`set-alarm(namespace, key, at-ms, payload)`,
`cancel-alarm`), which call `Env.set_alarm/4` and `Env.cancel_alarm/2`. When
it fires, `Atanor.Wasm.execute/2` calls `handle-alarm(namespace, key,
payload)` of the exported `atanor:worker/alarm-handler` in a fresh instance
under the limits of §9. `ok` is success; an `error`, a trap or a limit is a
failed attempt, retried as below (`reason` in the `[:atanor, :alarm,
:failed]` event is `{:guest, message}`, `{:trap, message}` or `{:limit,
kind}`). The task timeout of `timeout_ms` bounds the call from outside, so
setting the manifest's `limits.timeout_ms` below it gives the guest a clean
limit error.

**Firing is at least once.** For a due entry the scheduler (1) reads the row; a
mismatch is a stale entry; (2) writes the index entry of the retry time
`now + timeout_ms + backoff`; (3) in a cell transaction updates the row to that
time with `attempts + 1`, only if it still has the entry's `at_ms`, and so
claims it; a scheduler that lost the race finds no row and does nothing, which
is why two schedulers never run the same committed alarm twice; (4) deletes the
entry; (5) runs `handle_alarm({ns, key}, payload, env)` through
`Dispatch.execute/3`, outside the transaction because a handler may use the same
cell; (6) on `:ok` deletes the row if it still has the claimed time and
attempts, so a handler that set a new alarm keeps it. A handler may run more than
once: when the node dies or the firing exceeds `timeout_ms` (30,000, bounding
claim, handler and acknowledgment; the task is killed), the claim's retry time
passes and the alarm fires again. A handler that returns `{:error, reason}` or
raises is logged and retried at `now + backoff`, where backoff is 1 s doubling
to 60 s per attempt, up to `max_attempts` (5); after that the alarm is dropped
and the event says `final: true`. Handlers must be idempotent. At most once was
rejected: it loses the alarm when the node dies between the claim and the
effects, and a worker cannot make its own calls inside the claim transaction.
Options (operator `alarms:`): `tick_ms`, `timeout_ms`, `max_attempts`,
`page_size` (1,000 index entries per scan), `concurrency` (16 handler tasks),
`backoff_ms` (1,000), `max_backoff_ms` (60,000), `shards` (64) and `clock`.
The shard count is part of every index key: the first start records it under
`meta/alarms/shards` in the metadata store, and a later start with a different
value is refused.

Two Alambique instances in one VM cannot serve the same cells, so the unit
tests use a fake second member of the scheduler group and concurrent scans of
one instance; the cluster suite (§11) runs real nodes. That suite found that
`:erlang.phash2/2` of a pid differs between the pid's node and the others, so
two nodes ranked the schedulers differently and no shard was fired at all.
The rank now hashes the node and the local part of the pid, which every node
sees alike.

Alarms fire on the owner of the cell: `Dispatch.execute/3` sends the handler
to it (§8), whichever node's scheduler found the entry. Jobs add one reserved
row, `@jobs`, to the same table and index; the scheduler delegates it to the
jobs runner and it is hidden from the alarms page (§15.3).

### 7.5 Bearer tokens on a route

A route can require an OIDC access token. The configuration is the operator's,
not the manifest's: the issuer, the audience and the scopes are trust anchors,
and a package must not be able to name its own. The `auth:` option of
`{Atanor, opts}` lists rules, each naming a host pattern and a path prefix (as
the manifest declares a route, §7.1; a trailing slash of the path is dropped).
A rule covers every request whose canonical host and path (§7.1) match it,
whichever route serves the request, WebSocket upgrades and Plug workers
included: a worker's more specific route below a protected one (`/api/public`
under `/api`), a route of another worker and a request that only a decoding
router would send to the prefix (`/%61pi`) are all protected. When several
rules match, the most specific one applies, with the order of route matching:
host first (exact, `*.` suffixes from the longest, `*`), then the longest path
prefix. A request no rule covers is served as before, and an instance with no
`auth:` starts no process for it. A rule that matches no route protects
nothing, and nothing warns about it.

| Rule key | Default | Meaning |
| --- | --- | --- |
| `host`, `path` | `path: "/"` | The route, as in the manifest |
| `issuer` | required | `iss` must equal it exactly. https, unless `oidc: [allow_http: true]` |
| `audience` | required | A string or a list; `aud` (a string or an array) must contain one |
| `scopes` | `[]` | All must be present in `scope` (space-separated) or `scp` (an array, or a string) |
| `types` | any | Accepted `typ` header values, for example `["at+jwt"]`; case and an `application/` prefix are ignored. Set it: with `any`, an ID token that the same issuer signs for the same audience is accepted too |
| `algorithms` | `["RS256"]` | Allowlist among RS256/384/512, PS256/384/512, ES256/384/512 and EdDSA |
| `leeway_s` | 60 | Clock leeway for `exp`, `nbf` and `iat` |
| `realm` | none | The `realm` of `WWW-Authenticate` |

`Atanor.Auth.Token` is pure: header, key selection, signature, claims. Only
asymmetric algorithms exist, so a public key can never be used as an HMAC
secret, and `none` is not an algorithm. The header's `alg` must be in the rule's
list. A JWK is eligible only when its `kty` (and `crv`) fits the `alg`, its
`use` is `sig` or absent, its `alg` is absent or equal, and its `kid` equals
the header's (a header without `kid` tries every eligible key). A `crit`
header is refused. `exp` is required; `nbf` and `iat`, when present, must not
be later than now plus the leeway; `exp` plus the leeway must be later than now.
The checks run after the signature, and the scope check last, so a token that
is invalid in any other way is never answered 403.

`Atanor.Auth.Keys` (one process per instance, started when a rule exists)
holds the keys. A request reads them from an ETS table. A request that needs
a fetch (nothing cached, a `kid` that is not cached, keys older than
`jwks_max_age_ms`) calls the process, which serializes the fetches: 50
concurrent first requests make one discovery fetch and one JWKS fetch. The
discovery document at `<issuer>/.well-known/openid-configuration` must name
the same `issuer`, and its `jwks_uri` must have the issuer's scheme, host and
port; it is cached for `discovery_ttl_ms`. An unknown `kid` refreshes the JWKS
at most once per `min_refresh_ms` per issuer (60 s), so
a flood of forged `kid`s costs one fetch a minute. A failed fetch counts as an
attempt, and the next one waits `error_backoff_ms`. Expired keys that cannot
be refreshed keep serving for `jwks_max_stale_ms` (24 h) more, so a key that
the provider withdrew does not verify for ever while the provider is
unreachable; with no keys at all the answer is 503
`auth_unavailable` with `Retry-After`, not 401. A fetch goes through
`Atanor.Egress.send_request/3`, the reader that bounds `Env.fetch/3`: it uses
a deadline of `connect_timeout_ms` plus `receive_timeout_ms`, follows no
redirects and stops reading at `max_response_bytes`, so an oversized body is not
buffered.
`Atanor.Auth.Keys.flush/1` drops every cached discovery document and key set
of this node and clears the refresh and backoff clocks, so the next request
fetches at once; `POST /auth/keys/flush` on the admin API calls it
(`cluster:admin`, logged, `[:atanor, :admin, :action]`). It acts on the node
that answers, as `POST /drain` does, so a cluster needs one call per node.
`oct` keys in a JWKS are dropped. There is no introspection: a request never
calls the provider.

Limitations: a rule cannot set the `jwks_uri` itself (discovery is the only way), and one process serializes the fetches of all issuers, so a slow issuer delays the first fetch of another for up to its timeouts.

Rejections never reach the worker. No credentials (no `Authorization`, or
another scheme) is 401 with `WWW-Authenticate: Bearer` and no error code
(RFC 6750 §3.1); a duplicate header, or a `Bearer` with an empty or malformed
token, is 400 `invalid_request`; a bad token is 401 `invalid_token`; missing
scopes are 403 `insufficient_scope`, whose challenge names the required
`scope`. The JSON body carries only the error code. Neither the token nor a
claim is echoed, logged or put in telemetry, whose `reason` is an atom
(`[:atanor, :auth, :reject]`, `[:atanor, :auth, :fetch]`).

The verified claims reach every kind of worker as plain data in the
`x-atanor-claims` request header: the claims JSON, base64url without padding.
`Atanor.Request.claims/1` decodes it for native workers; a WASM guest or a Plug
reads the header. The header is Atanor's: the ingress removes every copy of
`x-atanor-claims` that a client sends, on every route, before it sets its own
(a protected route) or leaves it absent. `Atanor.Env.call/3` removes it from
the request a worker passes to another, so a worker cannot present claims
Atanor did not verify; route rules do not apply to calls between workers (§4:
a `workers` grant lets a worker act as an unauthenticated client of the
other), and the callee sees no end user unless the caller puts the identity in
the request itself. The WIT interfaces did
not change, and the header survives forwarding to the cell's owner like any
other.

Atanor applies no provider-specific rule. `org_ids`, `act`, `sub == client_id`,
the meaning of a scope or of a `typ` beyond the configured list: those belong
to the worker, which reads the claims.

#### Limits

**A route's `types:` defaults to any `typ`.** Many providers issue access tokens
with `typ: JWT`, so a stricter default would break them, and with `any` an ID
token that the same issuer signs for the same audience passes as an access
token. Workaround: set `types:` on every rule to what the provider issues
([how-to-protect-a-route-with-oidc.md](how-to-protect-a-route-with-oidc.md)).

### 7.6 Ephemeral channels

A cell has an ephemeral channel: messages for the sockets that joined it, on any
node, that are never written to the cell, run no transaction and need no call on
the cell's owner. They are for presence, signals and cursors. How to use them:
[how-to-share-ephemeral-messages.md](how-to-share-ephemeral-messages.md).

*Membership and fan-out.* `Atanor.Channels` joins the socket process to the
`:pg` group `{Atanor.Channels, prefix, namespace, key}` of scope `Atanor.PG`.
`:pg` joins local processes only, so a join made by a callback on the owner
(`Env.join_channel/3`, which needs the env's socket) asks the socket's node with
one `:erpc`, like `Sockets.attach/3` (§7.3), and membership lives on the node
that holds the socket. A node runs one `Atanor.Channels` server, which also counts
what its sockets joined for the limits and monitors them. `Env.publish/3`
reads the group's members (`:pg` has already replicated them), sends the frame
to the members on its own node, and sends **one** message to the
`Atanor.Channels` server of every other node that has members; that server sends
the frame to its local members, where the socket pushes it out as a frame. The
cost of a publication is one distribution message per node plus one local send
per socket. Nothing is stored, so there is no replay: delivery is at most once,
to the sockets in the channel at that moment.

*Order.* The messages of one publisher process reach each subscriber in the order
sent: a publisher sends to a subscriber either directly (same node) or through
one server process, and Erlang keeps the order between two processes. There is no
order between publishers.

*One implementation of fan-out.* `Atanor.Sockets.send_to/3`, which delivers
`send_to_cell/3` messages to the sockets attached to a cell (§7.3), uses the same
`Atanor.Channels.broadcast/2`, so it too sends one message per remote node
instead of one per socket. The two APIs stay separate because they mean
different things: a cell message is delivered by running `handle_ws/3` on the
owner, with access to the cell, once per attached socket (the worker transforms
it, may write, and may reply); a channel message is a frame that goes straight
out of the socket's node, with no worker code. Moving `send_to_cell/3` onto the
channel would remove that callback, which is what the API promises. What the two
do the same, they do with one implementation: the `:pg` group, the remote call
(`Channels.remote/5`) and the broadcast.

*From the client without the owner: `handle_ws_local/3`.* Every frame a client
sends was one callback on the owner (§8.14). A channel would not help clients that
publish if each publication still needed that callback. The worker may therefore
implement `handle_ws_local({:text | :binary, data}, state, env)`, an optional
callback that `Atanor.HTTP.Socket` runs in the socket's process, on its own node,
before it sends the frame to the owner. It returns `:pass` (go on to `handle_ws/3`
as before) or `:drop`. It publishes with `Env.publish/3`, so the worker validates
the frame, shapes it and stamps who sent it before anyone sees it; `state` is the
one `handle_ws/3` last returned. The env passed to it has `local: true`: every
cell function returns `{:error, {:not_granted, {:cell, namespace}}}`, which is
checked in one place (the cell grant check of `Atanor.Env`), and the owner is not asked
for anything. Alternatives that were rejected: a declarative option
(`ws_init` or the manifest names a channel and the socket relays frames as they
are) cannot validate or stamp, and a worker that does need the owner for some
frames would have to split them by a prefix the node would have to know. A
callback keeps the worker in control with the smallest surface: one function, and
the same `publish` that every other caller uses. A worker without the callback
behaves as before. The callback's cost is a call in the socket's process for
each frame, so it should be short.

*Delivery to the socket.* The frame goes out as it was published. There is no
transform on delivery: the worker shapes the message once when it publishes, not
once for each socket, which is what keeps the cost off the owner. A worker that
needs per-socket treatment uses `send_to_cell/3`.

*Presence.* `Env.channel_members/2` reads the group (`count`, the number of
members on every node) and asks each node that has members for the ids its
members joined with (`id:` of `join_channel/3`, none for an anonymous member).
It is read when asked; there is no replicated presence state and no merge, so
a node that does not answer within `sockets.attach_timeout_ms` makes the call
fail with `{:error, :node_unreachable}` instead of returning part of the list.
A remote join or leave fails the same way. (`Sockets.attach/3` keeps its
`{:unavailable, :owner_unreachable}` and the 503 of §8.4, because the attach is
part of a request that the owner is serving.) A
worker that wants to push presence changes publishes them.

*Limits* (operator option `channels:`, positive integers): `max_message_bytes`
(16,384, per message; over it `{:error, :too_large}`), `max_subscriptions` (16
channels per socket), `max_channels` (10,000 channels with a member on one
node), `max_channels_per_namespace` (2,000 of them in one namespace, so that
the workers of one namespace cannot use up the node's channels for the others)
and `max_queue` (1,000 messages waiting in a member's mailbox; see slow
subscribers). They are checked by the node's server, so a count is exact for the node.
A remote join is bounded by `sockets.attach_timeout_ms`.

*Slow subscribers.* A message goes to the socket process's mailbox, and the
process writes it to the connection. Local delivery, which is one function used
by the publisher for its own node and by the node server for the messages it
relays, skips a member whose `message_queue_len` is over `max_queue` (default
1,000) and counts it in `[:atanor, :channel, :dropped]`. The member misses that
message only; it receives the next ones once its queue is down. The default is
about half a minute of backlog at the 30 messages per second a socket received in
the lab (§12 results, section 9.1), and at most 16 MiB (`max_queue` times
`max_message_bytes`) per socket. The check applies to `send_to_cell/3` messages
too, since they go through the same function (`Atanor.Sockets` calls
`Channels.broadcast/3`) and a backlog there costs more: every queued message is a
callback on the owner. Both were already at most once, so the skip changes
nothing a worker could rely on. The publisher is never slowed down; the check
reads the mailbox length of each local member, a constant cost per delivery.

*Permissions.* `Env.join_channel/3`, `leave_channel/2`, `publish/3` and
`channel_members/2` need `sockets: true` and the cell's namespace in `cells`,
like `attach/2` and `send_to_cell/3`. Publishing and presence work in the local
callback, where the other cell functions do not. TCP connections cannot join: a
channel member is a WebSocket process (`handle_info` receives `{:atanor_channel,
frame}`), and TCP bytes have no frames.

*WASM.* `atanor:cell/sockets@0.1.0` gains `join-channel`, `leave-channel`,
`publish(namespace, key, message)` with `message = text(string) |
binary(list<u8>)`, and `channel-members`; they call the same `Atanor.Env`
functions through `Atanor.Wasm.Host` (§14.7). The local callback is the optional
export `atanor:worker/socket-local@0.1.0`, `on-frame(socket, frame) -> pass |
drop`, found when the component is prepared like the other handlers (§14.8) and
called in a fresh instance on the socket's node (`Dispatch.execute_local/3`,
call kind `:ws_local`). A component that exports it must also export the socket
handler. `scripts/build-wasm-fixtures` builds the test guest `channel`.

*Telemetry.* `[:atanor, :channel, :publish]`, `[:atanor, :channel, :rejected]` and
`[:atanor, :channel, :dropped]` (telemetry.md).

*Measurements.* The lab measured the effect on a hot cell
([how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md)).

*Tests.* `test/atanor/channels_test.exs` (limits, permissions, the local callback,
WASM host calls) and, on three peers, the property E1 in
`test/cluster/channels_test.exs`: random sockets on random nodes, random
publishers on random nodes (client cursor frames and worker processes) and
random leaves; every socket receives each message published while it was in the
channel, once, in the order of each publisher; the cell's position (txid and
data) is the one it had before; the owner ran a callback only for each join and
leave. Breaking the broadcast so that it skips a node makes the property fail.

## 8. Cluster

Nodes run an instance with the same `name`, `prefix` and placement over the
same store. The nodes find each other through the store ([§8.16](#816-discovery-through-the-store)),
or the operator connects them (`Node.connect/1`, a cluster library, or `mix atanor.dev --connect`). Alambique already forwards a cell call to the cell's owner, so a worker
that runs anywhere reads and writes correctly. Atanor goes further and runs the
worker callback on the owner, so its cell calls are local and its CPU is spent
where the data is. [how-to-run-a-cluster.md](how-to-run-a-cluster.md) shows it.

### 8.1 Finding the owner

`Dispatch.execute(env, cell, call)` with a `cell` and at least one connected
node (`Node.list() != []`; alone, a node runs everything at once) asks for the
node that owns the cell:

1. `Alambique.owner(instance, cell, hint: true)`: a process on this node
   answers `{:ok, node()}`; otherwise Alambique's own owner-hint cache answers
   without a store request, and fills the cache from the lease when it has no
   entry. A lease held by a node that is gone is `{:error, {:unavailable,
   owner, expires_at_ms}}`.
2. `:none` means the cell is asleep. `Atanor.Cell.owner/2` is then
   `Alambique.touch/3`, which wakes the cell on the node Alambique prefers
   (rendezvous hashing) and names the node that serves it.

A retry asks `Alambique.owner/3` with the hint first, which drops a hint to a
node that is gone (a `touch` would try to reach it, and a connection attempt to a
lost host can take seconds: in a local three-node demo a request in flight when the owner froze
waited 7 s for that), and then calls `touch`, which routes to the owner and
corrects the cache. An `{:error, {:unavailable, ...}}` from either lookup is
where the early takeover of a lost node's cell starts (§8.10).

An owner other than this node gets the call forwarded.

### 8.2 Running the call there

The call is sent with `:erpc` to `Dispatch.remote/9` with plain data only:
instance, worker name, deployment id, the socket pid, the nested-call depth,
the cell, the call and a reference. It is never a deployment struct, which
holds a NIF resource. The remote node:

1. checks that it owns the cell (`Alambique.owner/2`, a local lookup when it
   does), otherwise answers `{:moved, node}` and runs nothing: the caller
   asks the owner again (a stale hint costs one retry);
2. resolves the deployment by id (§8.3), otherwise answers `{:rejected, reason}`;
3. sends the caller `{:atanor_started, ref}` and runs the callback through the
   same code as a local call, and answers `{:executed, result}`. The caller no
   longer reads the message: it connects to the node before it calls, so any
   failure of the call counts as a call that may have started (§8.4). The
   message stays so that the protocol does not change.

The result has the plain-data shape of a local `execute/3`. The ownership check
and the start of the callback are not atomic: the cell can move in between.
Alambique's fencing still guarantees that no cell effect is applied by a node
that does not hold the lease, so such a callback fails on its first cell call;
only effects outside the cell (outbound HTTP, a message to a socket) can happen
on a node that has just lost it. This is a limit, not a proof of C1 for those
effects (limits of §8.13); §8.13 bounds the window
and says what to do about such effects.

The exception is a request that the worker declared bounded (`route_key/2`
returns `consistency: {:bounded, ms}`): it runs on the node that received it and
is never sent to the owner, and it may only read (§19.3).

### 8.3 One deployment across nodes (D1)

The request resolved its deployment at ingress and sends its id. The remote
node uses its active deployment of the worker when the id matches; otherwise
`Workers.pinned/3` fetches the package by id from the store, builds it as a
deployment apart from the registry (no routes, no listeners, no replacement of
the active one) and keeps it in a table of `routing.pinned_limit` pinned
deployments (16 by default). The two
choices for a node that does not have the id were:

* fail with 503 and let the client retry: simple, but every switch would
  answer 503 to the requests that cross nodes while the nodes converge, which is
  a mix of old and new on every rollout;
* fetch and pin: chosen. A request is never refused because the nodes switch at
  different moments, and it never runs on another version. The cost is one
  store read and a build the first time a node sees a version, and a node
  that cannot build it (native code it does not have: `{:code_mismatch, ...}`)
  rejects, which is a 503 for that request: a release roll comes first.

Properties of a switch, tested in `test/cluster/properties_test.exs`: random
switches on the ingress node only, the owner only or both, random rollbacks,
and requests held in the handler while this happens; every request reports one
deployment at start and end, the one the ingress had applied when it arrived.

#### Limits

**A forwarded request needs the node to be able to build its deployment.** A
node that lacks the native code of the deployment the ingress pinned (the
release was not rolled to it) answers 503 `unavailable` in both directions,
while the two versions run side by side. Workaround: roll the
release to every node before the deployment switch, as
[how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) says.

### 8.4 When the node is lost

Every forward ends in one of these, reported by the `[:atanor, :forward]`
event:

| Outcome | Meaning | What the ingress does |
| --- | --- | --- |
| `:ok` | the callback ran and answered | returns the result |
| `:moved`, `:rejected` | the node did not start the call | `:moved`: asks for the owner and tries again; `:rejected`: `{:error, {:unavailable, reason}}` |
| `:lost` | the call was never sent: the detector has the node down or its link broken (§8.8), or there was no connection and connecting failed | asks for the owner and tries again |
| `:unknown_outcome` | the callback started and the connection failed or the call timed out (60 s) | see below |

A call sent over a connection that then fails may have run: the node can still
receive what the kernel had buffered after the sender gave the connection up (a
silent partition, see [§12.6](#126-cluster-lab)). So a
call counts as started once the connection exists: the caller connects first
(it does not let the call connect by itself), and only a call that was never
sent (connecting failed) is retried as `:lost`. Letting the call connect was
wrong: it could start the handler, lose the link before the start message
arrived, and be repeated inside one job attempt. A **timeout** always counts as
started, because the node may still be running it.

Alambique has the same notion one layer down. A cell call that Alambique forwards
(a Plug or WASM worker, which run on the ingress node; a call after a stale hint)
and whose connection fails after it was sent answers `{:error, :outcome_unknown}`
and is never repeated, unless the caller passes `idempotent: true` to
`Env.execute/4` or `Env.transaction/4`. `Atanor.Cell` marks the request when it
sees that answer, and if the handler then fails (a response of 500 or more, or a
crash) `Atanor.Dispatch` replaces the failure with `{:error, :unknown_outcome}`:
the same 503 `unknown_outcome`, never a 500 and never a repeat. A handler that
handled the error and answered below 500 is left alone. The WASM `sql` import has
no `idempotent` option, for the reason it has no `verify_lease` (§8.12); WASM
writes are therefore never repeated by Alambique.

For an unknown outcome the ingress does not run the call again unless the call
is idempotent: an HTTP `GET`, `HEAD` or `OPTIONS`, or an alarm (delivered at
least once, §7.4). Any other call, such as a `POST`, TCP data or a WebSocket
frame, returns `{:error, :unknown_outcome}`: HTTP answers 503
`{"error": "unknown_outcome", "reason": "unknown_outcome"}` and a connection or
socket closes, so a client that cares has to look at the state. Retries are
three attempts 50 ms apart (`routing: [attempts:, retry_ms:]`)
with a fresh owner lookup each. When the lookup finds the lease held by a node
that is gone, the answer depends on the detector: if the node is confirmed down
the cell is taken over at once and the call runs (§8.10); otherwise (the node is
not yet confirmed, takeover is off, or this node has no quorum) the lookup fails
with `{:unavailable, reason}` until the lease expires (30 s by default,
`lease_ttl_ms`).

A node of another store is not unavailability. When a call reaches a node that
runs the instance over another store or prefix (a stale hint, or a restart that
changed the locations), Alambique answers `{:error, {:foreign_store, node}}`
and drops the hint (Alambique design §8). It means the nodes disagree on where
the data lives, so repeating the call does not help. Atanor keeps the error as
it is: it is not retried, not turned into `owner_unreachable` and not in
`Unavailable.reasons/0`. HTTP answers **500**
`{"error": "foreign_store", "reason": "foreign_store"}` with no `Retry-After`,
also when the worker maps the cell error to its own 5xx. The node that detects
it logs an error naming the foreign node and emits
`[:atanor, :foreign_store]` (`count`; `instance`, `node`); the call's
`[:atanor, :call]` event carries `reason: {:foreign_store, node}`. Alarms and jobs treat it as any
failed attempt: their backoff retries it, and `reason` or `last_error` names
it. Fix the configuration: every node of an instance needs the same store
(location, not credentials) and placement. Atanor itself defines no store or
placement. Alambique's optional `Store.location/1` and the start-time check
that `locations/1` answers a non-empty list apply to the operator's own
stores: a placement that fails there stops the instance from starting, with
Alambique's `ArgumentError` as the reason.

An expected unavailability is a 503 that names the reason and carries
`Retry-After` (seconds, `http.retry_after_s`, 1 by default): `no_quorum` (this
node is not a majority), `owner_unreachable` (the owner is not reachable and not
confirmed down), `owner_down` (confirmed down but the cell was not taken over),
`draining` (this node hands its cells off and does not wake the cell),
`held_elsewhere` (a node outside this cluster holds the cell's lease, with its own `Retry-After`: see below),
`fenced` (a lease was lost, expired or fenced), `overloaded` (the WASM queue is full),
`store_unavailable` (the store did not answer a request that a job's transaction needed, and the
transaction was rolled back) or `deployment_unavailable` (the node cannot build the pinned
deployment). A
worker that maps the cell error to a 5xx still gets that 503; 500 stays for
defects.

`held_elsewhere` is the answer while two nodes that are not a cluster take turns on a cell (§8.11):
the lease names a node that is no member of this instance's cluster, so this node waits for the lease
and never takes the cell. Its `Retry-After` is `http.retry_after_s` (default 1), on every path (a worker with no routing key does not
name the cell, so the lease's expiry is not known there, and a swap is over within seconds, not at the expiry). A drain releases
the lease, so the wait is normally one retry; after a crash a client polls until the lease ends (the TTL plus the skew margin). A WebSocket upgrade gets the same 503 and header before the upgrade. A TCP connection
has no `Retry-After`: it closes, and `[:atanor, :tcp, :disconnect]` carries `reason: {:unavailable, reason}`.
An attach to a channel that cannot reach its owner stays `owner_unreachable`. The two 503s differ: `unavailable` means the call did not run and is
safe to repeat, `unknown_outcome` means it may have run. A write whose batch was sent for
upload when its cell stopped, for any reason (`lease_lost`, `lease_expired`, `fenced`, a drain),
is answered `:outcome_unknown` by Alambique, so `fenced` on a write means it did not run;
a WASM guest sees `:outcome_unknown` as `failed("unknown_outcome: ...")`.
A write whose cell stopped on a failed upload (`{:error, {:sync_failed, reason}}`) may have reached the store, so it is an
`unknown_outcome` too; a WASM guest sees it as `failed("sync_failed: ...")`, and a store
request that failed inside a job's transaction as `failed("store_unavailable: ...")`.

#### Limits

**A request that may have run is not repeated.** Atanor cannot know whether the
effect happened, so a `POST`, a TCP chunk or a WebSocket frame whose callback
started is not repeated (the 503 `unknown_outcome` is described above).
Workaround: give the client a way to ask (an idempotency key stored in the cell,
or a read of the state) before it repeats a write. Evidence:
`test/cluster/routing_test.exs`, "a request that may have run is not run again".

### 8.5 TCP, WebSockets, alarms

* **TCP.** The connection stays on the accepting node, which holds the socket.
  Until it names a cell (§7.3), callbacks run there. Afterwards each
  `handle_tcp/3` runs on the cell's owner, with the worker's state sent there
  and back with every chunk (plain data, so it should stay small).
* **WebSockets.** The same: `ws_init` and `handle_ws/3` run on the owner; the
  env carries the socket pid, and `Env.attach/2` joins the socket in the `:pg`
  scope of its own node (§7.3).
* **Alarms.** The scheduler of the shard's owner finds the entry and claims it;
  the handler runs on the owner of the cell. An alarm call counts as idempotent
  (§8.4), and a failure of any kind is retried by the scheduler's backoff,
  which is the at-least-once contract.
* **Plug workers** have no routing key and run on the ingress node. WASM
  workers serve HTTP without a routing key and run on the ingress node too.

What else runs on the ingress and what reaches the owner is listed in §8.14.

**Guarantee C1.** Every request for a cell is served by its single current
owner, across node failures; Alambique's lease and epoch fencing provide the
single owner. The property in `test/cluster/properties_test.exs` sends
requests through random nodes while it kills and restarts nodes, injects store
faults and partitions the store and the distribution, and then checks that
every acknowledged request ran its handler on the node that committed its
transaction; that acknowledged requests for a cell never overlap in time on
different nodes (the handler reports its start and end by the shared clock);
that batches never overlap in epochs; and that the counter cell has every
acknowledged increment once and none twice. Requests that did not get an answer
may or may not have been applied: they are counted, not asserted. Order is not
asserted; it is Alambique's.

### 8.6 Classifying failures

A node can stop in three ways, and the peers learn of each in a different way.
Only the last one needs a detector.

| Failure | What the peers see | Signal | Measured (§12.7) |
| --- | --- | --- | --- |
| The node stops gracefully (`Supervisor.stop`, a release stop, a deploy) | Alambique hibernates the node's cells and releases their leases. Before that, the node's detector tells its peers that it leaves | the announcement, sent while the connections are up | peers mark it gone in 3 ms; its cells serve again in 11 to 133 ms |
| The process dies on a live host (crash, `kill -KILL`, the OOM killer) | The operating system closes the sockets; Erlang reports `nodedown` with `connection_closed` | immediate | down in 4 to 5 ms; the cells wait for the lease |
| The machine or the network is lost (power, `virsh destroy`, a cable, a firewall that drops) | Nothing: no FIN, no RST. Calls to the node wait. | heartbeats stop (§8.7), or the platform says so (§8.9) | phi decides |

`SIGSTOP` of a node's operating system process stands in for the last row: the
kernel keeps its sockets open and nothing answers. A `nodedown` that the
detector did not cause is not trusted as "dead" on its own, because a cut
cable and a reset by a middlebox produce it too: it makes the peer *suspect*,
and the same probes as for phi decide (§8.8). With a dead process they answer
in milliseconds.

### 8.7 The phi accrual detector

`Atanor.Detector` runs on every node, after Alambique in the supervision tree
so that it stops before Alambique does. It joins a `:pg` group of the prefix,
sends a heartbeat to every peer each `interval_ms`, and keeps for each peer
(`Atanor.Detector.Phi`) the last `window` intervals between its heartbeats. As
in Hayashi et al. (and Akka), the intervals are modelled as a normal
distribution, and phi is `-log10(P(the next heartbeat arrives later than now))`:
about 1 when a heartbeat is a little late, 8 when it is late with probability
1e-8. Decisions:

* **Normal, not exponential.** The exponential model (Cassandra) has one
  parameter, so a link that jitters a lot and one that is regular get the same
  phi for the same silence. The normal distribution has the deviation as well,
  so a jittery link is less suspect for the same delay and a regular one is
  detected sooner. The tail is evaluated with the logistic approximation Akka
  uses; phi is capped at 300.
* **A floor on the deviation (`min_std_ms`).** A regular link would otherwise
  have a deviation near zero, and a delay of a few milliseconds would be
  infinitely improbable.
* **An acceptable pause (`acceptable_pause_ms`)** is added to the mean:
  garbage collections, a busy scheduler and a brief stop are not failures.
* **Seeding.** A peer starts with two intervals around `interval_ms` (`seed_spread` apart), so phi
  is meaningful from its first tick, and the clock of a peer starts when it
  is discovered, so a peer that never sends is suspected too.
* **This node's own stalls.** If the detector itself was not scheduled for
  `stall_intervals` intervals (the VM was paused, the machine suspended), it forgets what
  it measured: queued heartbeats and the time since the last one are not
  intervals of the peers, and without this a node that wakes up would suspect
  everybody. A heartbeat that was waiting still shows that its peer is up, so a peer
  that was suspected or down during the stall is `alive` again.

**Transport: Erlang distribution messages**, sent with `:noconnect` and
`:nosuspend` to the detector process of the peer. The alternative was a
separate UDP socket. Reasons for distribution:

* It is the path that forwarded calls use. A UDP heartbeat can say "alive"
  while the distribution connection is stuck (a full buffer, a blocked
  controller), and then calls wait for a node the detector believes in. A
  heartbeat on the same connection goes silent when calls do.
* Nothing to open or secure: no port, no firewall rule; the cookie
  authenticates.
* `:nosuspend` and `:noconnect` mean the detector never waits: a peer that
  cannot take a message now simply gets no heartbeat, and a peer that is not
  connected is reconnected in the background (one attempt at a time) instead
  of from the detector.

The cost is head-of-line blocking: the connection is one TCP stream, so a large
message (a big response forwarded between nodes) keeps the heartbeats behind it.
The detector therefore also counts the bytes that arrive from an `alive` peer: on
each tick it reads `recv_oct` of the distribution socket of the peer
(`inet:getstat/2` on the port in `erlang:system_info(:dist_ctrl)`), and if it grew
since the last tick the peer was heard, so the silence phi measures starts over.
The intervals between heartbeats are not touched, so the window still describes
heartbeats. A link that is saturated but moving is not suspect, and a link on which
nothing arrives for `acceptable_pause_ms` plus a few deviations (a stuck
controller, a full buffer that does not drain, a stopped peer) still is: the
detector stays on the path the forwarded calls use.
Without this, a large message that took longer than the pause made the peer
suspect, and the probes of §8.8 (witnesses use their own connections) were what
kept the slow link from becoming a dead node. If the counter cannot be read (the
controller of the connection is not a port), only heartbeats count, as before.

Options (`detector:` of `{Atanor, opts}`), all optional:

| Option | Default | Meaning |
| --- | --- | --- |
| `interval_ms` | 1000 | time between heartbeats |
| `phi_threshold` | 8 | phi at which a peer becomes suspect; above 300 never |
| `min_std_ms` | 200 | lower bound of the deviation of the intervals |
| `acceptable_pause_ms` | 2000 | added to the mean interval |
| `window` | 100 | intervals kept per peer |
| `indirect: [k:, timeout_ms:, round_timeout_ms:]` | 3, 1000, 1500 | witnesses asked to probe a suspect peer, how long a ping waits, and when a round gives up (the peer is then down) |
| `reprobe_ms` | 1000 | time between probe rounds for a peer whose link is broken |
| `reconnect_ms` | 1000 | time between connection attempts to a peer that is not connected |
| `stall_intervals` | 3 | a gap this many intervals long between two messages of the detector means this node was stalled (see above) |
| `seed_spread` | 0.25 | how far apart, as a share of `interval_ms`, the two intervals are that seed a new peer's window |
| `forget_after_ms` | 600000 | a `down` peer is forgotten after this long |

**Tuning.** A silent peer is suspect after about `interval_ms +
acceptable_pause_ms + z * max(deviation, min_std_ms)`, where z is the distance
of the threshold in deviations of the normal distribution (z = 3.1 for phi 3,
5.6 for 8, 7.0 for 12), and is down after the probes, which take up to
`indirect.timeout_ms` more when the peer does not answer. The defaults give
4.1 s plus the probe: 4.8 s measured. To detect sooner, lower
`acceptable_pause_ms` first (it is the largest term) and `interval_ms`; to
suffer fewer false alarms, raise `acceptable_pause_ms` or the threshold. A faster
verdict now shortens the time to serve a lost node's cells too, because the
takeover (§8.10) does not wait for the lease; the floor is the false-positive
rate (§12.8), not the lease. Settings are per node; nodes need not agree, but a node with a long pause detects
others later than they detect it.

### 8.8 Indirect probes and states

Each peer is in one of four states, shown by `GET /nodes` and reported by
`[:atanor, :node, ...]` events:

| State | Meaning | Calls to it |
| --- | --- | --- |
| `alive` | heartbeats arrive | forwarded |
| `suspect` | phi reached the threshold, or the connection dropped; a probe round is running | forwarded (it may only be slow; the round is short) |
| `link_broken` | this node cannot reach the peer but another node can | not forwarded: `{:unavailable, ...}` |
| `down` | nobody reached it, or the platform or the node itself said it is gone | not forwarded; disconnected |

A probe round (SWIM style) starts when a peer becomes suspect. This node pings
the detector process of the peer (a `GenServer.call` with `indirect.timeout_ms`)
and, at the same time, asks up to `indirect.k` peers that are alive to ping it
too and report. It decides on the first answer that settles it:

* **This node's own ping is answered**: the heartbeats were late, not lost. The
  peer is alive again and the clock starts afresh.
* **A witness reaches the peer**: the peer is up and the link between the two
  nodes is bad. The state is `link_broken`, `[:atanor, :node, :link_broken]` is
  emitted with the witness in `via`, and the peer stays in Alambique's
  membership (no disconnect). While the heartbeats do not come back, a new
  round runs each `reprobe_ms`, so a peer that then really dies is found.
* **Nobody answers** (all negative, or the round timed out after
  `indirect.round_timeout_ms`): `down`.

**What routing does with a broken link.** It stops forwarding directly and
answers 503 `unavailable` (the call did not run, so it is safe to repeat; a
client that retries through another node reaches the owner, which that node
can still reach). Forwarding through the witness was the alternative: it needs a
relay protocol, a second path whose failures have to be told apart for
`unknown_outcome`, and an extra hop on a link that is already misbehaving.
Rejected for simplicity; Alambique's own routing is unchanged.

**A cluster of two nodes has no witnesses.** The rule is the same with no
answers to wait for: phi crossed and this node's own ping failed, so the peer is
down. The price is that a cut between two nodes makes each declare the other
down. Each keeps serving the cells whose leases it holds; epoch fencing keeps
that safe, but see §8.10: with `takeover.quorum` (the default) neither side
takes the other's cells, because one of two nodes is not a majority, so a
two-node cluster only gets the early takeover with `quorum: false`. The other
rule, never to confirm without a witness, would make a two-node cluster unable to
notice a death at all. `indirect: [k: 0]` makes any cluster behave this way.

A node that was disconnected comes back by itself. Every `reconnect_ms`, each peer that is
not connected gets one connection attempt in the background, and the first
heartbeat from a node that is `suspect`, `link_broken` or `down` makes it
`alive` again (`[:atanor, :node, :alive]`, with `from`). A `down` peer that
stays silent is forgotten after `forget_after_ms`.

**The bound on rejoining.** Two live nodes that each confirmed the other down
(a freeze that ended, a cut that healed) are `alive` at both again within about
`reconnect_ms` plus `interval_ms` and the time to connect, about 1.2 s with the
defaults. `reconnect_ms` is the knob. Each side reconnects by itself, so this
does not depend on traffic.

The bound once did not hold: the time of the last attempt started at 0 and the
monotonic clock is negative, so a peer never reached was never retried. A
thawed node declares its peers down within milliseconds and the pair stayed
down. `test/cluster/detector_freeze_test.exs` ("two live nodes that confirmed
each other down are alive again within a bound") failed in 5 of 5 runs
before the fix, and the frozen-node scenario ended in mutual `down` in 4 of
about 18 runs. The time of the last attempt is now `nil` until the first one.

#### Limits

**With two nodes, the detector cannot tell a cut from a death.** Each side of a
cut declares the other down and goes on serving the cells it holds, safely
because leases are fenced by their epoch; neither takes the other's cells early
(§8.10), so a really dead peer's cells wait for the lease. Workaround: run three
nodes, or set `detector: [indirect: [k: 0]]` and `takeover: [quorum: false]`
knowingly: then each side of a cut takes the other's cells as requests arrive,
and a cell that both sides use changes owner at every request (safe, but slow).

### 8.9 The platform hint

The infrastructure often knows before any detector: `virsh destroy`, an instance
terminated by the cloud, a pod deleted by the orchestrator. It says so with
`POST /nodes/NODE/gone` on the admin API of any node (the admin token is
required, the listener is loopback by default, as for every endpoint of §10.2).
That node confirms `NODE` down at once, without a probe, and tells its alive peers,
which do the same (they do not tell anyone further). The answer is 404 for a
node it does not know. The call is idempotent.

It is the first action of the admin API, which until now only read. The
decision: the hint can only make Atanor stop using a node, never move a cell or
change a deployment, and it is undone by the node's own heartbeats if it was
wrong, so it adds little to the damage a leaked token can do, and it is the only
way to make the verdict as fast as the platform's knowledge. Hinting a live node
is harmless but pointless: it is disconnected, reconnects within `reconnect_ms` and is
`alive` again.

### 8.10 Acting on a confirmed failure

Whoever confirms it (the probes, the node's own announcement that it leaves, the
hint), `Atanor.Detector.confirmed_down/3` is the one place that marks the node:

1. the node is `down` in the table that `Dispatch` reads, with the reason, so no
   call is forwarded to it: the attempt ends as `:lost`, which is retried against
   the owner Alambique names (§8.4). A node that leaves is not disconnected,
   because its cells are still handing off over the connection;
2. the node is disconnected (`:erlang.disconnect_node/1`): calls in flight fail
   with `noconnection` at once instead of waiting for `net_ticktime`, and
   Alambique's membership (the `:pg` groups) drops it;
3. `[:atanor, :node, :down]` is emitted with the reason (`{:phi, value}`,
   `{:nodedown, reason}`, `:left` or `:platform_hint`).

**Takeover, per cell and lazily.** Marking the node does not touch its cells.
Atanor does not list them: a node can hold millions, and most are idle. A cell is
taken the first time something needs it, by `Atanor.Takeover.recover/3`, which
every path that resolves the owner of a cell calls when the lookup answers
`{:unavailable, owner, _}` (the lease names a node that is not a member):

* `Atanor.Dispatch` for HTTP, TCP, WebSocket frames and alarms (§8.1). On
  success it runs the call here, or on the node that won a concurrent takeover;
* `Atanor.Cell`, under the cell calls that workers make through `Atanor.Env`
  (these go through Alambique's router): the call runs again once the cell is here.

The platform hint takes the same path, since it only changes what the detector
says. `recover/3`:

1. asks the detector whether `owner` is *down*. A node that is only `link_broken`
   is alive and reachable by others, and its cells are served by it, so nothing
   is taken (decision below); `suspect` is not a verdict either;
2. checks the quorum (below);
3. reads the lease of the cell for its epoch and, if it still names `owner`, records the lease's
   `expires_at_ms` so that no job or alarm handler starts on the cell before it plus the skew margin
   (§8.13, `routing.fence_defer_after_takeover`), and calls
   `Alambique.take_over(instance, cell, {:atanor_node_down, node, reason},
   epoch: epoch)`. Alambique raises the epoch with a conditional write, wakes the
   cell here and fences the old owner;
4. `{:epoch_changed, _}` or `{:contended, _, _}` mean another node won the race:
   the lease is read again (at most `takeover.attempts` times, default 3) and
   the cell is left to whoever holds it now;
5. emits `[:atanor, :cell, :take_over]` with the node, the reason, the cell, the
   result and the duration (the time of the whole step);
6. when the takeover succeeded, releases the jobs that node had claimed in the
   cell, so they run on the new owner at once (§15.11).

Decisions:

* **Lazy and per cell.** The cost is proportional to the cells that are used.
  A cell nobody asks for stays with the dead lease until someone does, or the
  lease expires and it simply wakes where it is wanted.
* **Epoch guard.** The epoch in the call is the one read just before. Two ingress
  nodes that suspect the same owner both read epoch *e*; the first `take_over`
  makes it *e + 1*, the second gets `epoch_changed`, reads the lease, finds a
  healthy owner and forwards to it. A node cannot take a cell from a healthy new
  owner on an old suspicion (`test/cluster/takeover_test.exs`: 15 cells, 120
  concurrent requests from two nodes, every epoch raised once).
  `Alambique.owner/3` does not return the epoch, so the lease is read with
  `Alambique.lease/3`, without waking the cell.
* **`link_broken`: no takeover.** The peer is alive and reachable by some node;
  taking its cells would fence a healthy owner for a problem that is between two
  nodes. A client that gets 503 `unavailable` through the broken side repeats the
  request through another node, which reaches the owner (§8.8).
* **Quorum (`takeover.quorum`, default on).** A node takes cells over only when it
  and the peers it does not consider lost are a strict majority of the nodes it
  knows. A peer that left, or that the platform says is gone, is known to be
  absent rather than lost and does not count among the nodes it knows. A peer
  counts as heard only while it is `alive` and its phi, taken now, is under the
  threshold. The majority must also have held for `takeover.settle_ms` (2 s): in
  the lab a node that had been cut off took cells of its peers in the moments
  after the heal, when it had heard from one peer and not yet from the other, which
  is a majority of two out of three for a short time (§12.8). Without it, a node cut off from the others would declare every peer down
  and take their cells, while they declare it down and take its cells back: each
  request for a contended cell would raise the epoch again. Fencing keeps that
  safe but not available. The price: a two-node cluster does not take the other's
  cells early after a silent failure (a survivor is one of two; after a graceful
  stop or a platform hint it does), and a perfect split of four nodes takes
  nothing on either side; both fall back to the lease. `quorum: false` turns the
  rule off. The result of a refusal is `:no_quorum` in the event. Refusals come one per request, so the event is
  rate-limited per node (`Atanor.Takeover.Throttle`, one ETS row replaced atomically): the first refusal
  emits, the ones within `no_quorum_event_interval_ms` are counted, and the next event carries the count as
  `suppressed`. The 503 `no_quorum` is unchanged. `test/atanor/takeover_throttle_test.exs` checks that
  events are at most `ceil(span / interval) + 1` and that the counts add up.
* **A slow node is safe.** If the verdict was wrong, the old owner is fenced:
  its next upload collides with the fence of the new epoch and its cell stops
  with `:fenced`. A write it acknowledged before is in the new owner's restore;
  it cannot acknowledge one afterwards. Reads on the old owner can be stale for a
  bounded time (§8.12). `test/cluster/takeover_test.exs` freezes the owner with
  `SIGSTOP`, takes its cell over, thaws it and writes to it: `{:error, :fenced}`,
  no acknowledged write lost or applied twice. The C1 property
  (`test/cluster/properties_test.exs`) has two more steps for this: `lose` freezes
  a node until a survivor confirms it down, serves its cells through the survivors
  and thaws it, and `steal` takes a cell from a healthy owner directly.
* **Off switch.** `takeover: [enabled: false]` leaves the cells to their leases, as
  before.

Options (`takeover:` of `{Atanor, opts}`):

| Option | Default | Meaning |
| --- | --- | --- |
| `enabled` | true | take cells of confirmed-down nodes over |
| `quorum` | true | only with a strict majority of the known nodes |
| `settle_ms` | 2 000 | how long the majority must have held (with `quorum`) |
| `no_quorum_event_interval_ms` | 10 000 | at most one `:no_quorum` takeover event per interval, with the count of refusals left out |
| `attempts` | 3 | reads of the lease when a takeover loses a race |
| `timeout_ms` | `nil` | per `Alambique.take_over/4` call; `nil` is Alambique's `call_timeout_ms` |
| `routing: [attempts:, retry_ms:, remote_timeout_ms:, leave_wait_ms:]` | 3, 50, 60 000, 3 000 | retries of a call whose owner moved or was lost (§8.4), the longest a forwarded call may run, and how long a call waits for a leaving owner to hand off (§8.11) |

**No cycle between live nodes.** A cell changes owner between two live nodes
only while each holds the other `down`, and each takeover needs the other's
verdict, so the cycle lasts as long as the mutual `down` does. That is bounded
by the rejoin bound of §8.8 (`reconnect_ms`). A minimum interval between two
takeovers of the same cell, or a check that the verdict is fresh, was
considered and left out: it would need state per cell, and with the bound
fixed, 10 runs of `test/cluster/detector_freeze_test.exs` (a cell touched on
all three nodes for 10 s after a thaw) saw no takeover between live nodes.
The fence (§8.13) and the release of claims (§15.11) are unchanged.

Because the takeover bumps the epoch, the detector being wrong costs
availability and never correctness. Telemetry for each transition and takeover:
[telemetry.md](telemetry.md).

#### Limits

**A lost owner's cells wait for the detector, and without a majority for the
lease.** When a node is lost, the requests for its cells get 503
`{"error": "unavailable", "reason": "owner_unreachable"}` (or `owner_down` once
the detector confirms it) until the detector confirms it down (about 5 s for a
lost machine with the defaults, milliseconds for a killed process, a graceful
stop or a platform hint). Then the first request for each cell takes it over. The
cell waits for the lease (30 s by default, `lease_ttl_ms`) instead when:

* the failure is not detected (the detector settings are too slack, or the
  failure is a slow node that never goes silent);
* this node and the peers it reaches are not a majority of the nodes it knows
  (`takeover.quorum`, above): a node cut off from the others, any survivor of a
  two-node cluster after a silent failure, and both halves of an even split;
  otherwise set `takeover: [quorum: false]` knowingly;
* the peer is only `link_broken` (above);
* `takeover: [enabled: false]`.

Workaround: give clients a timeout and retries for 503 `unavailable`, which means
the call did not run; run three or more nodes; shorten `lease_ttl_ms` when
quicker takeover without a majority is worth more lease renewals. Evidence:
§12.7, §12.8 and `test/cluster/takeover_test.exs` ("a node cut off from the
others is a minority and takes nothing").

**A partitioned node fails its requests for a few seconds.** When a node is cut
off from its peers but not from the store, it keeps its leases until the peers
declare it down (about 5 s) and take its cells (about 6 s after the cut in the
lab). During that time requests that need the cut wait or fail. The isolated
node declares its peers down, is a minority, and takes nothing: its workers'
cell calls for cells owned elsewhere fail at once with 503 `unavailable`, reason
`no_quorum` (the runtime maps the error even when the worker answers 500).
Workaround: a client timeout, and a load balancer that stops sending to a node
that is not in the majority (`/nodes` shows what it sees). Evidence:
`test/cluster/takeover_test.exs`.

### 8.11 Draining and stopping gracefully

A node hands its cells back in one function, `Atanor.drain/2` (`Atanor.Drain`). Four things run it: the
admin API (`POST /drain`), the command `atanor drain`, SIGTERM and the stop of the instance (the second part of
this section). It is how one node replaces another with no cluster between them: the node that leaves drains,
and the node that comes takes each cell from the store at its next call, with no call between the two.

The sequence of `Atanor.drain/2`:

1. **The node reports `draining`.** The state is `:draining` before anything else, so `/health/ready` and
   `/health/serving` answer 503 `draining` (`/health` stays 200, with `status: "draining"`) and a balancer that
   polls them stops sending requests. The listeners (HTTP, TCP, WebSocket, admin) stay open and keep serving
   the cells the node still holds. The alarm scheduler leaves its `:pg` group at its next tick, so no alarm
   fires here and the other nodes take the shards.
2. **The jobs finish.** The job runner stops claiming and waits up to `stop.jobs_ms` for the running attempts
   (§15.3), so no job runs on a cell that is handed off. Then, while the node still owns its cells, it
   releases the claims of the jobs that did not finish, so the node that takes a cell runs them at once
   (§15.12).
3. **`Alambique.drain/2`**: the node leaves the membership, refuses to wake cells (`{:error, :draining}`, a
   503 `draining` to the client, §8.4) and hibernates every awake cell: it uploads what is pending, publishes
   the feed and releases the lease (`released: true`), so another node takes the cell at once, without
   waiting for the lease to expire. One cell is bounded by `stop.drain_timeout_ms` (default 15 000), up to
   `stop.drain_concurrency` (default 64) at a time; the whole drain by `stop.shutdown_ms` (default 75 000,
   at least the first). Past it the drain gives up and reports `{:drain, :deadline}`.
4. **The node stops** (`stop.exit`, default `true`): `System.stop/1` with status 0, or 1 when a cell stayed
   with its lease. The drain started by the API or the command answers before that, with
   `%{state, hibernated, errors, duration_ms}`; `exit: false` or a function (`Atanor.drain(name, exit: fun)`)
   replaces it, which is how the tests and a drain that must not end the VM use it.

A cell that the drain did not hibernate (`errors`) is still awake on the node when the drain ends. If the node
then stops (SIGTERM, or `stop.exit`), the stop hands it back: the supervisor of Alambique stops
`Alambique.Drain`, which runs a second drain with Alambique's own limits (60 s for the drain, 15 s per cell),
then ends each cell still awake with `:shutdown` (at most 30 s each, in parallel), and the termination of a cell
hibernates it like the drain does: it uploads what is pending, publishes the feed, checkpoints, and only then
releases the lease (Alambique `Cell.hibernate/2` and `terminate/2`). Every write that was acknowledged is in the
store before the lease is released, and a cell that cannot finish that (an upload that fails, or the 30 s end)
keeps its lease, which expires as after a crash (30 s plus the 2 s skew margin by default); a client of the node
that takes over gets 503 `held_elsewhere` until then (§8.4). So `errors` after the deadline does not mean the
leases wait for their expiry: with a node that exits normally they were released by the stop, a few seconds
later (1,300 cells were served by the other node 2.3 to 3.3 s after a drain that ended at its deadline). Only
SIGKILL, or a stop that outlives the grace period, leaves them to expire. The exit status 1 still says that the
drain itself did not finish.
The drain is one way: the node does not take cells again until it restarts. A second call joins a drain that
is running, or returns what the finished one did (`GET /drain`, `Atanor.drain_status/1`).
While it runs the status adds the progress that `Alambique.drain_status/1` reports (`cells_at_start`, `done`,
`left` and the `errors` so far); they are absent until the jobs have finished and Alambique begins, so a status with only `state` means the node still waits for its jobs.

**SIGTERM** (what `docker stop`, systemd and Kubernetes send) runs the same drain with the listeners still
serving, then stops the VM. The application swaps `Atanor.Signal` in for OTP's `erl_signal_handler` on
`:erl_signal_server`, once per VM, and swaps it back when the application stops; the other signals keep OTP's
behavior. On SIGTERM it drains every running instance whose `stop.sigterm` is `:drain` (the default), in
parallel, then calls `System.stop/1` with status 1 if any drain left a cell or failed, else 0. With no
instance, or with `stop: [sigterm: :stop]`, the VM stops at once as OTP does, and the stop runs the drain
after the listeners close (the order below). The stop that follows finds the drain done and does not repeat
it. A second SIGTERM during the drain joins it and forces nothing: the grace period of the container or the
unit (`docker stop --time`, `TimeoutStopSec`, `terminationGracePeriodSeconds`) must exceed
`stop.shutdown_ms` (75 s by default), and SIGKILL is the way to force a stop; the leases then expire as
after a crash.

The VM stops as soon as the drain ends, and the listeners, the admin API among them, close with it, so a poll of
`GET /drain` never reads the final `drained` of a SIGTERM; the last answer is a `draining` with the progress at
that poll, then the connection is refused. The result is the exit status (1 when `errors` is not empty), the log
line `atanor: drain left ... cells to their leases` and the telemetry event `[:atanor, :node, :drain]`. A drain
asked for with `POST /drain` answers with the final status before the node stops.

A cell that has to be handed back is still safe if the node dies half way: leases not released expire, and
Alambique's fencing (§8.10) stops the old owner's writes after another node took over.

Telemetry: `[:atanor, :node, :drain, :start]` and `[:atanor, :node, :drain]` ([telemetry.md](telemetry.md)).

The walk-through of a swap, with the container grace period, the peers and the `node_id` it needs, and its measurements under
load, is [how-to-replace-a-node.md](how-to-replace-a-node.md).

#### The order of a stop

The supervision tree of an instance stops its children in reverse order, and
the order is the contract (`Atanor.Supervisor`):

1. **The listeners close.** The HTTP ingress, the TCP listeners (ThousandIsland
   or Ranch) and the admin and dashboard listeners stop accepting connections;
   the connections already served get `stop.connections_ms` (default 15 000,
   passed to ThousandIsland as `shutdown_timeout`) to finish. Ranch's
   `stop_listener/1` closes its connections at the same point.
2. **The detector announces `leaving`** to its peers, which mark the node down
   with reason `:left` at once. It is not disconnected: its cells are still
   handing off over the connection, so a peer keeps forwarding idempotent calls
   (reads, alarms) to it until Alambique names another owner; the node answers
   `{:moved, _}` for a cell it has already handed off, and the call is routed
   again. A call that a repeat could hurt (a `POST`) is not sent to it, since
   the node may stop while the call runs: it waits for the handoff, in tries of
   `routing.retry_ms`, for at most `routing.leave_wait_ms` (3 000), then answers
   503 `unavailable`. The node sets its state to `:stopping` when step 3 starts;
   an idempotent call that fails on it from then on, because the drain hibernated
   the cell under the handler or Alambique is shutting down, is answered
   `{:moved, nil}`, and a call refused with `owner_down` (a draining node does
   not wake cells) is repeated the same way while any peer is leaving. So is a call for a cell that no node holds, when the node
   chosen to wake it has left the members while the caller's view still lists it (Alambique answers `draining` after its own retries,
   which are immediate): it waits for the view, whatever the detector has said. Before this, both got 503 `owner_unreachable` after
   `routing.attempts` tries (150 ms) when the handoff of a loaded node took longer.
   A call that reaches the node after Alambique stopped (step 4, while the VM is
   still up) did not run, whatever it is: `Dispatch.remote/9` answers `{:moved,
   nil}`, and a cell call of a handler whose cell is owned by such a node is
   `{:unavailable, :owner_down}`, the refusal of a draining owner (`Atanor.Cell`).
   The shapes (`Cell.refusal/1`, each matched narrowly) are Alambique's router raising
   `no Alambique instance named ...`, at the owner or at the caller before it sent the
   call, and `badarg` from `ets:lookup` of the stopping instance's admission table
   (`{:failed, cell}`, the first step of a wake), all wrapped in `{:forward_failed, ...}`.
   Before, the first was an unknown outcome and the others reached the worker as a 500.
   **A cell call from inside a handler waits for the handoff like a routed call.** A
   WASM worker, or a native one without a routing key, runs on the ingress node and
   reaches the owner through Alambique's router, so `Dispatch` cannot wait for it. When
   such a call is refused with `draining`, or with a stopped-instance shape while a peer
   has announced that it leaves, `Atanor.Cell` repeats it every `routing.retry_ms` until
   `routing.leave_wait_ms` after the first refusal (`Dispatch.wait/5`, the same wait) or
   until the handler's time is up (the guest's remaining wall-clock limit for WASM),
   then answers as before. Before, a rolling restart of 3 nodes under 60 requests per
   second refused 42 and 51 of about 4,700 scoreboard POSTs with 503 `owner_down` in
   2 to 3 ms, and none after ([the container cluster how-to](how-to-run-a-cluster-in-containers.md)).
   A handler that Dispatch routes to the owner can wait twice (in the cell call and
   again in Dispatch), each bounded by the setting.
3. **The drain** (`Atanor.Drain`, the sequence above, jobs already stopped): the node leaves the
   membership, refuses new wakes and hibernates every cell it holds, so the leases are released, with
   `stop.drain_timeout_ms`, `stop.drain_concurrency` and `stop.shutdown_ms` (the whole step). A drain asked
   for earlier is not repeated.
4. Alambique stops (its own drain finds nothing left).

The jobs sit above the detector in that order. The job runner stops claiming and
waits up to `stop.jobs_ms` for the running attempts (§15.3). The instance's task
supervisor (`Atanor.Tasks`) stops after them and before the detector: it
cancels what still runs (job attempts, alarm handlers, lease reads, moves,
migrations), allowing `stop.tasks_ms` (default 5 000) for each to exit. So no task
outlives the tables it reads (the detector's and Alambique's). A cancelled job
attempt keeps its claim and runs again when the lease ends, as after a crash.
Before, these tasks ran under one supervisor of the VM that no instance stopped, and an
attempt that outlived `stop.jobs_ms` crashed with `ArgumentError` on the
detector's table.

Cells that the drain could not hibernate are logged as a warning and counted in
`[:atanor, :node, :drain]` (`errors`, with the list in `error_list`); their leases
expire as after a crash, and the takeover (§8.10) is the next peer's way in.

Measured (§12.7, §12.8): the drain of 16 to 22 cells took 3 ms, the whole stop
8 to 11 ms, and 800 GET and 800 POST requests through the other two nodes had
no errors in three runs of the bench (a loaded machine gave 2 POST 503 once; the
test requires none for GET). Phase 1 had the same order without the explicit
drain step and measured 132 ms to serve a cell again; the bench now reports the
errors too.

### 8.12 Reads that must not be stale

After a takeover, and in a partition, the old owner can answer a plain read from
its own copy until it learns of the new epoch (Alambique design §5, "Stale
reads"): `test/cluster/takeover_test.exs` shows a resumed old owner answering
`[0, 1]` for a cell whose new owner had acknowledged `2` and `3`. Native workers
choose per read:

* `Atanor.Env.query(env, cell, sql, params, verify_lease: true)` (also
  `Atanor.Cell.query/5`): the cell reads its lease object from the store after
  running the statement (one `GET` per read, or per batch of reads waiting behind
  a write) and answers only if the lease is still its own; otherwise the router
  sends the read to the new owner. Default off: a read costs no store request.
* **The WASM `sql` import has no lease flag.** Adding one means a new version of the
  WIT interface and rebuilding every guest, for a stale window that is bounded
  and short. Decision recorded here; revisit when a guest needs it. (A bound on
  the other side is the function `query-bounded` of `sql`, §19.2.)
* **A read that accepts staleness** says so with `consistency: {:bounded, ms}`
  and may be answered by a replica on another node (§19).

### 8.13 A handler that outlives its cell

Fencing protects the cell, not what a handler does outside it. After a takeover
that was a false positive (or a plain `Alambique.take_over/4`), the old owner may
still be running handlers for the cell, and the new owner starts others: for a
moment **a handler can run on two nodes at once**. Their cell writes are safe:
the old one's are refused by the fence (`:fenced`) or sent through the router to
the new owner, and no acknowledged write is lost or applied twice. Their other
effects are not protected: outbound HTTP (`Env.fetch`), e-mail, a message to a
socket. Such an effect has to carry an idempotency key that the receiver checks,
or go through the cell's jobs (§15): a job is written in the cell's transaction
and runs on the current owner, so it inherits the fence. Its id is stable
across retries and takeovers and is the default idempotency key. Until the
receiver checks that key the effect is at least once for the work of a handler
that spans a takeover.

Atanor bounds the window in four ways.

* **No new handler on a cell this node lost.** Before a handler starts for a
  cell this node owns (`Atanor.Dispatch`, for forwarded calls and for work that
  arrives here), the node reads the cell's lease from the store, with
  `Alambique.query/5` and `verify_lease: true`, unless it did within
  `routing.owner_check_ms`. A node that was told it lost the cell (Alambique
  notifies the old owner at once when it is reachable) has no cell process
  anymore. One that was not told (cut off from its peers, frozen and thawed) finds
  out at the next check, so it starts no handler for the cell later than
  `owner_check_ms` plus one lease read after the takeover. The cost is one store
  `GET` per owned cell per `owner_check_ms` while the cell is in use. The check
  that finds the last read older than `owner_check_ms` is the one the cell
  process serves, and it stalls the cell for the read: a busy cell therefore has
  its lease read ahead of time, outside the cell, by `Fence.refresh_ahead/3`
  once the last read is three quarters of `owner_check_ms` old (one reader per
  cell, `Registry.claim_refresh/4`). The bound is the same, since a handler
  still starts only on a read younger than `owner_check_ms`, and the cost for a
  cell in use is at most one `GET` per 750 ms instead of per 1000 ms (§12.14). A lease
  read by the fence (below) that shows this node as the owner at the epoch the
  fence remembers counts as this read (`Fence.record/4` marks the cell verified):
  it is the same read, made for another purpose, so a cell with a running
  handler pays one lease read per interval and not two.
* **A job or alarm handler is killed when the node's lease on the cell ends.**
  The fence (`Atanor.Fence`, below) stops the handler on a definite answer
  that the cell is lost, and at the end of the node's own lease when it can
  neither renew nor read it.
* **A cell taken over early starts no job or alarm handler until the old lease
  has ended.** The deferral is the new owner's half of the fence. When
  `Atanor.Takeover` takes a cell over from a node confirmed down (§8.10), it
  has read the previous lease for its epoch; it records that lease's
  `expires_at_ms + skew_margin_ms` in a table of holds, and from the takeover
  until that instant on its own clock neither a job claim nor an alarm claim
  succeeds for the cell (the claim transaction runs on the owner and checks
  the table). The cell is served at once for reads, writes and requests; the
  job or alarm is not lost, it is claimed by the first scan after the instant
  (`jobs.wait_ms` for jobs, `alarms.tick_ms` for alarms). Together with the
  old owner's kill at `expires_at_ms - skew_margin_ms`, the handlers of the
  two nodes do not overlap whether the new owner got the cell by lease expiry
  or by early takeover.
* **Other handlers** (requests, WebSocket and TCP callbacks) run to the end;
  Atanor does not interrupt a native handler. Their length is the worker's, a
  forwarded call is cut at `routing.remote_timeout_ms` by the caller and a WASM
  call has its own wall-clock limit (§9).

**The fence.** A job or alarm handler runs in a task that the fence watches.
The node keeps, per cell, the epoch and expiry of its own lease from the last
successful `Alambique.lease/3` read in which it is the owner. That expiry is a
lower bound: a renewal only extends it, and a takeover changes the owner or the
epoch, which the next read shows as a definite loss. The fence acts in two
cases.

1. *The lease ends.* The deadline is `expires_at_ms - skew_margin_ms` on the
   clock the cells use (the instance's `clock`, or the system's). The fence
   waits for the handler in a `receive ... after` set to that deadline, not to
   the read interval, so the bound does not depend on `fence_check_ms`. At the
   deadline the task is killed with `:brutal_kill`, without the handler's
   cooperation. A read that extends the expiry moves the deadline.
2. *The lease names another owner or epoch.* The read shows it, and the task is
   killed at once.

Every `routing.fence_check_ms` one watcher per cell reads the lease in a
separate process (the read has the same timeout, so a store that hangs cannot
delay the kill). The read is shared: the remembered lease is a per-cell table,
so handlers of one cell, jobs and alarms alike, cost one `GET` per interval, and a
handler that starts while the remembered expiry is still ahead reads nothing.
A handler that cannot start because the lease cannot be read, or is not this
node's, does not run (`{:error, :handler_fenced}`). A killed handler returns
`{:error, :handler_fenced}`: a job writes nothing (the new owner decides), an
alarm stays claimed and fires again, as for any failed alarm. Each kill emits
`[:atanor, :handler, :fenced]` with `reason` `:local_deadline` (the lease ended),
`:lost` (a read showed another owner or epoch), `:unreadable` (the handler did
not start) or `:stopped` (the instance is stopping).

A `verify_lease` query does not move the deadline: it proves that the lease was
valid when it ran, not until when.

**What it guarantees.** Alambique lets another node acquire the cell only
after `expires_at_ms + skew_margin_ms` on that node's clock
(`Alambique.Lease`). The old owner's handlers are dead at
`expires_at_ms - skew_margin_ms` on its own clock plus the timer's precision.
An early takeover does not change that, because the new owner waits for the same
instant before it starts a job or alarm handler (above). With clock skew between
the two nodes below `skew_margin_ms`, a handler of the old owner has ended before
the new owner starts one, so the two do not overlap.
The assumptions are those two: skew below the margin, and a kill that is late
by the scheduler only. The kill was never later than the deadline in the
runs of `test/atanor/fence_test.exs`: in 12 runs the last effect of the handler
was 1 ms before it at the closest; the tests allow 60 ms, and the cluster test
100 ms for its 100 ms heartbeat. The margin is Alambique's `skew_margin_ms`
(default 2 000), which Atanor passes through in `alambique:`; there is no
separate option.

**What it does not guarantee.**

* *The deferral off or lost.* With `routing.fence_defer_after_takeover: false`
  the new owner of an early takeover starts at once, and the overlap is
  bounded by the old owner's remaining lease (up to `lease_ttl_ms -
  skew_margin_ms`). The deferral is kept in memory, in a table of its own that the
  `owner_check_cells` bound never empties (an expired hold is deleted when it is
  read or when the next one is recorded): a new owner that restarts in that
  window forgets it.
* *Processes a handler spawned and did not link* are not killed with it, and
  neither is what it already sent: effects outside the cell stay at least once.
* *Skew above the margin* breaks the guarantee, as it does Alambique's.
* The fence ends a handler at the end of the lease, also on a node that is
  healthy but could not renew in time. That is when the cell stops accepting
  its writes as well.

Tests of the fence: `test/atanor/fence_test.exs` (a property over the lease timings, the
check interval and the moment of the cut: no handler runs after `expires_at - skew_margin` plus
60 ms) and the cluster test in `test/cluster/jobs_release_test.exs` (a long job, the node cut off from
the store and its peers, with the default early takeover: the handler stops by its deadline, the
new owner's first beat comes after the old lease ended, the job ends on the new owner). The property
in the same file checks the deferral for a job and an alarm. All fail with `ATANOR_TEST_FENCE=off`,
and the deferral tests fail with `ATANOR_TEST_FENCE=no_defer`.

Tests: `test/cluster/takeover_test.exs` cuts the old owner off, takes its cell
from another node and sends it a request after the lease it last read is older
than `owner_check_ms`: no handler starts; with `owner_check: false` one does (and
the write is refused). The C1 property (§8.5) takes cells with `lose` and `steal`
and checks, for **every** cell and with no relaxation of the data checks (no
acknowledged increment lost, none twice, epochs never overlap), that a handler
which ran on another node than the one that committed its batch is explained by a
takeover: it started before the takeover finished, or on the old owner at most
`owner_check_ms` + 1 s after it. For those requests (and only for them) the
rule "the handler ran where the batch committed" and the no-overlap rule do not
apply; they apply to every other acknowledged request. In the runs recorded here
the latest start on an old owner was 3 ms after the takeover.

#### Limits

**A handler can run on two nodes at once around a takeover.** The cell writes
are safe, but effects outside the cell, such as outbound HTTP, e-mail or a
message to a socket, can happen twice; the sections above bound the window.
Workaround: make effects outside the cell idempotent (an idempotency key the
receiver checks), or do them from a cell job (§15), which runs on the current
owner and carries a stable job id. Evidence: the C1 property and
`test/cluster/takeover_test.exs`.

### 8.14 Ingress and owner: what runs where

HTTP, WebSocket and TCP connections end on whichever node the client reaches;
only the worker's callback for a cell goes to the cell's owner (§8.2). So a
cell with many connections costs its owner the callbacks and the cell, not the
connections. Audit of the code (no change was needed):

| Work | Runs on | Where in the code |
| --- | --- | --- |
| Accepting the connection, TLS, HTTP parsing, keep-alive and idle timers | ingress | Bandit, ThousandIsland and Ranch listeners; the WebSocket `idle_timeout_ms` is the timeout `Atanor.HTTP.serve_socket/3` gives `WebSockAdapter.upgrade/4` |
| Route match, deployment pin (D1) | ingress | `Atanor.HTTP.call/2`, `Registry.match/3` |
| Bearer token check (OIDC, §7.5) and the `x-atanor-claims` header | ingress; the owner receives the verified claims in the request headers | `Atanor.HTTP.authorize/4` calls `Auth.check/6` before `Dispatch`; a rejected request never reaches `Dispatch` |
| Reading the body, the 413 limit | ingress; the body is sent to the owner once, inside the `Request` | `Atanor.HTTP.serve_request/3`, `Dispatch.forward/7` |
| `route_key/2` | ingress (a pure function of the request) | `Dispatch.route/2` |
| Owner lookup | ingress, from Alambique's hint cache, no store request | `Dispatch.owner/4` |
| The worker's `handle_request/2` | owner; the ingress node itself for a request whose `route_key/2` declared a bounded read (§19.3) | `Dispatch.remote/9`; `Dispatch.execute/3` |
| Writing the response (headers, `send_resp`) | ingress; the owner returns the `Response` once | `Atanor.HTTP.write/2` |
| WebSocket process, frame decoding and encoding, ping/pong, close | ingress: one process per socket, holding the connection | `Atanor.HTTP.Socket` (`WebSock` callbacks) |
| `ws_init/2`, each `handle_ws/3`, `ws_close` | owner, one call per frame | `Socket.deliver/2` through `Dispatch.execute/3` |
| `handle_ws_local/3` (optional) | the socket's node, in the socket process, no cell access (§7.6) | `Socket.frame/2` through `Dispatch.execute_local/3` |
| Fan-out of a channel message or a cell message | the publisher sends the frame to its local members and one message to each other node; that node's `Atanor.Channels` sends to its sockets (§7.6) | `Channels.broadcast/2` |
| Membership of a socket in a cell's `:pg` group | the socket's own node (`:pg` joins local processes only); the owner asks it with one `:erpc` | `Sockets.attach/3` |
| TCP connection, TLS, STARTTLS, bytes in and out | ingress: the `ThousandIsland.Handler` process | `Atanor.TCP.Connection` |
| `handle_tcp/3` after the connection names a cell | owner, one call per chunk, with the worker's state sent there and back | `Connection.handle_data/3` |
| Plug and WASM workers | ingress (no routing key) | `Atanor.HTTP.serve_plug/2`, `Workers.invoke/2` |

Two costs stay with the owner on purpose, and they are the ones to look at for a
cell with many sockets:

- **One callback per frame.** (With `handle_ws_local/3` a frame the worker
  drops there is not a callback on the owner, §7.6.) An idle socket costs the owner nothing (no timer
  or heartbeat runs there), but every frame a socket sends is a callback, and
  so is every message to the cell: `Env.send_to_cell/3` reaches each attached
  socket on its own node, and each of them then runs `handle_ws/3` with
  `{:cell_message, message}` on the owner. A message to 300 sockets is 300
  callbacks there, and the process that calls `send_to_cell/3` sends 300
  messages itself, one per socket, to the remote ones across the distribution.
  `test/cluster/ingress_test.exs` shows the count (one `say` and three cell
  messages for three sockets). The sender now sends one message per remote node
  (`Atanor.Channels.broadcast/2`, §7.6), and the callback per socket stays: it is
  what a cell message means. Messages that need no worker code (presence, signals,
  cursors) use the ephemeral channel of §7.6, and a client's frame can reach it
  from the socket's own node with `handle_ws_local/3`, so neither the callback
  nor the frame reaches the owner.
- **Worker state in TCP.** It travels with every chunk (§8.5); keep it small.

`test/cluster/ingress_test.exs` checks, on three peers, that a request with a bad
token or audience is answered 401 by the ingress node without a forward or a call
on the owner, that a valid one runs once on the owner and sees the claims, and
that the process of a WebSocket opened on a node other than the owner's is on
that node while `ws_init/2` and every frame run on the owner. The owner's CPU
with many connections on one cell is measured in the cluster lab
([how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md)).

The ceiling stays: one cell has one writer, on one node. Everything above
moves the connections away from it, and a bounded read (§19) moves the reads of
a request to the nodes that receive them; it does not make the cell's writer
faster.
What can change is which node that is: §8.15 moves a hot cell to a less loaded
or a dedicated node, so the writer has a core of its own, and the ceiling
stays one writer.

#### Limits

**Plug and WASM workers do not run on the owner of the cell.** They have no
routing key, so they run on the node that received the request. Their cell calls
are still routed to the owner by Alambique, so they are correct, but they pay
one network hop per call instead of one per request. Workaround: use `handle_request/2` in a native
worker for latency-sensitive paths. Evidence: §8.5.

### 8.15 Placement of hot cells

`Atanor.HotCells` watches the cells a node serves and moves a hot one to
another node with `Alambique.move/4`: the owner hibernates the cell and the
target wakes it. It helps in two cases: the owner is busy with other work as
well (the hot cell's neighbours get their CPU back, and the hot cell gets a
node that is less loaded), and the operator owns a node for hot cells. It
does not make one cell faster than one writer. The loop is off by default:
`hot_cells: [enabled: true]`. A move is not free (§ "What a move costs"), the
thresholds depend on the hardware, and an operator should choose to accept both.

**The owner decides.** Each node samples only the cells it serves and decides
only for them, so one cell has one decider and two nodes never decide for the
same cell. The other nodes' load comes from a message each node sends its peers
every `interval_ms` (CPU, number of hot cells, tags), over the `:pg` group of
the instance's prefix. Considered and left out: a central placer (another
process to elect and to lose) and deciding at the target (it has no metrics of
the cell). A decision on a view that is `stale_ms` old costs at worst a move that
was not needed.

**Metrics**, every `interval_ms` (1 s):

| Metric | Source |
| --- | --- |
| Reads and writes per second of a cell | counters in `Atanor.Cell`, one `update_counter` per call, for the calls this node makes. Handlers run on the owner (§8.2), and so do jobs and alarms of its cells, so this is the load of the cells it serves. A handler that calls a cell owned elsewhere is counted on its own node, not on that cell's owner |
| Reads of the cell on other nodes (with `replicas: true`) | the reads each node counts for cells it does not serve, sent to its peers in the load message (§19.4) |
| Calls waiting on a cell | `pending` of `Alambique.load/2`: the messages in the cell's mailbox plus the callers it accepted and has not answered, so writes waiting in the commit pipeline count. It is exact while the cell is quiet and may exceed the callers by a handful under load. `:none` (no process on this node) leaves the cell out of the sample. The `queue_enter` and `queue_exit` defaults did not change: they count callers as before, and a few more now while a commit is in flight, which a saturated cell exceeds by far (not re-measured) |
| CPU of the node | the larger of two views. The VM's schedulers: busy time of the normal and dirty CPU schedulers between two samples (`:erlang.statistics(:scheduler_wall_time_all)`) as a share of the normal schedulers; dirty IO schedulers are left out; starting the loop turns on `scheduler_wall_time` for the VM. The machine, on Linux: the busy share of all its CPUs from `/proc/stat`, steal included (`os_cpu`, true). The second was added after the lab: with two busy loops taking the cores of the owner's VM, its schedulers read 37 to 45% as before while the cell's writes fell by half and its queue grew to 250, and the machine read 100% |

A cell is *hot* when a signal reaches its enter threshold (`write_enter`,
`read_enter`, `queue_enter`) and stays hot until all three are under their exit
thresholds. A node is *pressured* from `cpu_enter` to `cpu_exit`. Only the
`max_tracked` hottest cells are kept.

**The decision** (`Atanor.HotCells.Policy`, pure functions), for a cell that has
been hot for `sustain_ms`, hottest first, at most one move started per sample:

1. a cell that moved less than `residence_ms` ago stays;
2. with `max_moves` moves in progress in the cluster, it stays;
3. a node that took part in a move less than `node_cooldown_ms` ago does not
   give one away, and does not receive one;
4. **affinity**: if `affinity: [{namespace, tag}]` names the cell's namespace, the cell goes
   to the least loaded node that has the `tag` among its `tags:`, whatever the
   load, and stays if this node has it. With no such node the load rule decides;
5. **load**: only a pressured node gives a cell away, to the least loaded node
   (CPU, then fewer hot cells, then name) whose CPU is at least `margin` points
   under this node's. A node whose tag some rule names is reserved for those rules
   and is not offered other cells.

A target must have been heard from within `stale_ms`, and be neither down, leaving
nor cut off in the failure detector (§8.8); it announces itself only once it is
ready, so it is a member of the instance (§2.1).

**Hysteresis**, in one place: enter and exit thresholds for the cell and for the
CPU; the sustained window; the margin between source and target; the residence
time of a cell; the cooldown of both nodes of a move; the cap on moves in
progress. The nodes keep the last three in step by telling each other when a
move starts and ends (`{:moving, ...}` and `{:moved, ...}`), so a node that did
not decide knows the move. A node that restarted during a move learns it from
the next load message of the node that runs it, which lists its moves in progress.
The cap is exact except for two nodes that decide within the delay of that message
(milliseconds on a LAN); a node that dies during a move leaves its entry for the
others for `move_timeout_ms + stale_ms`.

**Safety does not depend on any of this.** The loop can be wrong, late or
duplicated; `Alambique.move/4` is hibernate then wake, and Alambique's lease and
epoch fencing allow one writer per cell: the target takes the lease only after the
owner released it, with a higher epoch, and a former owner that still writes is
fenced. The loop adds no way to hold a cell on two nodes. What a bad decision
costs is a move that was not worth its price.

**What a move costs, and what calls see.** The cell is unavailable between the
hibernate (pending writes uploaded, lease released) and the wake on the target. A
call that arrives meanwhile is routed by Alambique: a handler already running keeps
its cell calls, which are forwarded to the new owner (the call ends on a node other
than the one that started it, the case of §8.13), and `Atanor.Cell` repeats a call that
meets `epoch_changed` or `contended`. A callback forwarded to the old owner finds
`{:moved, node}` (§8.2) and is routed again. The duration of each move is in
`[:atanor, :hot_cell, :move]`; the lab measured it (0.4 to 0.9 s with 348 connections writing and reading the cell).

**What is attached to the cell.** WebSockets and channel members belong to the
`:pg` group of the socket's own node (§8.14), not of the owner's, so a move does not
change them: the next frame is a callback on the new owner, and a cell or channel
message reaches the same sockets (`test/cluster/hot_cells_test.exs`). Alarms and
jobs are rows in the cell (§7.4, §15): the new owner serves them, and the claims of
a job that was running on the old owner end by the old owner's fenced write and a
retry (§15.3). Pinned deployments (§8.3) are per request and unaffected.

**Takeover and drain.** A move starts only on a node that is `:ready` and
has the cell, and goes only to a node the detector holds alive, so it cannot race the
takeover of a node confirmed down (§8.10): that needs the owner down, and a
move needs it alive. If the owner is wrongly held down, the takeover and the move
both go through Alambique's epoch, and one of them loses with `epoch_changed`
or `contended`. A node that stops (§8.11) stops the loop before it announces
that it leaves, and its peers stop sending it cells. A move of a cell in
the middle of a drain fails with an Alambique error and is recorded as a failed
move. During a rolling restart a restarted node is empty and so the least
loaded: it receives cells only if some node is pressured and hot cells are
eligible; to avoid moves meanwhile, set `enabled: false` or raise `cpu_enter`.

**Rendezvous hashing.** Alambique wakes a sleeping cell on its preferred node. A
cell that was moved and later hibernates (idle, a restart of its node) wakes
on the preferred node again, not where it was moved. The loop does not fight
that: the cell is either idle (no load) or hot again, and then moves again after
the residence time. Affinity is the way to make a cell prefer a node: a hot cell
of a ruled namespace is moved to a tagged node every time it is hot there.

**Telemetry.** `[:atanor, :hot_cell, :sample]` (per interval: CPU, reads and writes
per second, hot cells), `[:atanor, :hot_cell, :replicas]` (§19.4), `[:atanor, :hot_cell, :decision]` (a hot cell and what was
decided, once per change of reason) and `[:atanor, :hot_cell, :move]` (result, from,
to, duration). [telemetry.md](telemetry.md) has the fields. `GET /hot-cells` on the
admin API shows what one node knows. The how-to is
[how-to-place-hot-cells.md](how-to-place-hot-cells.md).

Options (`hot_cells:` of `{Atanor, opts}`; CPU and `margin` in percent, rates per
second, `queue` in calls):

| Option | Default | Meaning |
| --- | --- | --- |
| `enabled` | false | run the loop |
| `interval_ms` | 1 000 | sampling period and period of the load message |
| `sustain_ms` | 10 000 | a cell must stay hot this long before it moves |
| `write_enter` / `write_exit` | 500 / 250 | writes per second that make a cell hot / stop it |
| `read_enter` / `read_exit` | 2 000 / 1 000 | reads per second |
| `queue_enter` / `queue_exit` | 50 / 10 | calls waiting on the cell (`pending`, above) |
| `cpu_enter` / `cpu_exit` | 70 / 50 | CPU of the node that makes it give cells away / stop |
| `os_cpu` | true | also use the machine's CPU from `/proc/stat` (Linux). Off, only the schedulers count: needed when several nodes share one machine, as in the cluster tests |
| `margin` | 20 | the target's CPU must be at least this far under the source's |
| `residence_ms` | 300 000 | a cell that moved is not moved again for this long |
| `node_cooldown_ms` | 30 000 | after a move, source and target take part in none |
| `max_moves` | 1 | moves in progress in the cluster |
| `move_timeout_ms` | 15 000 | per `Alambique.move/4` |
| `stale_ms` | 5 000 | a node not heard from this long is not a target |
| `max_tracked` | 100 | hot cells kept per node, and cells whose remote reads a node reports |
| `move` | true | false: the loop moves no cell (it can still switch replicas) |
| `replicas` | false | turn the Alambique read replicas on for a cell read at `replica_enter` and off under `replica_exit` (§19.4); needs `alambique: [replicas: ...]` |
| `replica_enter` / `replica_exit` | 1 000 / 500 | reads per second of a cell in the cluster that turn its replicas on / allow them off |
| `replica_hold_ms` | 60 000 | replicas stay on this long after the rate was last at `replica_exit` |
| `tags` | `[]` | labels of this node |
| `affinity` | `[]` | `[{namespace, tag}]`: hot cells of the namespace go to a node with the tag |

The defaults are a starting point, not a measurement: the rates are those at which one
cell on the lab's 2 vCPU nodes is clearly busy (one hot cell there takes about 1,000 writes and 1,400 reads per second, §12.6), and `cpu_enter` 70 leaves a node
room before it saturates. The off default is on purpose: a move interrupts the cell
briefly and moves its cache, an operator should switch it on knowing that, and with
thresholds checked against the hardware.

`test/atanor/hot_cells_policy_test.exs` checks the decision as properties (never a
source or cooling node as target, never inside the residence time or over the cap,
the margin and the least loaded target, affinity). `test/cluster/hot_cells_property_test.exs`
(H1) loads random cells through random nodes while the loop moves them, with
manual moves, loads and node restarts, and checks that every acknowledged write is
in its cell exactly once, that no two nodes acknowledged one epoch, that requests
of a cell did not overlap in time except across a move or a takeover, and that the
loop kept to residence time and cap. Every run waits for at least one move by the loop.

### 8.16 Discovery through the store

Nodes find each other through Alambique's node registry, not through a list of peers. An instance with
`alambique: [registry: [advertise:, ttl_ms:, renew_ms:, meta:]]` writes `<prefix>/nodes/<node_id>`, renews
it and deletes it when it drains or stops. `Alambique.peers/1` lists the other live nodes, and
`[:alambique, :registry, :peers_changed]` says who joined and who left. Alambique never connects to them.
`Atanor.Discovery` does, in a process that starts after Alambique when the VM is distributed:

* **What `advertise` holds.** The Erlang node name of the peer, `atanor@node-2.cluster`: the one rule. The
  daemon builds it from `ATANOR_ADVERTISE` (`atanor@<host>`, the name `rel/env.sh.eex` gives the VM); an
  embedded instance gives `Atom.to_string(node())`. A string that is not a `name@host` is logged and
  counted (`[:atanor, :discovery, :invalid]`), never dialled.
* **When it dials.** On `peers_changed` and every refresh period (the registry's `refresh_ms`, else its
  `renew_ms`, else 10 s). It reads the current listing each time and calls `Node.connect/1` for the nodes
  it is not connected to, minus itself, in tasks: a host that does not answer takes `net_setuptime` (7 s)
  and must not stop the process. A peer that expired or left is not in the listing and is not dialled again.
  The dial set is a pure function (`Atanor.Discovery.targets/4`) with a property: exactly the live peers of
  the group, minus this node and the connected ones.
* **It never disconnects.** A peer that leaves the registry stays connected. The registry says who is
  *listed*, which depends on renewals, the store and the clock; whether a connected peer is *down* is the
  failure detector's call (§8.7 to §8.10), made from heartbeats on the link. A store that fails for a
  minute would otherwise cut the links of live nodes and trigger takeovers. The detector also
  disconnects a node it confirms down; if the registry still lists it, discovery connects again at the next
  round, as the old `Mesh` did every second, and the detector judges the link anew.
* **Groups.** The `"group"` of `meta` (`ATANOR_GROUP`) limits whom a node dials: it dials only its own
  group. A node of another group is in the store, logged and counted (`:ignored`), and left alone. A swap
  (design §8.11, [how-to-replace-a-node.md](how-to-replace-a-node.md)) needs two nodes that share the
  store and form no cluster; a store prefix of its own would isolate them but also their cells.
* **Trust boundary.** Whoever can write `<prefix>/nodes/` decides whom the nodes dial, so a writer can
  make nodes connect to any host that listens. The cookie still gates the handshake, and it is never in the
  bucket, so a stranger without it cannot join and can only make the nodes spend connection attempts.
  Write access to the bucket must be as trusted as the cluster. Between the nodes, `epmd` (4369) and the
  distribution ports (9100 to 9110 for the daemon) must be open.
* **Single owner.** Discovery changes who is connected, never who owns a cell: that stays in the lease and
  its fencing. `test/cluster/discovery_property_test.exs` runs C1's checks while nodes join (found while
  requests run), stop and die, with peers that are not connected at start. **Mutation:** making
  `Dispatch.execute/3` run every call locally fails it at once, as it fails C1.
* **Tests.** `test/cluster/discovery_test.exs` starts peers that are not connected: two and three nodes find
  each other, a node added later joins, a node that stopped is listed no more while the detector keeps
  the link, a node that was killed is forgotten after the TTL (2.4 s with a 2 s TTL and 400 ms of skew), and a
  node of another group is left alone. Without `Atanor.Discovery` all of them fail. Mutations caught by
  `test/atanor/discovery_property_test.exs`: dialling this node, dialling a connected node, ignoring the
  group, dialling a peer twice, and remembering a peer after it left the listing; a `Node.disconnect` on
  `:left` is caught by the cluster test.

Measured on the VM (4 vCPU, Docker, three nodes of the harness image over SeaweedFS, defaults: TTL 15 s,
renewal 3 s; no list of peers; one run): `cluster:up` with all three nodes seeing three; `docker stop` of
one: the others saw two nodes after 0.1 s (the node announces that it leaves) and dropped it from the
registry after 0.5 s; `docker start`: the others saw it after 1.3 s, and it saw three after 0.05 s more;
`docker kill`: the others saw two nodes after 0.1 s (the detector, from the closed connection) and the
registry forgot it after 17.0 s (the TTL plus the 2 s skew margin).

Limits: a node found by the store but unreachable (a closed port, a name that does not resolve) is retried
every round and logged once. The join time is the renewal period of the peer plus one connect.

## 9. Limits

A WASM call (a request, an alarm or a WebSocket call) has a wall-clock
deadline, a CPU limit and a memory cap. A
worker that exceeds one is stopped, the request fails with
`{:error, {:limit, kind}}`, a `[:atanor, :wasm, :limit]` event is emitted and
the node keeps serving.

| Limit | Set by | Default | Stops with |
| --- | --- | --- | --- |
| wall clock | manifest `limits.timeout_ms`, at most the node setting `max_timeout_ms` | 30,000 ms (ceiling 120,000) | `:timeout`, 504 |
| memory | manifest `limits.memory_bytes`, at most the node setting `max_memory_bytes` | 64 MiB of linear memory per call, all memories together (ceiling 512 MiB) | `:memory`, 500 |
| host resources | node setting `max_resources` | 4,096 field sets, streams and pollables per call | trap, 500 |
| header memory | node setting `max_field_bytes` | 16,384 bytes per `wasi:http` field set | trap, 500 |
| CPU, epoch mode | manifest `limits.cpu_ms`, at most the node setting `cpu_ms` | node `cpu_ms`, 5000 ms | `:cpu`, 500 |
| CPU, fuel mode | manifest `limits.fuel` (at most the node setting `max_fuel`), else the node setting `fuel` | 1,000,000,000 (ceiling 10,000,000,000) | `:cpu`, 500 |
| response body | node setting `max_response_bytes` | 8,000,000 | 500 |
| guests that wait without a call slot | node setting `max_waiting` | 2 per thread | none: a guest above it keeps its slot (§14.2) |

The wall clock covers the wait for host calls (cells, secrets, worker calls,
outbound HTTP). CPU time does not include it. Overload is separate: a call
that finds the queue full, or waits in it longer than `queue_wait_ms`
(default 1000), fails with `:overloaded`, 503. A manifest value above a
ceiling is lowered to it. Host resources and field sets live outside the
linear memory, so they have their own caps. A panic in a pool thread ends
that call with a guest error and the thread goes on serving. The node settings are
documented in `Atanor.Wasm`. `limits.fuel` is read only in fuel mode and `limits.cpu_ms` only in epoch mode (§14.4).

## 10. Observability

### 10.1 Events

`telemetry` events per worker, deployment and cell. [telemetry.md](telemetry.md)
lists them with their measurements and metadata. Every call into a worker
(HTTP, Plug, TCP, WebSocket, alarm) emits `[:atanor, :call]` on the node that
ran it, with `worker`, `deployment`, `cell`, `kind`, `node`, `forwarded`, the
`result` (`:error` with a `reason`, such as `{:limit, :cpu}`) and the HTTP
`status`; its `duration` is the latency of the callback. A forward emits
`[:atanor, :forward]` on the ingress node. Requests the ingress answers itself
(no route, body too large, a host or path refused by §7.1) emit `[:atanor, :http, :reject]`. WASM adds
`[:atanor, :wasm, :load | :prepare | :invoke | :limit]` with the instantiation
time and the limit that was hit. The failure detector emits
`[:atanor, :node, :suspect | :down | :link_broken | :alive]` (§8.8). One event per call, not per layer, keeps the
overhead to one `:telemetry.execute/3` and one table lookup. A crash report
detected at start emits `[:atanor, :crash, :detected]` (§17.2). `[:atanor, :call]` and `[:atanor, :wasm, :invoke]` carry the `instance`.

### 10.2 Admin API

**An open store breaker does not make the node unready.** `/health` and `/runtime` show it
(`store`), and `/health/ready` and `/health/serving` ignore it. Readiness says that the node can
serve (§2.1), and an open breaker leaves most of that: the awake cells keep answering, their
leases renew through it (Alambique 0.5), and calls that need the store get a fast 503
`store_unavailable` instead of a queue (§4.3). The store is shared, so the breakers of the other
nodes open with it: a balancer that left the nodes out would turn a degraded service into none,
and a rolling restart that polled `/health/ready` would stall on an outage that a restart does
not fix. An operator or an alert reads `store` instead; a half-open breaker is the probe, and a
closed one with `failures` above zero is a store that has begun to fail.

`Atanor.Admin` is a Bandit listener of its own (option `admin:`), on loopback
unless `ip:` says otherwise, with no listener when the option is absent. Every
request needs `Authorization: Bearer <token>`, compared in constant time; the
`token` is required, not only off loopback, so that a listener bound by mistake
to a public address is never open, and it is kept out of `inspect` output. It
is read-only apart from deploys and token management (§10.2.1), the platform's hint that a node is gone (§8.9), the
dead-letter controls, the bulk-operation controls (§15.7), the TLS
certificate reload of one listener (§7.3), unfreezing a cell (§17.2) and starting or cancelling a
migration rehearsal (§17.3).
The hint cannot change what runs, only make the cluster stop using a node, and
the infrastructure that knows a machine is lost has no other way to say so.
The job controls are needed for dead letters and managed operations, and every
control action is logged and emits `[:atanor, :admin, :action]`. Endpoints,
JSON; `GET` unless the table says otherwise:

| Path | Answers |
| --- | --- |
| `/health` | this node, its `status` (`ok` or `starting`), the nodes running the instance, the number of active workers, and `store`: the circuit breaker of each store location (`state` `closed`, `open` or `half_open`, `since_ms` in Unix ms, `failures` in a row), read from `Alambique.breaker_status/1` without a request to the store |
| `/health/ready` | 200 `ready` when the node serves; 503 `starting` with the `reason` until it serves (§2.1). Poll it during a rolling restart |
| `/health/serving` | `/health/ready` and a quorum: 200 `serving`, or 503 `no_quorum` while this node is not a majority of the nodes it knows (§8.10; always 200 when ready with `takeover: [quorum: false]`). Point a load balancer at it: a partitioned node leaves the rotation. A rolling restart still polls `/health/ready` |
| `/crashes`, `/crashes/:node/:id` | crash reports from a previous VM death, with the units, their cells and `Alambique.crashes/2` (§17.2) |
| `/rehearsals`, `/rehearsals/:id`; `POST /rehearsals`, `POST /rehearsals/:id/cancel` | migration rehearsals: start (202), list newest first, read a report, cancel (§17.3) |
| `POST /cells/:namespace/:key/unfreeze` | unfreezes a cell and forgets its recorded crashes (`Alambique.unfreeze/2`); the admin action is logged (§17.2) |
| `/workers`, `/workers/:name` | the heads in the store (active id, previous ids, revision); for one worker also the manifest of the deployment this node serves |
| `POST /workers/:name/packages`, `POST /workers/:name/activate`, `POST /workers/:name/rollback`, `GET /workers/:name/versions`, `GET /workers/:name/status`, `GET /heads` | deploys through the API, by scope (§10.2.1) |
| `POST /tokens`, `GET /tokens`, `GET /tokens/:id`, `POST /tokens/:id/revoke`, `GET /audit` | scoped tokens and the audit log, `cluster:admin` (§10.2.1) |
| `/deployments` | for every node, what it applied for each worker: `head`, `applied`, `serving` and `error` (`{:code_mismatch, ...}`, a route not allowed, ...) |
| `/routes` | this node's HTTP routes and TCP listeners with their ports |
| `/runtime` | what this node's memory is made of, for finding what grows: `:erlang.memory()` by type, process, port and run queue counts, the 5 biggest ETS tables, the 10 processes with the longest message queue and the 10 largest (pid, name, initial call, current function), the cgroup v2 `memory.current`, `memory.max`, `memory.stat` (anon, file, shmem, sock, slab, kernel_stack, inactive_file, active_file) and `memory.events` (oom, oom_kill), read next to `:memory` `:cgroup_path` (null when a file is missing; `memory_max` is null for `max`), and the native Wasm gauges (§14). One bounded scan of at most 100,000 processes; this node only |
| `POST /auth/keys/flush` | drops this node's cached OIDC discovery documents and keys, `cluster:admin` (§7.5); answers `node` and `flushed`, the issuers dropped |
| `POST /listeners/:name/reload-tls` | reloads the certificate files of one TLS listener (§7.3); 404 `unknown_listener`, 409 `no_tls`, 422 `reload_failed` (the previous certificate keeps serving) |
| `/cells` | for every node, the number of live cells; with `?node=NAME` one page of that node's cells (`limit` 1 to `:admin`'s `max_limit`, 1,000, default `default_limit`, 100, and `after=<cell id>` from the previous page's `next`) |
| `/nodes` | how this node sees each peer: `state` (`alive`, `suspect`, `link_broken`, `down`), `phi`, `last_heartbeat_ms` and the `reason` of the last verdict (§8.8). Only this node's view; ask every node for the cluster's |
| `POST /nodes/:node/gone` | the platform says the node is lost: it is confirmed down here and at the peers (§8.9). 404 `unknown_node` for a node this one does not know |
| `/jobs`, `/jobs/:namespace/:key`, `/jobs/:namespace/:key/:id` | job counts, one cell's jobs and one job; `POST .../:id/retry` and `/discard` handle dead letters (§15.7) |
| `/operations`, `/operations/:id`; `POST /operations`, `POST /operations/:id/pause|resume|continue|cancel` | bulk operations and their progress (§15.6, §15.8) |

The endpoints that cover the cluster ask every node of the prefix (the members
of the watcher's `:pg` group) through `:erpc` with a 5 second timeout. A node
that does not answer shows `"status": "error"` with the reason and the
response says `"partial": true`; the others are still there.

The admin lists a node's cells with `Alambique.cells/2` (`after:` and `limit:`):
the count is cheap and a page costs its size, whatever the number of cells. The
list follows Alambique's registry by a message, so a cell that has just woken or
stopped may be missing or listed late.
[how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) shows each endpoint.

The JSON of the API and the dashboard pages read the same functions in
`Atanor.Overview`; `Atanor.Admin` only authenticates, parses parameters and
encodes. The functions that describe one node are called on every node with
`:erpc`.

#### 10.2.1 Deploys, scoped tokens and the audit log

A deployer must not hold the bucket credentials, so the writes of §5.4 are
also an API: the node validates and writes, the caller only needs a token.
`Atanor.Deployments.Service` owns the writes (`deploy/3` stores a package and
optionally activates it; `upload/5` first checks the size limit
`:admin` `:max_package_bytes`, the client's SHA-256, `Atanor.Package.parse/1`
with its canonical-manifest check and the `package` limits, that the package is the path's worker, and that a
native module is one the node has).
Activate and rollback are `Atanor.Deployments.activate/4` and `rollback/3`,
which the dev tooling calls as well, so each write has one implementation.
They refuse a head that this node's registry would refuse (routes, namespaces
and the operator's policy, §3.3) before writing it, so a deploy token cannot
leave a conflicting head in the store; the answers are 409 (`namespace_owned`,
`namespace_conflict`, `route_taken`, `listener_taken`, `migrations_lowered`)
and 422 (`namespace_not_allowed`, `host_not_allowed`, `http_not_allowed`,
`module_not_allowed`, `listener_not_allowed`, `module_not_loaded`). The scope
`worker:<name>:deploy` is the authority of that worker's manifest within these
limits, no more. The
admin only maps results to status codes. The contract of these endpoints is
[openapi/admin.json](openapi/admin.json) (OpenAPI 3.1); `test/atanor/openapi_test.exs`
fails when a route of the admin plug is missing from it or the other way round,
and validates its examples and the live answers against its schemas.

**Version index.** Packages are stored by hash, so there is no listing per
worker. Every deploy (`Service.deploy/4`)
also records the package with `Atanor.Deployments.Versions`: a guard object
`versions/<worker>/id/<package id>` (written with `if_none_match`, so a second
upload of the same package is a no-op and a crash between the two writes is
healed by the next upload) and an entry
`versions/<worker>/log/<unix microseconds>-<package id>` with `package_id`,
`kind`, `size`, `uploaded_at` and `uploaded_by`. Keys list oldest first
(the store cannot list backwards), so `GET /workers/:w/versions` pages oldest
first with `after` and `limit`, and marks each entry `active` or `previous` from the head.
Entries are never changed. Packages stored before the index existed are not in it.

**Credentials.** The operator token of the `:admin` option stays the bootstrap
credential and holds every scope. A scoped token is `atn_<id>_<secret>` (12
random bytes in hex, 32 random bytes in base64url). With 256 bits of entropy a
plain SHA-256 of the secret is enough: only that hash is stored, and it is
compared in constant time. The record has `name`, `description`, `scopes`,
`created_at`, `created_by`, optional `expires_at`, `revoked_at` and
`revoked_by`. The secret is in the creation answer only.

**Scopes** (`Atanor.Admin.Scope`): `cluster:admin`, and `worker:<name>:<action>`
with `<action>` in `deploy`, `activate`, `rollback`, `read`. The worker
segment may be `*` (all workers, one action); partial patterns are not
accepted. A wildcard is allowed because a CI that deploys every worker of a
project is common and listing names would make it a token per release; it is
bounded to one action and never covers `cluster:admin`. `cluster:admin` does not imply any
worker scope, so the powers to manage tokens and to deploy can be granted
apart (a holder can still create a token with any scope, which is what token
management means). Scopes are validated on create, with at most
`:max_scopes` per token. Each request names the scope it needs before any
handler runs; a missing scope is 403 and the handler does not run.
`GET /heads` needs any valid token and lists only the workers it may read.
Every endpoint that was not a deploy endpoint before needs `cluster:admin`.

**Storage.** Tokens are objects `tokens/<id>` and the audit log objects
`audit/<time>-<random>` in the instance's metadata store (the bucket and
prefix the deployments already use). Every node sees them without a new
dependency, a revocation is a compare-and-swap on the object, and an audit
entry is written once with `if_none_match` and never changed. An Alambique
cell would need a placement, a schema and the cell machinery to be up before
the admin can authenticate, and the admin listener opens before the node loads
its deployments (§2.1). A request with a scoped token reads its object from the
store, so a revocation is effective on every node on the next request (as soon
as the store makes the write visible); there is no token cache and no TTL to
configure. The cost is one store read per request with a scoped token, which
an admin API accepts. If the store cannot be read the answer is 503, never an
allow.

**Audit.** Every deploy-path write and token create/revoke writes an entry:
actor (`operator` or token id and name), action, worker, version (the package
id), result (`ok`, `denied` for a 403, `failed`), HTTP status, error code,
time, node and remote address. 403s on those writes are recorded; reads and 401s
(whose actor is unknown, and which an attacker could use to fill the bucket)
are not, and neither are the other admin writes, which keep the log line and
`[:atanor, :admin, :action]`. The entry is written after the action, so an
action whose node dies before the write is not in the log, and a failed write
of the entry is logged and counted (`stored: false` in
`[:atanor, :admin, :audit]`) without changing the answer. Keys carry the
time in microseconds, so listing returns oldest first across nodes (to the
accuracy of their clocks) and `GET /audit` pages with `after` and `limit`
(`:default_limit` and `:max_limit`).

**Attempt limit.** `Atanor.Admin.Throttle` limits failed bearer tokens (the
operator's and scoped ones) per client address. The key is the peer address of
the connection, an IPv6 client by its /64; `X-Forwarded-For` is never read,
because Atanor has no trusted-proxy setting, so behind a proxy all clients share
the proxy's address and are limited together (a proxy that limits per client
remains the right place for a finer limit). A window opens at the address's first
attempt after the previous one ended. Each attempt reserves a place in an ETS
counter before the token is compared (`update_counter`, so parallel guesses cannot
pass the limit) and gives it back when the token is right: the success path costs
two table operations and no wait, and the comparison itself is unchanged. After
`max_failures` failures the address gets 429 `too_many_attempts` with
`Retry-After` until the window ends, with the right token too (otherwise the
answer would tell a guess). A request without a bearer token is not counted. The
table is bounded by `tracked_addresses`; at the bound a sixteenth of the entries
goes, so a flood of addresses can release an address from its lockout. The state
is per node and is lost on restart. `test/atanor/admin_throttle_property_test.exs`
checks, against a window model, that an address has at most `max_failures`
admitted failures per window and is never refused under it, and that the table
keeps its cap.

**Properties.** `test/atanor/admin_scope_property_test.exs` generates random
scope sets and random (action, worker) requests and checks, against an
independent string oracle, that every out-of-scope request is 403 and leaves
every head and package as it was, that in-scope requests are never 401 or 403,
that an upload with `activate` needs both scopes, and that malformed, unknown,
wrong-secret, revoked and expired tokens are 401 with no change.

| Option of `:admin` | Default | Meaning |
| --- | --- | --- |
| `max_package_bytes` | 67,108,864 | largest package upload; 413 `package_too_large` beyond it |
| `max_scopes` | 64 | scopes per token |
| `default_limit`, `max_limit` | 100, 1,000 | page size of lists, including `/tokens` and `/audit` |
| `max_failures`, `failure_window_ms` | 10, 60,000 | failed tokens per client address in a window (and, in `dashboard:`, failed `?token=`); past it the address is refused with 429 and `Retry-After` until the window ends, even with the right token |
| `tracked_addresses` | 10,000 | client addresses kept; at the bound a sixteenth is dropped |
| `unknown_token_ms`, `unknown_tokens` | 2,000, 1,000 | a well-formed token id that the store does not have is refused from memory for this long, and at most this many ids are kept, so random tokens do not each cost a store read; a token created meanwhile works after the time |

#### Limits

**The audit log has no retention.** A forbidden call on an audited endpoint
writes an audit object that Atanor never deletes: the log is immutable by
design. Workaround: give the `audit/` prefix of the bucket a lifecycle rule that
expires old objects. Evidence: `lib/atanor/admin/audit.ex` writes entries and
lists them; nothing deletes them.

### 10.3 Dashboard

A read-only Phoenix LiveDashboard with six pages of its own (workers,
deployments, routes, cells, alarms, jobs) and the built-in Metrics page fed by
`Atanor.Dashboard.Metrics` (`Telemetry.Metrics` definitions over the events of
[telemetry.md](telemetry.md)). Pages are in [screens.md](screens.md). Decisions:

* **Optional, compiled only when present.** `phoenix`, `phoenix_live_view`,
  `phoenix_live_dashboard` and `telemetry_metrics` are `optional: true`. Every
  module that uses them sits inside `if Code.ensure_loaded?(Phoenix.LiveDashboard)`;
  `Atanor.Dashboard` (always compiled) answers `available?/0` and names the
  dependencies. A project that adds the dependencies later must run `mix deps.compile
  atanor --force`, because Mix does not recompile a dependency when an optional
  dependency of it appears. `Atanor.Config` rejects `dashboard:` when the
  modules are missing. `mise run check:no-phoenix` compiles and runs
  `examples/hello-native`, which has no Phoenix, and checks that no dashboard
  module exists and that `mix atanor.dev` explains the missing dependencies.
* **Own listener, token always.** Option `dashboard: [token:, port:, ip:]` (port
  4002, loopback), validated like `admin:`; no option, no listener. The
  endpoint is a module, so a VM runs one dashboard; the instance it shows is in
  the endpoint configuration (`atanor_instance`). Phoenix reads its options from
  the application environment, so the supervisor writes them there at start,
  with a random `secret_key_base` per start.
* **Token before LiveView, on every path.** `?token=` on a `GET` is compared in
  constant time, limited per client address like the admin API's tokens (§10.2;
  the dashboard has the same `max_failures`, `failure_window_ms` and
  `tracked_addresses`, and answers 429 with `Retry-After`), and answered with a 303 to the same URL without it, setting a
  signed cookie (`SameSite=Strict`, `Max-Age` `cookie_max_age_s`, 86 400 s by
  default, and `Secure` when `secure_cookie: true`; the listener is plain http,
  so the option says that a proxy serves https) that says "signed in". Every other request
  without that cookie gets 401, assets included. The socket
  (`Atanor.Dashboard.Socket`) refuses a connection whose cookie lacks the
  sign-in, on top of Phoenix's origin check (`:conn`: the origin must be the
  host asked for) and CSRF check; and an `on_mount` hook refuses to mount a
  LiveView whose session lacks it. A restart signs everyone out. A token in a
  query string can reach logs and history: it is for a loopback or private
  listener, and the 303 keeps it out of later URLs.
* **Read-only.** No page has a button or event that changes state; the default
  pages of LiveDashboard are kept, its destructive actions stay off, and the
  request logger page is off.
* **Pages share the queries.** Each page loads its data in `handle_params/3`
  and `handle_refresh/1` (the dashboard's "Update every" selector) from
  `Atanor.Overview`. The node selector of the dashboard picks the node whose
  routes and cells are shown; deployments cover every node. Cells and alarms
  page with a cursor (`?after=`, `?limit=` from 1 to the dashboard's
  `max_page_size` (500), default `page_size` (50)) because
  `Alambique.cells/2` and the store listing are cursor based, which the
  dashboard's table component (a top-N list) cannot express; the pages use the
  dashboard's table styles.
* **Alarms** come from the store index (`Atanor.Alarms.pending/3`), so they
  include alarms claimed for a retry and stale entries not yet removed, and the
  order is the key order (minute, then shard), not strictly by due time.
* **Native counters** are not emitted by anything on their own. A small poller
  (`Atanor.Dashboard.Poller`, every `poll_ms`, 5 seconds by default) calls
  `Atanor.Wasm.Stats.emit/0` and
  `Alambique.NativeStats.emit/0`; the charts show the values (counters are
  cumulative) in two groups, `Wasm native` and `Alambique native`. It runs only
  with the dashboard; an application that wants these events without it
  polls them itself.
* **No history.** LiveDashboard charts start when the Metrics page is opened;
  there is no store of past points. Use the events with an exporter for history.
* **`mix atanor.dev`** starts the dashboard when the project has the
  dependencies, on 4002 with a random token printed in the URL; without them it
  prints what to add and goes on.

## 11. Test kit

`atanor_testkit` (in `testkit/`) starts nodes and clusters over the alambique
testkit store and offers fault injection. Its sources are compiled into the
test build of Atanor (`elixirc_paths`), because the package depends on Atanor.
`AtanorTestkit.Node` starts one node. `AtanorTestkit.Cluster` starts peer
nodes (`:peer`, on `127.0.0.1`; it needs `epmd`), each with an Atanor instance
of the same name and prefix over one `AlambiqueTestkit.MemoryStore` on the test
node. It mirrors `AlambiqueTestkit.Cluster`, which starts only an Alambique
instance and so cannot be reused: peers get ephemeral HTTP and admin ports,
`deploy/3`, `activate/4` and `rollback/3` (also for a subset of the nodes, so
they can run different versions), `kill/2` and `restart/2` (a peer can have
options of its own, such as its `release`, with `:peer_atanor` and the
`atanor:` of `restart/3`), a partition of the
store (`partition_store/2`, `inject/3`) or of the distribution
(`partition_nodes/3`; the two sides get different cookies for each other, so
nothing reconnects them), the operating system's signals to a peer's process
(`kill_process/2` for SIGKILL, `pause/2` and `resume/2` for SIGSTOP and SIGCONT:
a stopped process keeps its sockets open and answers nothing, like a machine
that disappeared; only the processes of peers it started are signalled), clock
skew, and the telemetry of every peer, forwarded with the operating system
time. Cluster tests carry `@moduletag :cluster`, are
excluded by default (as the `seaweedfs` ones) and run with `mise run
test:cluster`; they start 2 or 3 peers per test or property run, which takes
about two minutes in all on a quiet machine (§12.5).

Properties (StreamData):

* C1 single owner across node failures, including peers stopped and resumed
  (`test/cluster/properties_test.exs`, §8.5);
* the phi math: monotonic in the silence, and less suspicious on a jittery
  link (`test/atanor/detector_phi_test.exs`);
* D1 no request split across deployments, on one node (§5.4) and across nodes
  (§8.3);
* alarms across real nodes: every committed alarm fires at least once and the
  duplicates are counted and bounded (§7.4);
* B1 a WASM worker cannot reach an ungranted binding;
* L1 runaway workers are stopped and the node stays healthy.

Mutation checks: making `Dispatch.execute/3` run every call locally fails C1
and six example-based cluster tests; making the remote node use its own
active deployment instead of the pinned one fails the cross-node D1 property.

## 12. Measurements

How to read this section. Every figure comes from a `mise run bench:*` task or a
test named next to it, run on one laptop-class machine with 12 logical
processors (Erlang/OTP 28, Elixir 1.20) that shared its cores with other work.
Figures move by tens of percent between runs on such a machine, so treat them
as orders of magnitude; only comparisons made in one session mean anything.
Statements marked *inference* were not tested. Unless a section says otherwise,
figures were taken when the code they describe was last changed and have not
all been measured again; re-run the named task before relying on one.

| Measurement | Result | Section |
| --- | --- | --- |
| Native worker over HTTP, no cell | about 130,000 requests/s, p99 0.9 ms | 12.2 |
| Native worker, one cell write per request | about 10,600 requests/s, p99 6.7 ms | 12.2 |
| WASM worker over HTTP, no cell / with a cell write | about 8,200 / 5,600 requests/s | 12.2 |
| Cold WASM instantiation | 0.22 ms (warm 0.08 ms); compile 36 ms, once per component | 12.1 |
| 20,000 cells on one node, woken by requests | 1,093 cells/s, 135 KB of BEAM memory per awake cell (Alambique alone: 1,052 cells/s, 124 KB) | 12.3 |
| Jobs enqueued in one cell / run end to end | 3,300 to 3,700 jobs/s enqueued, 375 to 400 jobs/s with a handler writing two rows | 12.9 |
| One job in 1,000 cold cells / a sweep over them | 623 to 660 cells/s enqueue, 324 to 350 cells/s sweep | 12.9 |
| A request forwarded to the owner on another node | 6,000 writes/s against 8,500 when local (loopback, three nodes on one machine) | 12.4 |
| Failover | the cell answers again about 0.1 s after the failure detector confirms the loss: 5 s for a lost machine with the defaults, milliseconds for a killed process or a platform hint; a graceful stop hands the cells off in 10 ms with no client errors | 12.7, 12.8 |
| Store requests per job | 0.4 to 2.7 on the job path (25 and 100 ms of store latency) | 12.13 |

### 12.1 WASM workers

`mise run bench:wasm` (`bench/wasm.exs`): one node in the test build over the
memory store, 12 guest threads, the `hello` guest (a 181 KB component built
from `test/fixtures/guests`), one run per mode.

| Measurement | Epoch (default) | Fuel |
| --- | --- | --- |
| cold compile, no cache | 36 ms | 70 ms |
| cold start, compiled code loaded from the disk cache | 1.2 ms | 1.8 ms |
| instantiation of the first request after a compile / after a disk load | 0.22 / 0.19 ms | 0.25 / 0.20 ms |
| warm instantiation (mean of 2000) | 0.079 ms | 0.094 ms |
| whole request inside the NIF (mean of 2000, includes the instantiation) | 0.149 ms | 0.174 ms |
| `hello` over HTTP, 32 clients, 5 s | 12,941 requests/s | 14,246 requests/s |
| CPU-bound request, 200M loop iterations, median of 5 | 186 ms | 224 ms |

Fuel metering costs 20 percent on the CPU-bound guest. The HTTP throughput is
higher with fuel; the Elixir client and Bandit are the bottleneck there, so
that is noise (inference). Epoch mode is the default (§14.4).

The Wasmtime pooling allocator (`pooling: true`, §14.9) makes warm
instantiation 0.018 ms and the whole request in the NIF 0.065 ms, and `hello`
over HTTP 21,900 requests/s, without slowing the CPU-bound request. It costs
address space and resident memory: 390 GiB of address space and 284 MiB
resident after `bench:wasm`, against 2.4 GiB and 207 MiB without the pool.

Property L1 (`test/atanor/wasm_properties_test.exs`, 4 guest threads): 16
runaway guests (8 spinning, 8 allocating) and 40 `hello` requests finish in
about 0.85 s; the BEAM's `Process.sleep(1)` took at most 2 ms and an Agent call
at most 1 ms during the storm.

### 12.2 HTTP requests

`mise run bench:http` (`bench/http.exs`): one node in the test build over the
memory store, 32 keep-alive clients on the same machine (`bench/load.exs`, a
small `:gen_tcp` client), 5 s per case after 1 s of warm-up. A native worker (an
echo) and a WASM worker (the `hello` guest), each without a cell and with a
write to one of 64 cells (the native counter worker routes by cell and runs one
transaction; the `cell` guest runs one `execute`).

| Case | Requests/s | p50 | p95 | p99 |
| --- | --- | --- | --- | --- |
| native, no cell | 131,916 | 0.20 ms | 0.51 ms | 0.86 ms |
| native, write to a cell | 10,626 | 2.7 ms | 5.1 ms | 6.7 ms |
| WASM, no cell | 8,181 | 3.6 ms | 6.8 ms | 8.7 ms |
| WASM, write to a cell | 5,558 | 5.4 ms | 8.5 ms | 12.7 ms |

On a machine loaded by other work (load average above 25) the same command gave
25,000 to 91,000 requests/s for the native echo and 1,900 to 6,300 for the WASM
write, so only a quiet machine is comparable. The WASM figure is lower than the
12.9 thousand of §12.1 because the load generator shares the machine with the
guest threads and replies with a body the client reads (inference). A cell write
is a commit that Alambique acknowledges after the store has the batch (here the
memory store); Alambique's `bench:commit` measures that alone.

### 12.3 Cells

`mise run bench:cells` (`bench/cells.exs`) wakes N cells with one HTTP request
each (the counter worker appends a row, 256 clients), sends the same requests
again to the awake cells, and waits for the idle timeout to put them to sleep.
It mirrors Alambique's own `mise run bench:cells`, which wakes the cells with
`Alambique.execute/5` directly.

| Cells | Wake all (cells/s) | p50 / p99 of the cold request | BEAM MB awake / asleep | RSS MB awake / asleep | Open fds awake / asleep | Second pass on awake cells |
| --- | --- | --- | --- | --- | --- | --- |
| 5,000 | 4.2 s (1,183/s) | 209 / 287 ms | 725 / 111 | 1,117 / 413 | 15,058 / 58 | 12,658 req/s, p50 20 ms |
| 20,000 (idle timeout 150 s) | 18.3 s (1,093/s) | 228 / 301 ms | 2,701 / 225 | 3,858 / 792 | 60,058 / 58 | 10,565 req/s, p50 24 ms |

An awake cell costs about 136 KB of BEAM memory through Atanor and 190 to 200 KB
of RSS; a node with no cells uses 60 MB of BEAM memory and 155 MB of RSS.
Processes and open files return to their baseline after the cells sleep.

Alambique alone (`Alambique.execute/5`): 1,233 cells/s and 685 MB of BEAM memory
awake at 5,000 cells; 1,052 cells/s and 2,546 MB at 20,000. Atanor's cold wake
is within a few percent of it, and a cell costs 12 KB more (the HTTP layer and
the routing).

A wake that takes longer than the idle timeout finds cells asleep again: with
the default 20 s timeout and a loaded machine, a 20,000-cell wake ended with
3,383 cells awake. That is why the run above uses 150 s.

### 12.4 Cluster

`mise run bench:cluster` (`bench/cluster.exs`): three peer nodes on this machine
over the memory store, the counter worker, 96 write cells and 96 read cells
woken first. All load (32 clients, 5 s) goes to the HTTP port of `n1`; "owner
is the ingress" uses the cells `n1` owns and "forwarded" the cells the other
two own. The nodes and the load generator share the cores; the network is the
loopback.

| Case | Requests/s | p50 | p95 | p99 |
| --- | --- | --- | --- | --- |
| write, owner is the ingress (31 cells) | 8,495 | 3.5 ms | 6.7 ms | 8.9 ms |
| write, forwarded to the owner (65 cells) | 6,004 | 4.9 ms | 9.5 ms | 12.2 ms |
| read, owner is the ingress (27 cells) | 26,897 | 1.0 ms | 2.7 ms | 4.6 ms |
| read, forwarded to the owner (69 cells) | 15,623 | 1.8 ms | 4.0 ms | 5.8 ms |

A forwarded request costs about 1.4 ms at p50 on writes and 0.8 ms on reads over
the loopback, and 30 to 40 percent of the throughput of this setup. The forward
is one `:erpc` call carrying the request and the response, and a hint lookup;
the owner lookup is not on the path once the hint is set. On a real network the
cost is the round trip between the nodes. These runs do not include a node
failure (§8.4).

### 12.5 Cluster properties

`mise run test:cluster` runs the cluster tests on peer nodes, three of them
properties: C1 (12 runs of 20 to 40 steps), D1 across nodes (8 runs of 12 to 25
steps) and the alarms property (6 runs of 15 to 30 steps). The whole task takes
about 3 to 4 minutes on a quiet machine and up to 10 minutes on a busy one. In
the C1 runs, 9 to 28 requests are sent per run, of which 2 to 25 are
acknowledged; the others get no answer (a dead or partitioned node, or a lease
that has not expired). In the alarms runs, 2 to 9 alarms are committed per run
and none fires twice. Timing-dependent tests are deterministic: the nodes of the
routing tests reload heads only when told, and the tests of the wait for the
lease turn the takeover off.

### 12.6 Cluster lab

`mise run lab:up` and `lab:test` ([how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md)):
three KVM VMs (an Arch Linux image, a release of `lab/app`) over one SeaweedFS in
a fourth VM, on an isolated libvirt network, with faults injected inside the
VMs. The load writes to 24 cells through the three nodes and checks afterwards
that every acknowledged write is in its cell.

| Scenario | Measured |
| --- | --- |
| A machine disappears (detector off) | its cells serve again 63 to 72 s later with the default `net_ticktime` (60 s), 24 to 28 s with 10: forwarded calls wait for the ticker, not for the lease |
| A node stops gracefully | 0.6 to 0.9 s (the leases are released) |
| Partition of a node from its peers | requests that cross the cut wait for the client's timeout; nobody takes the cells (the leases hold) |
| Latency between nodes | a forwarded request costs one round trip: +41 ms at 20 ms one way, +161 ms at 80 ms; local requests do not change; 5 % loss puts forwarded p95 at 165 ms |
| Store cut | every write waits; cut 15 s or 60 s, service resumed within 20 s of the heal |
| Clock skew of one node, +1, +5, -5, +20 s | no visible effect; one burst of 5 x 503 at +20 s |
| All scenarios | no acknowledged write lost; no write applied twice (Alambique's `:outcome_unknown` covers a lost forward) |

Placement of hot cells in the lab: a move takes 0.4 to 0.9 s under load and 0.5
to 1.3 s after a CPU hog starts on the owner, with no request failed and no
write lost. One hot cell on these 2 vCPU nodes takes about 1,000 writes and
1,400 reads per second.

### 12.7 Failure detection

`mise run bench:detector` (`bench/detector.exs`): three peer nodes on one machine
over one in-memory store, lease ttl 5 s with a skew margin of 1 s, the default
detector settings (§8.7), three runs of each case. A cell is woken on the victim;
"down" is the time from the fault until a survivor marks the victim down,
"served again" until a write to the cell through a survivor succeeds.

| Fault | Down | Served again, with takeover | Served again, takeover off |
| --- | --- | --- | --- |
| `SIGKILL` of the process | 4 to 5 ms | 78 to 79 ms | 5,990 to 6,057 ms |
| `SIGSTOP` of the process (a lost machine) | 4,740 to 4,785 ms | 4,829 to 4,878 ms | 6,016 to 6,043 ms |
| `SIGSTOP` and the platform hint | 5 to 13 ms | 83 to 109 ms | 5,978 to 6,042 ms |
| Graceful stop | 3 to 4 ms | 131 to 135 ms | 132 to 137 ms |
| `SIGSTOP`, detector off (`phi_threshold` 1,000,000) | never | 71,614 to 71,918 ms | same |

Without the takeover a cell is served again when the lease expires (5 s + 1 s
here), whatever the fault; without the detector too, the writes forwarded to the
stopped node wait for the 60 s limit of a forwarded call and then retry, which
is 71.6 s. With the takeover the cell is served again about 100 ms after the
verdict: the time is the detection time, and the lease does not matter (30 s by
default). A killed process is seen at once by Erlang; the detector adds the
verdict, and the takeover turns the lease wait into 78 ms. The graceful stop is
fast because the node hands its cells off. The 4.7 to 4.8 s of `SIGSTOP` is
`interval_ms + acceptable_pause_ms + 5.6 * min_std_ms` = 4.1 s, plus the probes
(the stopped peer cannot answer, so they wait `indirect.timeout_ms`, 1 s).

**Graceful stop under load.** Clients send `GET` and `POST` every 10 ms through
the two other nodes to 60 cells while the third stops; that node owned 19 to 25
of them. The stop took 8 to 12 ms, of which the drain was 3 to 4 ms, and the
`GET` and `POST` requests had no error. A `POST` that was on the stopping node
may answer 503, which is allowed for a write; a `GET` must have none.

**Heartbeat cost** on an idle cluster with the defaults (1 s), measured as the
difference in packets and bytes sent over the distribution sockets with the
interval at one hour: 3 nodes, +2.0 packets/s and +86 bytes/s sent per node (one
43-byte message to each of 2 peers); 6 nodes, +5.0 packets/s and +215 bytes/s.
The detector process used 336 reductions/s on 3 nodes and 689 on 6: well under a
millisecond of CPU per second (inference from the reduction rate). The cost
grows with the number of peers, so a cluster of hundreds of nodes would want a
longer interval or a sampled peer set; that is not built.

**False positives.** `test/cluster/detector_test.exs` (interval 200 ms,
acceptable pause 600 ms, minimum deviation 50 ms, threshold 8): a `SIGSTOP` of
300 ms and a peer with every scheduler spinning for 4 s produce no `suspect`,
`down` or `link_broken` event on any node. A pause longer than the acceptable
pause plus a few deviations is a failure by definition (§8.7), and a node that
comes back from one returns to `alive`.

**A saturated link.** On loopback a 1 GiB message delays the heartbeats behind it
by about 2 s (plain Erlang nodes, heartbeats sent with `:nosuspend` every 100 ms
while it crosses; one of them was refused). Local sockets are too fast to hold
them for longer, so `test/cluster/detector_test.exs` (a saturated link) suspends
the detector of one node, which holds its heartbeats back, while it sends 32 KiB
messages to a peer for 4 s: the peer has no heartbeat for over 3 s and does not
suspect it. Without the check of received bytes it suspects it after about 1.1 s;
when the bytes stop, it suspects it with the check too.

**Tests.** `test/cluster/detector_test.exs` covers a `SIGKILL` seen without phi,
a `SIGSTOP` found by phi and the probes, `SIGCONT` returning the node to `alive`
with no row applied twice, a cut between two nodes while the third reaches both
(`link_broken` on both sides, no `down` event, 503 across the cut and 200
through the third node), the platform hint (down at the node and at its peer
within 15 ms, 401 without the token, 404 for an unknown node), a graceful stop
(`down` with reason `left`) and the two false-positive cases. C1 (§8.5) also
freezes nodes until a survivor confirms them down, serves their cells through
the survivors, thaws them, and takes cells from healthy owners.
`test/cluster/takeover_test.exs` (lease 20 s so that the detection time is
visible) checks that for `SIGSTOP`, `SIGKILL` and the hint the cell is served
again in the detection time (1.5 to 1.8 s with the test settings, 16 to 60 ms for
the kill and the hint) and the epoch rises once; that a `GET` in flight when the
owner froze is repeated and served after the takeover; that a resumed old owner
gets `{:error, :fenced}` on a write and no acknowledged write is lost or applied
twice; that a plain read on it can return old data where a read with
`verify_lease` returns the new owner's; that two ingress nodes taking the same 17
cells with 136 concurrent requests raise every epoch once; that a broken link
and a node without a majority take nothing; that `takeover: [enabled: false]`
leaves the cell to its lease; and that a node that stops gracefully has no `GET`
error under load.

### 12.8 Detection and takeover in the lab

The VM lab of §12.6 with the defaults everywhere (heartbeat 1 s, phi 8, pause
2 s, lease 30 s), three runs of the faults; the commands are in
[how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md).

| Fault on node 2 | Down at node 1 | Cells served again (median of the runs) |
| --- | --- | --- |
| `virsh destroy` | 4.5 to 5.3 s | 6.3 to 8.3 s |
| `kill -9` of the beam | 0.33 to 0.43 s | 0.53 to 0.80 s |
| Partition from both peers | 4.9 to 5.0 s | 5.6 to 6.2 s |
| `virsh destroy`, takeover off | 5.1 s | 23.5 s |
| `systemctl stop` / `virsh shutdown` | n/a | 0.92 s / 0.57 s, no errors |

False takeovers: none for pauses of the beam of 2 s and 3.5 s, for 30 s of CPU
hogs on both vCPUs, or for clock skew of +1, +5, -5 and +20 s (the detector uses
the monotonic clock); a pause of 8 s is a failure and took 5 cells, with the old
owner fenced and nothing lost. Heartbeat cost on three nodes: +1.9 packets/s and
+87 bytes/s sent per node, about 350 reductions/s in the detector. Six partition
runs: no acknowledged write lost, no row applied twice, and no cell moved to the
isolated node. The same measurements on one machine are in §12.7.

### 12.9 Jobs and bulk operations

`mise run bench:jobs` (`bench/jobs.exs`): one node over the in-memory store with
the test worker; 1,000 cells and 2,000 jobs in one cell. The first phase
enqueues N jobs in one awake cell; the second wakes N cells and enqueues one job
in each; the third enqueues and waits for N jobs' handlers (each does two cell
writes); the fourth creates a prefix sweep over N cells and waits for `done`.
Each phase waits for its jobs before the next one starts. The timings include the
store writes, the schema creation on first use of a cell, the alarm index and
the HTTP and API layers. The cells are cold at the start of the enqueue phase, so
the many-cell rate is the price of a first job in a cell, not of an awake cell's
enqueue.

| Phase | Result (two runs) |
| --- | --- |
| Enqueue in one awake cell | 3,295 to 3,695 jobs/s |
| Enqueue one job in 1,000 cold cells | 623 and 660 cells/s |
| End to end, one cell (handler writes two rows) | 375 and 398 jobs/s |
| Sweep one job over 1,000 cells | 324 and 350 cells/s |

The one-cell enqueue is a single SQLite writer. The end-to-end rate includes the
claim transaction, the handler's two cell writes and the finish and re-arm
transaction; it is bounded by those cell transactions and the bench's
`cell_concurrency` (16), not by the queue. The sweep is throttled by the same
cell work. The Atanor schema of a cell is created by one `Tx.script/2` (one
capture cycle, §15.1), and the `_atanor_` tables have no capture triggers, which
makes their writes cheaper. A second sweep over the same cells does not pay the
schema cost again. The sweep bench raises `sweeps.rate_per_s` to 10,000 and
`sweeps.concurrency` to 32; with the defaults (50/s and 8) an operation is
capped at 50 cells/s and 8 cell transactions in flight, so raise both in
`sweeps:` for a large sweep. For comparison, `bench:cells` wakes 1,039 cold
cells/s on the same machine.

**Claiming the next job when one finishes (§15.5).** `mise run bench:jobs` first
drains a burst of 100 jobs enqueued in one cell with `cell_concurrency` 4, the
default one-second `alarms.tick_ms` and a handler that writes two rows, once with
`claim_on_finish: false` and once with `true`, and times from the end of the
enqueue to the last effect:

| `claim_on_finish` | Time to drain 100 jobs | Scans |
| --- | --- | --- |
| false (one claim per scan) | about 25,000 ms | 25.0 |
| true (the finish claims the next job) | about 1,050 ms | 1.0 to 1.1 |

With `ATANOR_BENCH_CLAIM_ON_FINISH` `on` or `off` (`cell_concurrency` 16):

| Phase | off | on |
| --- | --- | --- |
| End to end, one cell | 369 and 389 jobs/s | 1,143 and 1,215 jobs/s |
| Enqueue in one cell while its jobs run | 4,327 and 4,777 jobs/s | 1,456 and 1,467 jobs/s |
| Jobs that ran while the 2,000 were enqueued | 272 and 256 | 1,909 and 1,913 |

The enqueue rate is lower with the option on because the cell has one writer.
With the option off, jobs start only at a scan and only about 260 of the 2,000
run during the enqueue, so the enqueue has the writer almost to itself. With it
on, nearly all the jobs claim, run and finish during the same time, so the writer
does the enqueues and the jobs' transactions together: enqueuing and running
2,000 jobs takes about 1.4 s instead of about 5.4 s. A queue that enqueues into a
cell while the cell's jobs are running sees the lower enqueue rate;
`claim_on_finish: false` gives it back at the price of the scan-rate drain.

### 12.10 Crash breadcrumbs

This table was measured on an earlier version of the code and has not been
measured again; re-measure with the commands below before relying on it.
`mise run bench:jobs` and `mise run bench:http` take
`ATANOR_BENCH_BREADCRUMBS=off|durable|all`, which sets
`diagnostics: [breadcrumbs: ...]`. Three runs per mode on a quiet machine; the
table gives the median and the observed range.

| Bench | `:off` | `:durable` (default) | `:all` |
| --- | --- | --- | --- |
| Jobs end to end, one cell | 376 jobs/s (361-422) | 350 jobs/s (348-370) | same as `:durable` (no HTTP) |
| Sweep one job over 1,000 cells | 114 cells/s (107-116) | 115 cells/s (108-118) | same as `:durable` |
| HTTP native, no cell | 100k-125k req/s | 105k-126k req/s (no per-request unit) | 50k-52k req/s |
| HTTP native, cell write | 9.1k-11.3k req/s | 8.4k-10.5k req/s | 9.9k req/s (cell work dominates) |
| HTTP WASM, no cell | 8.1k-9.6k req/s | 8.9k-9.8k req/s | 9.3k req/s |
| HTTP WASM, cell write | 5.6k-7.0k req/s | 5.8k req/s | 5.5k req/s |

`:durable` costs one file create, two `pwrite`s and one unlink per job, alarm,
sweep page, migration, deployment activation or WebSocket connection; in the job
bench that is about 7% of end-to-end throughput, within the noise of the machine
(the sweep and HTTP cases show no consistent cost, because the cell or the guest
dominates). It does not cover HTTP requests.

`:all` adds one marker per HTTP or TCP callback. In the no-cell native case the
file churn roughly halves throughput, so this is an order-of-magnitude warning,
not a coefficient. The cell-write and WASM cases are limited by the cell or the
instantiation, which hides the marker. `:all` is for incident reproduction, not
a production default.

The marker follows the durability rule of Alambique's in-flight markers: no
fsync, so a VM crash keeps the page cache and a whole-machine crash may lose it.
The cost of a missing marker is a less detailed report, never a wrong cell write.

### 12.11 Rolling restart

`test/cluster/rolling_restart_test.exs` stops three peers one after another
(graceful stop, then a new VM with the same name, connected to the others before
its instance starts) under `GET` and `POST` load through the other two, with a
300 ms delay on the first five store requests of the starting node so that its
first load of the deployments lasts about a second. It requires no `GET` error
and no `POST` `owner_unreachable`, including in the stop windows, `/health/ready`
503 then 200, and no cell woken on the node before `[:atanor, :deployments,
:loaded]`.

The test passes on a quiet machine and on one kept busy by 16 busy loops on 12
cores (a run takes 22 to 46 s instead of 8 s, with about 3,000 to 4,500 requests
each). The order of §2.1 (deployments first, then the cluster) is what makes it
pass: starting the instance before the watcher's first load makes the new node
wake cells before it applied the worker. The stop windows depend on forwarding
to a leaving node still working while it holds its cells, on handlers that tolerate
Alambique shutting down, and on a draining node refusing to wake a cell with
`owner_down` (§8.11).

### 12.12 Rolling restart through the gate

Removed with the node-release gate (§18). §12.11 measures the rolling restart.

### 12.13 Store round trips of a job

Question: when the store is slow, how many requests does a job cost, and how
fast does one cell finish jobs? The command is `mise run bench:job-trips`
([how-to](how-to-measure-job-round-trips.md)). It starts a node over the
SeaweedFS container, behind a proxy (`bench/store_proxy.exs`) that waits the added
latency once per request and counts requests by method and path. 100 jobs are
enqueued in one cell, due at about one instant; the drain is timed from the first
claim to the last finish. The worker is the test `JobWorker`, whose handler writes
two rows (two cell transactions) per job; with `--handler none` it writes
nothing, so the run measures the job path alone. Settings: `alarms.tick_ms`
1,000 and `claim_on_finish` on (defaults), `cell_concurrency` 1, 4 and 16. The
counts are requests received by the store, whoever sends them; `--trace` adds
the Atanor and Alambique functions on the stack of each call.

The bench runs each case twice, with the writing handler and with
`--handler none`, and prints the **job path** (the run that writes nothing) and
the **handler** (the difference per kind of request). The handler's own
transactions, their segment uploads, their change feed objects and the
compaction they trigger are the application's work; enqueue, claim, finish, the
`@jobs` alarm, the lease and the fence are the job path.

**Requests per job and jobs a second** (100 jobs; the columns come from separate
runs of the same command on the same host, not from one session):

| Added latency | `cell_concurrency` | Job path, requests per job | Total, requests per job | Jobs/s, writing handler | Jobs/s, no-write handler |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 25 ms | 1 | 1.76 | 4.81 | 9.1 | 31.3 |
| 25 ms | 4 | 0.75 | 1.17 | 21.7 | 109.2 |
| 25 ms | 16 | 0.57 | 0.56 | 66.3 | 142.7 |
| 100 ms | 1 | 2.73 | 7.24 | 2.2 | 7.4 |
| 100 ms | 4 | 0.69 | 2.00 | 6.5 | 23.5 |
| 100 ms | 16 | 0.41 | 0.80 | 22.1 | 36.9 |

(The jobs a second were measured at different loads, so read them as orders of
magnitude.) The job path by kind of request, at 25 ms with `cell_concurrency` 1
and 4 and at 100 ms with 1, per job:

| Kind | 25/1 | 25/4 | 100/1 |
| --- | ---: | ---: | ---: |
| Segment upload | 1.09 | 0.32 | 1.15 |
| Segment read, head (compaction) | 0.36 | 0.27 | 0.65 |
| Lease object read | 0.06 | 0.05 | 0.22 |
| `@jobs` entry write, delete | 0.17 | 0.05 | 0.47 |
| Lists and polls (time-driven) | 0.07 | 0.06 | 0.24 |

Enqueueing costs 0.1 request per job and waking the cell costs 8 or 9 requests
once. After a drain 0 to 2 index entries are left under `alarms/` (more at slow
stores); a stale entry expires after `alarms.timeout_ms` (30 s).

**Where the requests come from.** The code that issues each kind, from `--trace`
and from reading the code:

| Kind | Issued by | Needed for |
| --- | --- | --- |
| Alarm index entry write and delete | `Jobs.rearm_tx/5` and `Jobs.apply_rearm/3` → `Alarms.put_index/6`, `Alarms.delete_index/6` | A wake-up at the earliest lease expiry of a claimed job, so that a job whose node died is claimed again after `claim_ms`. A finish leaves the entry where it is while it is not later than the next wake |
| Index entry read, lease read for it | `Alarms.expire/3` and `unmatched/4` in the scan | Not deleting an entry while a `set_alarm` that wrote it first may still be writing its row; a stale entry is dropped only on a read that cannot be stale (§8.12) |
| Lease read by the fence | `Fence.refresh/3`, `read_now/3` → `Alambique.lease/3` | Local-time fencing (§8.13), at handler start and every `routing.fence_check_ms` (1 s) while a handler runs |
| Ownership check | `Dispatch.ownership/2` | Fencing of a node that lost its cell; at most one read in `routing.owner_check_ms` (1 s) |
| Segment upload | `Alambique.Replication.Replicator.upload/3` | Durability of each cell transaction (claim, handler writes, finish), which exactly-one completion and fencing rest on; commits that queue together share an upload |
| Segment read, head, list of the cell | `Alambique.Compaction` | Background merge of segments |
| Change feed upload | `Alambique.Feed.Publisher.publish/3` | The change feed of the worker's own tables (commits outside `_atanor_` tables); Atanor groups up to 16 batches per object (§4.3) |
| List of `alarms/`, `workers/`, `operations/` | `Alarms.page/8` (every `tick_ms`), `Deployments.workers/3` (every `poll_interval_ms`, 5 s), `Sweeps.list/3` (every `sweeps.poll_ms`, 5 s) | Finding due alarms, new deployments and new bulk operations; time-driven, so slower jobs pay more of them |

A "GET on the bucket root" is an S3 list (`Alambique.Store.S3.list/4` sends
`GET /<bucket>/?list-type=2&prefix=...`), not a health check. Its issuers are the
alarm scan, the deployments watcher, the sweeps manager and Alambique's
compaction of the cell; together they cost 0.1 to 0.2 request per job at 25 ms.
A node with more cells and change feed consumers would pay more (inference).

**Why the dead-node guarantee holds.** The `@jobs` row always sits at a time not
later than the earliest of every pending `due_at_ms`, running `claimed_until_ms`
and cron `next_at_ms`, and the entry for that time exists. A finish keeps the row
only when `current_at <= next`, so the row can be earlier than needed, never
later. A scan that reaches the entry moves the row to its lease first, so a row
still at `current_at` has an unclaimed entry. An early wake runs `Jobs.run/3`,
which re-arms from that row to the real next wake, so a claim of a node that died
is woken at `claim_ms` at the latest. Tests: `test/atanor/jobs_test.exs` (no
entries left after jobs) and the cluster tests of
`test/cluster/jobs_release_test.exs` and `test/cluster/jobs_test.exs` (a dead
owner's job runs again, once). A cell with claimed jobs and no other traffic is
therefore recovered at the end of `claim_ms`, not at the detection of the
failure (§15).

**Claim and finish.** A scan claims up to `jobs.batch_size` (20) jobs in one
transaction, bounded by the room under `cell_concurrency`, and a finish claims
the next job in its own transaction. What is left is one finish transaction per
job, one segment upload per transaction; transactions that queue together share
an upload (0.32 uploads per job at concurrency 4, 0.10 to 0.12 at 16). A
coalesced finish would save at best about 0.07 of 0.75 requests, and at
concurrency 1 it cannot batch anything, so it is not built. Exactly-one
completion and the fence rest on the finish being conditional on `state =
'running' AND claimed_until_ms = <lease>` and the claim on `WHERE state =
'pending' ... OR (state = 'running' AND claimed_until_ms <= now)`. The property
`batched claim` of `test/atanor/jobs_claim_test.exs` checks several scans at once
over due jobs, expired claims and jobs held by another node, with random
`cell_concurrency` and `batch_size`: each job that may run runs once, a held one
never, and no more than `cell_concurrency` at once.

**Feed grouping.** Requests per job (the drain, writing handler) for
`object_batches` / `linger_ms` pairs, 100 jobs, store latency / `cell_concurrency`:

| Case | `1/0` | `4/10` | `16/50` | `16/250` | `16/1000` (undercounted) |
| --- | --- | --- | --- | --- | --- |
| 25 ms / 1 | 6.21 | 6.19 | 5.27 | **4.50** | 4.27 |
| 25 ms / 4 | 1.93 | 1.70 | 1.45 | **1.17** | 1.14 |
| 100 ms / 1 | 8.20 | 8.26 | 8.09 | **6.88** | 6.27 |
| 100 ms / 4 | 2.51 | 2.54 | 2.36 | **2.00** | 1.78 |

Grouping only pays when the linger reaches across commits: at 25 ms the commits of
a job are about 100 ms apart, at 100 ms about 200 to 400 ms, so `4/10` and
`16/50` gather nothing at 100 ms and `16/250` gathers about two. `16/250` removes
about half of the requests at 25/1 and 39 percent at 100/1. A longer linger gains
little more and delays the feed by a second, so 16 and 250 ms is the measured
choice and Atanor's default (§4.3). The cost is in §12.14. The `16/1000` column is
a floor: the last groups are put after the bench's sampling window. The stop flush
adds at most one put when a cell stops with batches queued.

What remains is in Alambique: segment reads and heads (compaction) are 0.36 to
0.65 requests per job on the job path, and change feed objects are 2.00 per job
with the test handler at concurrency 1.

Limits: single runs on a shared host; one cell, one node, one worker; a handler of
two writes (a heavier handler adds its own transactions); no network jitter; the
traced run is slower than the untraced one and its rates are not reported.

### 12.14 Per-request and per-job costs

Micro-benchmarks of the hot paths, run with the commands in the table. The
figures were taken when each path was last changed and have not all been
measured again on the current code; re-measure with the command before relying
on one. They are
wall time per call, summed over all the processes of a run, so 12 processes that
do not contend show a twelfth of the single-process figure. The host was shared,
so only the ratios mean anything.

| Path | Command | Metric | Result |
| --- | --- | --- | --- |
| `Registry.config/1` (read from `:persistent_term`) | `bench:micro config` | ns per call, 1 process / 12 processes | 127 / 24 |
| `Wasm.settings/0` (built once, `:persistent_term`) | `bench:micro wasm` | ns per call | 43 to 50 |
| Byte loops for the namespace and the bearer token | `bench:micro regex` | `Cell.validate_namespace/1`, `Cell.id/1`, ns | 187, 808 |
| Feed tailer reads the next page at once while the feed moves | `bench:feed` (2,000 changes, defaults) | first to last change | 1.06 s |
| Sweep manager keeps finished operation records | `bench:idle-polls` (300 finished operations, `poll_ms` 500) | store GET/s of an idle node | 0 in 10 s |
| Done index for the purge of finished jobs | `bench:micro purge` (100,000 finished jobs) | purge statement per claim | 55 us |
| Lease read ahead of the owner check, outside the cell | `bench:hot-cell-tail` (8 clients, 25 ms store) | req/s, p99, max | 295, 28 ms, 71 ms |
| Wasmtime pooling allocator | `bench:wasm` (epoch) | warm instantiation, whole request in the NIF, `hello` over HTTP | 0.018 ms, 0.065 ms, 21,895 req/s |
| | `bench:http` | WASM, no cell / cell write | 27,779 / 5,283 req/s |
| Verifying a bearer token | `bench:auth` | RS256 / ES256 per verify | 53 / 58 us |
| `Registry.match/3` | `bench:micro` | a hit / a miss | 5.6 / 3.1 us |
| `Alarms.owner/2` with 3 members | `bench:micro` | per entry | 1.2 to 1.3 us |
| `Jobs.full?/3` (storage bounds) | `bench:micro jobs` | one statement at 5,000 pending jobs; an enqueue at depth 0 / 5,000 | 251 us; 179 / 411 us |

* The native cell write (about 8,000 req/s on a loaded machine) and the job path
  are bound by the commit, not by these costs.
* The pooled allocator costs address space and some resident memory (§14.9). The
  CPU-bound request is not slower with the pool (about 200 ms either way).
* The feed figure excludes the 14 s that Alambique takes to settle a feed object;
  the first change arrives at about 15 s, and the table gives the time from the
  first to the last. `bench:feed` with `poll_ms` 50 gives the same 14 s after the
  writes, which shows that the page and not the interval was the limit.
* *Cost of `linger_ms`.* `mise run bench:feed -- 2000 100 B L` (in-memory store,
  `poll_ms` 100) sets `object_batches` B and `linger_ms` L, and after the burst
  writes 20 lone changes 300 ms apart and reports the delay from each write to
  its delivery. Atanor requires `window_ms` of at least ten times `linger_ms`, so
  the `16/250` case uses `window_ms` 2,500.

  | B / L | burst: first change | burst: last change | lone change, median / p90 / max |
  | --- | --- | --- | --- |
  | 1 / 0 | 14,123 ms | 15,797 ms | 14,045 / 14,050 / 14,050 ms |
  | 4 / 10 | 14,100 ms | 15,977 ms | 14,050 / 14,056 / 14,056 ms |
  | 16 / 50 | 14,126 ms | 15,984 ms | 14,146 / 14,152 / 14,155 ms |
  | 16 / 250 | 14,326 ms | 16,050 ms | 14,261 / 14,267 / 14,268 ms |

  A lone change is delivered `linger_ms` later (+1, +101 and +216 ms over `1/0`,
  +1.8% of the 14 s at 250), and a busy cell is not delayed: the group fills
  before the linger ends (inference; the last change of the burst stays at 15.8 to
  16.1 s).
* `bench:idle-polls` counts the reads of `sweeps.poll_ms` 500. Finished records are
  read again after `sweeps.reread_ms`, so the idle cost is about 300 / (`reread_ms` / `poll_ms`) GETs per poll, 0.25 with the
  default 600,000 ms.
* The tests for the feed backlog, the finished sweep record and the done index
  guard these paths.

Measured and left alone:

| Path | Measurement | Why |
| --- | --- | --- |
| `diagnostics.breadcrumbs: :durable` (the default) | costs a few percent of job throughput (§12.10) | Reusing marker files needs care in `Diagnostics.track` and the reporter that reads the directory; the crash evidence is the point of the feature. |
| `Jobs.full?/3` | 251 us at 5,000 pending jobs, as in the table | Both limits are exact and need the rows; a counter row kept by triggers, or a covering index with the size, changes the schema of every cell. One statement per enqueue and per cron fire. |
| JWT verification | 53 to 58 us per verify | A cache of verified tokens is a security decision; at 5,000 requests/s it would be 0.27 of a core. |
| The `:atanor_started` message of a forwarded call | not measured; `bench:cluster` differences are inside the noise | `remote/9` is called by name over distribution: so the argument and the message stay until the protocol changes on purpose. |
| Deployments watcher: one head per worker every `poll_interval_ms` | not measured | Needs a listing with etags in Alambique, or the heads read in parallel. |
| Channels fan-out, `Slots`, body copies in the NIF, the pending-call mutex | not measured | Need a three-node bench with thousands of sockets, or only matter at rates above these. |

Reproduce with `mise run bench:micro`, `bench:feed`, `bench:idle-polls`,
`bench:hot-cell-tail`, `bench:auth`, `bench:wasm`, `bench:http` and `bench:jobs`
(`ATANOR_BENCH_BREADCRUMBS=durable` and `ATANOR_BENCH_POOLING=off` select the
other side of the comparisons).

## 13. Prior art

[prior-art.md](prior-art.md) compares workerd, celld, Spin and wasmCloud and
lists the format choices (its section 6).

## 14. WASM engine

A spike of `wasmex` 0.15 (prior-art.md section 7) found that it cannot serve
`wasi:http/incoming-handler`, has no fuel for components, cannot serialize
compiled components, and starves its own timers when as many guests run as
it has threads. Atanor therefore runs Wasmtime through an own
NIF, following Alambique's native pattern:

* Rustler crate `native/atanor_wasm` over `wasmtime`, `wasmtime-wasi` and
  `wasmtime-wasi-http` 50;
* long calls run off the BEAM schedulers, on a pool the crate owns, with its
  own epoch ticker;
* native allocations are counted and the counters are emitted as telemetry;
* CPU is limited by fuel or epoch, whichever measures cheaper (§12);
* compiled components are serialized and cached on disk by package id;
* outbound HTTP goes through the host's `send_request` hook, which applies
  the `http.allow` grant.

The decisions below were taken in stage 4.

### 14.1 Own pool, not dirty schedulers

`prepare/2` is a dirty-CPU NIF: it is short and bounded. A compile is not
(§14.5), so `compile/5` runs on a pool of its own.
Guests are not: one holds a thread until its deadline (30 s by default). The
BEAM has as many dirty CPU schedulers as cores, shared with every other
dirty NIF (alambique's SQLite), so a burst of runaway guests would take them
all. The crate therefore owns `max_calls` OS threads (default: 4 per logical
processor) fed from a bounded queue, and `invoke/5` only enqueues. A guest
call is `block_on` of a current-thread Tokio runtime on its pool thread,
because `wasmtime-wasi-http` is async. The epoch ticker is a separate
thread that sleeps `tick_ms` (10) and increments the epoch, so no guest can
delay it. With 16 runaway guests on 4 threads the scheduler lag stayed under
3 ms (§12.1).

### 14.2 Admission

Three bounds, all in Rust (`admission.rs`); Elixir does not count requests.

* **Running.** At most `threads` guests (default: logical processors, at most the CPU quota of the container from cgroup `cpu.max`, rounded up) run at
  once. A call polls its guest only while it holds one of `threads` permits and
  gives the permit back whenever the guest is pending: a sleep, `poll`, a host
  call, an outbound response or a worker it called. A waiting guest holds no
  CPU, and while there is room among the `max_waiting` waiting guests it holds
  no call slot and no pool thread either (see *In flight*). Permits are served in order, and the
  wait for the first one counts in `queue_wait_ms`. The CPU limit counts only
  the time the guest ran, as before: a call has a thread of its own.
* **In flight.** The queue holds `queue` calls (default 4 per thread) for the
  pool threads; a full queue refuses the call at once. A queued
  call that waited more than `queue_wait_ms` is dropped when it gets the right
  to run. At most `max_calls` calls are busy at once (default 4 per thread):
  a pool thread takes a queued call only below that number. One worker's
  prepared component has at most `worker_calls` busy calls, queued included
  (default three quarters of `max_calls`); one more is refused at once. So a
  busy worker cannot take every thread, and another worker is served. Both are
  `{:error, :overloaded}`, 503.
* **Waiting.** A call whose guest waits is not busy: it gives its call slot
  back, and the pool thread it holds stops counting against `max_calls`, so
  guests that wait do not cause `:overloaded` for new calls. At most
  `max_waiting` guests do this at once (default 2 per thread). The pool has
  `max_waiting` threads more than `max_calls` for them, and a store each
  (§14.9). A guest that waits above that number keeps its slot and thread until
  it runs again, as before. A guest that wakes is never refused: it takes its
  slot back, above `worker_calls` if need be, and runs when it gets the right
  to run. So busy calls can pass `max_calls` by at most `max_waiting` while
  woken guests run, and the threads and stores in use never pass
  `max_calls + max_waiting + max_nested_calls`.
* **Nested.** A call a guest makes to another worker (`Env.depth > 0`) skips
  the queue and the per-worker bound: its caller is waiting for it, so it
  could wait behind its caller forever. It gets a thread of its own, up to
  `max_nested_calls` in flight (default 1 per thread); one more is refused
  with `:overloaded`. A pool full of waiting callers cannot starve their
  callees, and a callee waits only for the right to run, like any call.

`Gate` is the counting rule of the second, third and fourth bounds. Its property
tests check over random sequences that the slots held never exceed the limit,
that an entry is refused only at the limit and that a release always makes room
(`a_gate_admits_exactly_up_to_its_limit`), and that waiting, waking and ending
a call, in any order, move the slot, the waiting count and the busy count
together and return all of them at the end (`slots_follow_the_calls_that_wait`).
`test/atanor/wasm_wait_test.exs` checks the effect with guests that sleep and
that call each other.

**Cost and limits (measured).** Fuel mode, `hello` over HTTP, 32 clients, 12
threads, runs alternated in ABBA order with the load below 3 and no other test
VM (`mise run bench:wasm`): master 25,940 requests/s (median of 3) against
about 24,100 to 24,400 with this admission, about 5% less. One of three
branch runs gave 12,888 and is left out as host noise. The cause is not
proven. The thread count was one cause, and the queue of `engine.rs` now
wakes one idle thread per job (12% before, 5% after). Pools of 24 threads
(arms with `max_calls = 2 x threads`) did not close the rest. The suspect is
the pooling allocator's 60 instance slots against 12 (§14.9).

The refusal moved. Master queued up to 60 calls of one worker (12 running and
48 waiting); one worker is now refused with 503 `overloaded` above
`worker_calls` (36 at the defaults), so a burst of 64 clients against one
worker got about 0.1% 503s per 5 s run (87 to 117 of about 120,000) against
about 0.01% on master (4 to 13). The p99 of the accepted requests was the
same, 4.1 to 4.7 ms. This is backpressure on purpose, not loss: the response
carries `Retry-After` and a worker whose guests wait cannot take every thread.
A node that serves bursts of one worker raises `worker_calls` and `max_calls`
(each adds address space, §14.9). Lower values refuse more and were not
faster: with `max_calls` and `worker_calls` at 24, the same burst got about
0.5% 503s.

### 14.3 Allocator

The library's global allocator counts bytes on the system allocator, per
thread, as alambique does for its own. Unlike alambique it does not use
`enif_alloc`: pool threads are not BEAM threads, glibc's per-thread arenas
avoid ERTS's allocator lock under many guests, and a guest's memories are
mapped by Wasmtime, not allocated. So `alloc_bytes` and `free_bytes` are the
Rust heap; the guests' memory is `memory_bytes` in each `invoke` event.
`Atanor.Wasm.Stats.emit/0` emits all counters (poll it like
`Alambique.NativeStats`).

### 14.4 CPU: epoch by default

Both are implemented; the engine is built in one mode per VM (`:cpu` in the
`:atanor, :wasm` environment) because fuel is an engine setting.

* **Epoch.** Every store gets a deadline of one tick; the callback runs at
  each tick the guest executes. It stops the guest when the wall deadline has
  passed (`:timeout`) or when the CPU time of the pool thread
  (`CLOCK_THREAD_CPUTIME_ID`, so waits are not counted) since the call began
  has reached `cpu_ms` (`:cpu`). Resolution is `tick_ms`.
* **Fuel.** The store gets `fuel` units (manifest `limits.fuel` or the node
  setting) and traps with `OutOfFuel` (`:cpu`). Deterministic, but every
  instruction pays.

Epoch is the default because fuel costs 20 percent on a CPU-bound guest and
epoch interruption is needed for the wall clock anyway (§12.1). Wall-clock
also has a Tokio `timeout_at` around the whole call, because a guest blocked
in a host call or in `poll` runs no Wasm code for the epoch to interrupt.

Per request, the CPU limit in epoch mode is `min(limits.cpu_ms, node cpu_ms)`;
a manifest without `cpu_ms` gets the node value. In fuel mode `limits.fuel`
applies and `cpu_ms` is ignored. Both are passed to the NIF with each call,
not fixed in the engine.

### 14.5 Compiled code cache

The cache key is the package id. `Atanor.Wasm.Cache` (one per instance) keeps
the compiled components of its instance in ETS and compiles a missing one
once, however many callers wait. On a miss the crate looks for
`<data_dir>/wasm/<id>-<engine>.cwasm`, where `<engine>` fingerprints
Wasmtime's compatibility hash (version and settings, so epoch and fuel
engines have separate files). The file is the SHA-256 of the payload followed
by the output of `Component::serialize`. Wasmtime checks the payload against
the engine; the digest rejects truncation and bit rot, because deserializing
damaged code is unsafe. Any failure to read the file recompiles and rewrites
it (atomic rename). The `[:atanor, :wasm, :load]` event reports the source:
`:memory`, `:disk`, `:compiled` or `:recompiled`. Entries are not evicted
while the instance runs. A deployment waits for a compile at most
`compile_timeout_ms` (`:atanor, :wasm`, default 60,000) and the watcher goes on
with the other heads; the compile cannot be interrupted, so it ends on the
compile pool and the next apply finds it cached. That pool is
`compile_threads` OS threads (default 2) with a queue of `compile_queue`
(default 16): `compile/5` queues the work and returns at once, the result
arrives as a message, and a full queue answers `:overloaded` (the deployment
fails with "compile queue is full"). An abandoned compile therefore holds no
dirty scheduler, and repeated deployments cannot pile up more than
`compile_threads + compile_queue` compiles. A queued compile is not
cancelled when its caller gives up. The component size is bounded
before the compile (§5.1).

#### Limits

**The compiled-code cache is checked, not authenticated.**
`<data_dir>/wasm/*.cwasm` files carry a SHA-256 of their content, which detects
damage but not tampering. Whoever can write that directory can have the node
load native code of their choosing. The data directory is trusted: it also holds the cells.
Authenticating the files would need a per-node key kept outside the data
directory, which Atanor does not manage. Workaround: keep the data directory
writable only by the node's user, and restart nodes that deploy many distinct
packages, because compiled components are not evicted while the instance runs.

### 14.6 Linking and WASI

Every component gets the full WASI preview 2 interfaces with an empty
context: no preopened directories, environment, arguments, stdin or stdout;
stderr is captured up to `stderr_bytes` (4 KiB by default) and logged as a warning; sockets and IP name
lookup are denied by default. The `atanor:*` interfaces and
`wasi:http/outgoing-handler` are linked only when granted. Guests built with
any `wasi 0.2.x` bindings link against the host's 0.2.12. The imports are
checked before linking so the error names the import.

### 14.7 Host calls and outbound HTTP

A guest's call to a granted import sends `{:atanor_wasm, tag, :host, id, op,
args}` to the process that called `Atanor.Wasm.invoke/3`, which answers with
`Atanor.Wasm.Host` using the request's env (so D1 holds and the answer runs
the same `Atanor.Env` function a native worker would call), and the guest
waits for the reply up to the request deadline, without holding the right to run (§14.2). Outbound HTTP is the
same: the `send_request` hook buffers the request body (capped), asks for
`Atanor.Env.fetch/3` with the time the call has left, and returns the buffered response as a `wasi:http`
response. The allowlist, address resolution, private-address refusal and
redirects are therefore the single implementation in `Atanor.Env` and
`Atanor.Egress`. Not streamed in either direction: a request body and a
response body are buffered in full, within `max_body_bytes` and
`max_response_bytes`.

`Native.host_reply/2` has two entry points that share one decode. Copying a
64 MiB reply (the cells' `max_result_bytes` allows it) into Rust held a normal
scheduler for 7 to 14 ms, so a reply of `host_reply_dirty_bytes` or more
(`:atanor, :wasm`, default 262,144) goes to a `DirtyCpu` NIF and a smaller one
to a normal NIF, which avoids the hop to the dirty schedulers (about 1 us) for
the frequent small replies. The size is `byte_size` for a binary and
`:erlang.external_size/1` for any other term. The default is where the copy
on a normal scheduler (about 3 us for 256 KiB, 116 us for 1 MiB) starts to cost
more than the hop. Large replies do not wait behind compiles, which no longer run on
the dirty schedulers (§14.5); `prepare` is the only other dirty NIF.

The cell host calls are the `Atanor.Env` functions with the same names. The
cell interface also has `partition`, which runs `Env.partition/3` and returns the
physical address of a partition key (§4.2); the guest then uses that address with
`query`, `execute`, `batch`, jobs, alarms and sockets.

A WASM worker calling a WASM worker holds a call slot while it waits, and its
callee runs on a nested-call thread (§14.2), so a pool full of callers does not
starve their callees. Callers and callees do not run at the same time unless
`threads` permits are free.

### 14.8 Alarms, sockets and what is left out

Decisions of the stage that gave WASM workers alarms and WebSockets:

* **One call path.** `Native.invoke/5` takes a tagged call (`:http`,
  `:alarm`, `:ws_open`, `:ws_message`, `:ws_close`); `native/atanor_wasm`
  runs it with the same store, limits, epoch callback and host-call link as
  an HTTP request. `Atanor.Wasm.run/3` waits for the result and answers host
  calls, so `attach` in a socket call sees the socket pid in the env.
* **Handlers are looked up once.** `prepare` finds the exports by
  introspecting the component type (`atanor:worker/alarm-handler@0.1.0`,
  `atanor:worker/socket-handler@0.1.0`) and pre-instantiates a typed handle
  for each present one; a manifest that grants `alarms` or `sockets` without
  the export is refused (`{:missing_export, name}`). A component may export a
  handler without the grant: it then cannot set alarms, but a socket handler
  still serves WebSockets, like a native `handle_ws/3` without `sockets: true`.
* **The HTTP handler stays required.** A WASM worker exports
  `wasi:http/incoming-handler` even if it only serves alarms; an alarm-only
  worker without it is refused at activation.
* **Results.** The wire results are `nil` (alarm, close), `accept` or
  `{reject, {status, headers, body}}` (open) and `{frames, close?}` (message).
  A rejected response is validated like a native one (`Response.valid?/1`).
* **Telemetry.** `[:atanor, :wasm, :invoke]` and `[:atanor, :wasm, :limit]`
  carry `call`: `:http`, `:alarm`, `:ws_open`, `:ws_message`, `:ws_local` or
  `:ws_close`.
* **The local socket handler.** `atanor:worker/socket-local` is a separate
  optional export (an interface cannot have optional functions, and adding one
  to `socket-handler` would break existing guests). `prepare` returns whether
  the component has it; the call is `{:ws_local, socket, :text | :binary, data}`
  and its result `pass` or `drop` (§7.6).
* **Not supported: TCP.** A raw-socket worker needs a stream between the
  listener and a long-lived guest, which the per-call model of this engine does
  not have (see the limits below).
* **Test guests.** `scripts/build-wasm-fixtures` assembles
  `test/fixtures/guests/wit/deps` (not committed) from `wit/` and from the
  WASI 0.2.12 packages in the `wasmtime-wasi-http` crate source, then builds
  one component per feature, including `alarm`, `socket` and `job`.

#### Limits

**WASM workers do not serve TCP, TLS or STARTTLS.** WASM workers have no
`handle_tcp/3` and no `ranch_protocol/1`. A `tcp` route in a WASM manifest is
refused with `{:unsupported_for_wasm, :tcp}`. Implicit TLS and STARTTLS are
properties of a TCP listener the worker serves, so a guest cannot use them
either: the host never intercepts a guest socket to upgrade it. Workaround: keep
the TCP/TLS edge in a native worker and call the WASM worker from it with
`Atanor.Env.call/3` (for example for parsing or a cell write), or terminate TLS
in a proxy in front of an HTTP route. Evidence: §3.2, §7.3 and
`test/atanor/tcp_test.exs` ("WASM manifests cannot claim listeners yet").

### 14.9 Pooled instance slots

Wasmtime's on-demand allocator maps and unmaps the linear memory, tables and
stack of every call. Warm instantiation was 53 percent of a request in the NIF
(§12.1). The pooling allocator keeps pre-mapped slots and reuses them; it is the
default, and `pooling: false` (`:atanor, :wasm` setting, `Atanor.Wasm`) maps on demand
as before. The pool is sized from the other settings, so no new size has to be
chosen:

* A call holds its store from start to end, waiting or not, so there are
  `max_calls + max_waiting + max_nested_calls` component instances and stacks, and per thread the most one store may hold: 8 core
  instances, 8 memories and 16 tables (`Limiter` refuses more, in both modes).
* A memory slot holds up to `max_memory_bytes` (at most 4 GiB, the size of a
  wasm32 memory) and a table slot `table_elements`. The CPU, wall-clock and
  memory limits are enforced as before: `Limiter` counts every memory of a call
  against `memory_bytes`, and the slot size is the node ceiling.
* The cost is address space, not memory: each memory slot reserves the guard
  region of the bounds-check scheme. On the 12-thread laptop the VM went from
  2.4 GiB to 390 GiB of address space and from 207 to 284 MiB resident after a
  run (`bench:wasm`). Each memory slot reserves 4 GiB of address space (the wasm32 range plus guard region), and
  a pool has `(max_calls + max_waiting + max_nested_calls) * 8` of them, so the reservation scales with those
  settings. To lower it, lower `max_calls`, `max_waiting` and `max_nested_calls`, or set `pooling: false`. When the
  host refuses the reservation the node does not start: the error ends with "the pooling allocator
  reserves address space for N calls: lower max_calls, max_waiting and max_nested_calls, or set pooling: false".
  With `max_calls` and `max_nested_calls` at their defaults (4 and 1 per thread, before `max_waiting` existed) the same laptop
  reserved 1.98 TiB (5 times as many slots), and 324 MiB resident after the run. With `max_waiting` at its default
  (2 per thread) there are 7 slots per thread, so about 2.8 TiB (scaled, not measured). Pages are returned to the kernel when a call ends. A host
  with a limit on address space (`ulimit -v`, `vm.overcommit_memory=2`) must set
  `pooling: false` or fewer `threads` and `max_calls`.
* A component that needs more than a slot (more than 8 memories, a table larger
  than `table_elements`, a declared memory larger than `max_memory_bytes`)
  fails to instantiate with an error, as it did in the limiter; it does not
  weaken a cap.

## 15. Jobs per cell and bulk operations

Jobs replace Oban for applications on Atanor (design milestone 3615). A job is
a row in the cell's SQLite, written in the same transaction as the worker's
data. The earliest due job is the cell's wake-up alarm, so a sleeping cell is
woken only when work is due. A **bulk operation** (a sweep) enqueues one job in
each cell of a selector, throttled, resumable and idempotent per cell.

### 15.1 Atanor's per-cell schema

Alambique's migrations are one contiguous `1..n` list per namespace applied to
`PRAGMA user_version`, and the worker's manifest list *is* that list (§4.1).
Inserting an Atanor migration at the front renumbers the worker's migrations
and breaks cells already at version `n`; appending it collides when the worker
later adds a migration. Atanor therefore treats **the presence of the two base
tables, `_atanor_alarms` and `_atanor_jobs`, as schema version 1**. There is no
schema-version row in a job table and no bookkeeping row to filter, purge or
mistake for a job. `Atanor.Jobs.Schema.ensure!/2` runs inside the same cell
transaction as an enqueue or claim: it looks for the base tables and the lazy
features in `sqlite_master`, creates what is missing, and does not need a
version check today. A future schema version can add `_atanor_meta` (or use
`PRAGMA application_id` if that is verified through replication) when it
introduces a change; version 1 needs neither.

The implementation uses only the public `Alambique.Tx` API. Whatever is
missing is created by one `Alambique.Tx.script/2`, so a new cell pays one
change-capture cycle, not one per statement: the two base tables
(`_atanor_alarms` and `_atanor_jobs`) and, when the same transaction asks for
them, the lazy features. The unique key is an inline constraint, the due index
and the done index (`state, completed_at_ms`, which the purge of finished jobs
uses) are created on the first job wake, the cron table and its two indexes on the
first cron schedule, and `_atanor_undo` on the first undoable operation.
Feature presence is read from `sqlite_master`; there is no marker row. The
operation marker is the job row's `operation_id`, so there is no separate
operations table. Atanor starts Alambique with
`feed: [internal_prefixes: ["_atanor_"]]` (`Atanor.Config`), so these tables
get no capture triggers and never enter the change feed (§16.5). Worker migrations, `user_version`,
`migration_window` and `migrations_lowered` are unchanged. `_atanor_` names
are reserved for Atanor.

Schema version 1 creates `_atanor_jobs` and `_atanor_alarms` eagerly;
`_atanor_cron` and the two job indexes are lazy. A job row has a stable text `id`
(32 hex), `worker`, `kind`, `payload BLOB`, `state` (`pending`, `running`,
`done`, `dead`, `cancelled`), `due_at_ms`, `inserted_at_ms`,
`claimed_until_ms`, `claimed_by`, `attempts`, `max_attempts`, `unique_key`,
`unique_period`, `unique_until_ms`, `idempotency_key`, `operation_id`,
`last_error` and `completed_at_ms`. The unique key is an inline
`UNIQUE(worker, unique_key)` constraint; the due and done indexes are created lazily on
the first wake. `_atanor_cron` is a schedule (expression, next time, template). `_atanor_undo`
is lazy as well and belongs to undoable operations (§15.9).
The operation marker and outcome are the job row's `operation_id` and `state`.

### 15.2 Enqueue and unique keys

Native workers call `Atanor.Jobs.enqueue(tx, env, cell, job)` inside
`Env.transaction/4`; the job and the data commit or roll back together.
`Env.enqueue/3` is the one-transaction convenience. WASM workers import
`atanor:cell/jobs@0.1.0` (`enqueue`, `enqueue-batch`) and export
`atanor:worker/job-handler@0.1.0` (`handle-job`); the manifest grants
`"jobs": true` plus the namespace under `cells`. A missing grant is
`{:error, {:not_granted, :jobs}}`. `enqueue-batch` writes the statements and
the job in one transaction.

`kind` names the worker's handler, `payload` is a binary, `scheduled_at_ms` is
in the alarm clock, and `max_attempts` defaults to `jobs.max_attempts`. The
job id is generated before the transaction and is the default idempotency key;
retries and takeovers reuse it. For effects outside the cell (§8.13) the
handler sends that key to the receiver. A bulk job also carries `operation_id`.

A unique key is scoped to `(cell, worker, unique_key)`; `kind` is not part of
the scope. `:until_done` (default) conflicts while the row is pending, running
or dead; `{:seconds, n}` conflicts for `n` seconds; `:forever` never expires
(a small tombstone remains). A conflict inserts nothing and returns
`{:ok, {:duplicate, id}}`; it is not an error, so the surrounding transaction
still commits. A unique index is the final guard.

*Storage bounds* (operator `jobs:`, per cell). An enqueue is refused with
`{:error, :queue_full}` when the cell holds `max_pending` (10,000) pending and
running jobs, or when their payloads, with the new one, pass `max_cell_bytes`
(64 MiB). A `:forever` job is refused with `{:error, :too_many_tombstones}` when the
cell already holds `max_tombstones` (10,000) of them, since nothing purges
them. `cron` is refused with `{:error, :too_many_crons}` at `max_cron` (100)
schedules. A cron fire into a full queue inserts nothing and the schedule moves
on. A job that finished drops its payload (`done`), and so does a discarded
one; a dead job keeps it for a retry.

### 15.3 The wake-up alarm

Jobs reuse `_atanor_alarms` through a reserved row named `@jobs`, a name no
manifest can use. The worker's own alarm row is untouched: this is
multiplexing by row in the same table and index, not sharing the worker's one
alarm. `@jobs.at_ms` is the minimum of a pending job's `due_at_ms`, a running
job's `claimed_until_ms` and a cron `next_at_ms`.

The store index entry
`alarms/<minute>/<shard>/<at_ms>/@jobs/<cell-id>/<nonce>` is written before the
row, as alarms do, with a random nonce that is also kept in the row's `payload`.
Whoever moves or deletes the row deletes exactly that entry (`Jobs.apply_rearm/3`
after the commit, `Alarms.claim/7` for the entry it scanned), so none is left
behind. A finish leaves the row where it is while its wake is not later than the
next one (§12.13). An enqueue inside a transaction writes the entry from inside that
transaction; a failed store write fails the enqueue, and a rollback leaves a
stale entry that `Alarms.expire/2` removes after `alarms.timeout_ms`. An enqueue
that moves a later wake earlier replaces the row's entry; when the enqueue owns
its transaction (`Jobs.enqueue_direct/4`, `Jobs.enqueue/3`, `Env.enqueue/3`) the old entry is
deleted after the commit, and when the caller owns it (`Jobs.enqueue/5` in a
worker's `Env.transaction`) there is no after-commit point to run the delete
(`Alambique.Tx` has no commit hook), so that entry expires after `alarms.timeout_ms`.
A finish and a scan that both move the row at once leave the entry of the loser;
the loser deletes it, since the winner's row names the winner's nonce. The
existing `alarms.clock` drives jobs, cron and alarms, so a `ManualClock` test
controls all three.

`Atanor.Alarms.fire/4` branches on `@jobs` before resolving a deployment; the
normal conditional claim still decides which scheduler fires. The handler
calls `Atanor.Jobs.run/3`, which claims due jobs, starts tasks and re-arms
`@jobs`. `Dispatch.internal/3` forwards the internal call to the cell owner
when the scheduler is elsewhere. `Alarms.pending/3` hides `@jobs`, and no
alarm event is emitted for it. A scheduler that lost the claim sees a
different `at_ms`; the conditional job claim makes a second runner harmless.

A job claim stores `claimed_until_ms` and `claimed_by` (the node's name). After
a takeover the new owner restores them. It re-runs the job when the claim
expires, or at once when the takeover released the claim (§15.11); the old
owner's completion write is fenced (§8.10) and fails, and the new owner retries
with the same job id and idempotency key. On a graceful stop the runner stops
claiming (`Atanor.Jobs.Slots.close/1`, so a job that finishes during the wait
starts no other), waits up to `stop.jobs_ms`, cancels the attempts still running (§8.11) and leaves them to the lease.

### 15.4 Execution, retries, cron and timeouts

The cell owner runs jobs. A runner claims up to `jobs.batch_size` due jobs in
one cell transaction and starts one supervised task per job. `claim_ms`
exceeds `timeout_ms`, so a live attempt is not re-claimed. The claim lasts
`claim_ms` from the moment its transaction writes it, and `[:atanor, :job, :started]`
reports when it expires (`claimed_until_ms`). Delivery is at
least once: a node that dies after side effects leaves the claim to expire.
Success sets `done`; a failure records `last_error` and retries at
`now + min(backoff_ms * 2^(attempts-1), max_backoff_ms)`, or marks `dead`
after `max_attempts`. A claim that is still live when its node dies expires at
`claim_ms`, or earlier when the takeover releases it (§15.11). `jobs.timeout_ms` bounds one attempt with a watchdog
task. Dead jobs can be retried or discarded from the admin API.

The write that ends an attempt can fail with an unknown outcome: the owner was lost or too slow while it ran
(§8.4). It is not repeated, because the runner cannot tell whether it applied. If it did, the job is
`pending` again (or `done`) and runs again after its backoff, while the claim is still unexpired and
with no `finished` event. The runner then emits `[:atanor, :job, :unconfirmed]`, which tells that
case from a start with no cause. A runner that stops after the write committed and before it reports
(a killed node) reports nothing: the `[:atanor, :forward]` event with `unknown_outcome` is then the only trace.

A cron row is a schedule, not an execution: when due, the runner inserts a
normal job in the same transaction (new id, deterministic key
`<cron id>:<fire ms>`) and advances `next_at_ms`. The five-field parser
supports `*`, lists, ranges and steps, the usual day-of-month OR day-of-week
rule and `@hourly`…`@yearly`; it uses `:calendar` and has no dependency. Times
are UTC (see the limits below). The search for the next fire jumps over the months, days and hours that
cannot match, so an expression that never fires (`0 0 31 2 *`) is refused in
microseconds. The native callback is `Atanor.Worker.handle_job/2`; the manifest must
export it when it grants `jobs: true`. `Dispatch` routes `{:job, job}` to the
cell owner, and a WASM job runs in a fresh instance under its limits.

#### Limits

**Cron has no time zones.** Recurring jobs use five-field cron expressions
evaluated in UTC. A schedule such as `0 3 * * *` runs at 03:00 UTC, not in the
operator's local time, and there is no daylight-saving handling. A time-zone
option would need a tz database, which is not a dependency. Workaround: write
the expression in UTC, or enqueue a one-off job with an explicit
`scheduled_at_ms`. Evidence: `test/atanor/jobs_test.exs`.

### 15.5 Concurrency

`Atanor.Jobs.Slots` holds per-node slots. `jobs.concurrency` is the node total,
`jobs.worker_concurrency` the per-worker total and `jobs.cell_concurrency` the
per-cell total (default 1). A job with no slot is **not claimed**: it stays
pending at its due time and the wake-up is re-armed to `now + jobs.wait_ms`, so
waiting costs no attempt. Limits are per node, so the cluster total is
`nodes * concurrency`. A slot belongs to a process: the scan that claims the
job, then the task that runs it. `Slots` monitors the holder and takes the slot
back when it exits, so a scan killed after its claim committed (the alarm scan
has a `alarms.timeout_ms` limit) does not keep the slot for good. The claim
stays and expires as usual.

**The next job of a cell, when one finishes.** A scan claims at most
`cell_concurrency` jobs of a cell, so a burst would drain at that many jobs per
`alarms.tick_ms`. With `jobs.claim_on_finish` (default true), the transaction
that writes a job's finish (done, failed with a retry, or dead) also claims the
cell's next due job, in the same commit, and the handler starts after it. The
finished job's slot passes to the new one, so no slot is requested again and the
node and worker limits hold. The next job is taken only if it is the first in
the usual order (`due_at_ms`, then id), it has the same worker as the finished
one and the cell has room under `cell_concurrency`; otherwise nothing is
claimed and the next scan or wake-up does it, as before. One finish claims at
most one job, which keeps a cell at its bound. A scan claims up to
`jobs.batch_size` (default 20) jobs of a cell in one transaction, bounded by the
room under `cell_concurrency`; a finish needs no transaction for its claim,
so claims cost no store request of their own at steady state (§12.13).

Two claims of one cell can overlap (an alarm scan and a finish), so the scan's
claim transaction counts the live claims again and takes at most the room that
is left under `cell_concurrency`: the bound is checked where cell transactions
are serialized, not in the candidate read. A node that is stopping claims
nothing (§15.3). `claim_on_finish: false` returns to one claim per scan.
Measurement and cost: §12.9.

### 15.6 Bulk operations (sweeps)

An operation record lives at `<prefix>/operations/<id>` in the metadata store:
state, selector, action, rate, concurrency, page size, cursor, driver,
`lease_id`, `lease_until_ms`, counters and `last_error`. It is not an
operation cell: it is small, every dashboard can read it without waking a
cell, and conditional writes make one writer. Per-cell outcomes do not fit
there; they live in each target cell.

`Atanor.Sweeps.Manager` polls the records every `sweeps.poll_ms`. A running
operation with no live driver is claimed with an `If-Match` write setting the
driver and lease; every checkpoint is conditional, so a lost race stops the
old driver. An expired lease after a node loss is claimed by a survivor, which
resumes from the saved cursor. At most `sweeps.max_active` operations are
driven per node; a stopping node releases its lease.

The manager keeps every finished record it has read, and reads it again only
after `sweeps.reread_ms` (600 000), plus up to half of that, spread per key. A
listing returns keys only and a `HEAD` costs as much as a `GET`, so this
bounds the reads of an idle node while a record rewritten in the store is
seen within that time.

Selectors are `{:namespace, ns}` and `{:prefix, p}` through
`Alambique.list_cells(instance, prefix:, after:, limit:)`, and
`{:index, cell, ns, sql}` through a read of an index cell whose query takes
`?` for the cursor and `?` for the limit and returns one target key per row
(for example the mailboxes of a domain). A sweep is not a snapshot:
`list_cells` follows the schema index, so cells created after the start may be
missed; rerun for full coverage.

The cursor is the last id of a fully processed page; a crash mid-page replays
it. Each target cell gets one transaction that checks whether a job with this
`operation_id` already exists and, only when it does not, inserts the job and
the `@jobs` alarm. A unique `operation_id` is the marker; a replay skips a
marked cell, so a cell records the operation it ran. The driver uses
`idempotent: true`; completion updates the job state to `done`/`dead`, which
is the per-cell outcome 3616 can count. `Atanor.Sweeps.sample_outcomes/3`
reads a sample of those rows.

A token bucket enforces `rate_per_s`, at most `concurrency` cell transactions
are in flight, and pages are sequential. Pause and cancel are conditional
record writes checked before each page and batch; pause saves the cursor,
releases the lease and stops, resume starts a new driver there, and cancel
stops dispatching while already-enqueued jobs stay. `{:run, job}` is the same
insert with `due_at_ms = now` and a best-effort wake; there is no separate
synchronous path.

### 15.7 Observability, options and measurements

Events: `[:atanor, :job, :enqueued | :started | :finished | :dead]`,
`[:atanor, :sweep, :started | :paused | :resumed | :continued | :awaiting_confirmation |
:canary_passed | :halted | :cancelled | :done | :failed | :page | :lease_lost | :undo_report |
:undo_apply | :undo_rewind]` and `[:atanor, :admin, :action]` (see
[telemetry.md](telemetry.md)). The dashboard has a Jobs page with operations,
slot counts, dead letters and one cell's jobs; the admin API lists jobs and
cells, retries or discards dead jobs, and creates/pauses/resumes/cancels
operations, and asks for or reads an operation's undo report and applies it (§15.10). The `[:atanor, :job, :finished]` duration excludes the queue and
the store.

`jobs`: `max_attempts` 20, `timeout_ms` 30 000, `claim_ms` 60 000,
`backoff_ms` 1 000, `max_backoff_ms` 300 000, `concurrency` 64,
`worker_concurrency` 8, `cell_concurrency` 1, `claim_on_finish` true (§15.5),
`release_claims` true (§15.11), `batch_size` 20, `wait_ms`
1 000, `max_payload_bytes` 1 000 000, `max_pending` 10 000,
`max_cell_bytes` 67 108 864, `max_cron` 100, `max_tombstones` 10 000, `retention_ms`
604 800 000, `dead_retention_ms` 2 592 000 000 (or `:infinity`), `purge_limit`
100. `sweeps`: `poll_ms` 5 000, `lease_ttl_ms` 30 000, `renew_ms` 10 000,
`cell_timeout_ms` 10 000, `page_size` 100, `rate_per_s` 50, `concurrency` 8,
`max_active` 4, `cell_attempts` 3, `control_attempts` 10 (tries of a
pause, resume, continue or cancel that loses the compare-and-swap to the
driver's own write), `retry_ms` 1 000, `retention_ms` 2 592 000 000, `reread_ms` 600 000 (§15.6), `max_records` 1 000 (operation
records; the manager reads them in one page, and a new operation over the
bound is refused, 429 on the admin API), the
canary and guard defaults of §15.8 and the undo settings of §15.9 and
§15.10 (`undo` false, `undo_concurrency` 2, `undo_timeout_ms` 120 000, `undo_max_cells` 1 000, `undo_stale_ms` 600 000). `stop` adds `jobs_ms` 15 000, `sweeps_ms` 5 000 and `tasks_ms` 5 000. Config
validation also checks `claim_ms > timeout_ms`, `renew_ms < lease_ttl_ms`,
`cell_timeout_ms < lease_ttl_ms`, `worker_concurrency <= concurrency` and
`cell_concurrency <= worker_concurrency`. Per-operation values may only lower
the instance's `rate_per_s`, `concurrency` and `page_size`.

Measurements are in §12.9: one cell's enqueue rate, many-cell enqueue rate,
end-to-end job rate and sweep cells/s, with the method and machine.

### 15.8 Canary and error-rate guard

An operation starts with a **canary**: the first `canary_size` cells of the
selector (10; 0 disables it). If that is smaller than a page, the driver
dispatches only those cells and moves the cursor to the last of them, so the
rest of the page is listed again. When the canary is out, `canary_gate`
decides:

* `"auto"` (default) sets `canary.until_ms = now + canary_window_ms` (60 s) and
  keeps the lease. The driver wakes at least every `sweeps.renew_ms`, so the
  lease stays live. At `until_ms` it samples the canary cells. If the guard
  trips the operation is `halted`; if jobs are still pending it waits, and
  past `canary_timeout_ms` (300 s) after the canary it halts with
  `halt_reason: "canary_timeout"`. Otherwise `canary.passed` becomes true and
  the sweep continues from the cursor.
* `"pause"` saves the cursor in state `awaiting_confirmation`, releases the
  lease and stops. The manager starts only `running` operations, so nothing
  restarts it. `POST /operations/:id/continue` sets `running` and
  `canary.passed`; `cancel` also works, `pause` does not.

The canary is not evaluated when the selector ends inside it: the operation is
then `done`. The canary is sampled through the guard's `recent` ring, so a
`canary_size` above `guard_window_cells` is judged on its last
`guard_window_cells` cells.

The **guard** keeps `recent`, the last `guard_window_cells` (50) target cell
ids, appended per page and capped. Before a page, and at most every
`guard_poll_ms` (5 s), the driver samples them with
`Sweeps.sample_outcomes(instance, id, window, cells: recent, at: :latest)`.
That reads the `_atanor_jobs` row of the operation in each cell with
`Alambique.Query.all/5`, on a replica, without waking or leasing the cell. A
job row is a `done` success or a `dead` failure; pending jobs, and cells with
no row (a skipped duplicate, a row not yet visible), are not counted. When at
least `guard_min_cells` (10) outcomes exist (for the canary, at most the cells
dispatched) and `failed / (done + failed) > guard_error_rate` (0.1), the
operation becomes `halted` with `halt_reason: "error_rate"` and the sample in
`guard` (`samples`, `done`, `failed`, `rate`). Jobs already enqueued stay;
only dispatching stops. A sample in which any cell could not be read counts as
a failure: it is retried after `sweeps.retry_ms`, and after `guard_attempts`
(3) in a row the operation halts with `halt_reason: "guard_unavailable"`
rather than guess.

`resume` of a `halted` operation clears `recent` and the failure count and
sets `canary.passed`: the operator accepted the canary. A job that fails
slowly (retries with backoff) is still pending, so a canary of such jobs ends
in `canary_timeout`, not `error_rate`. The guard sees the outcomes of the
cells dispatched, not store or lease errors, which keep the existing
retry/`failed` path. The defaults are the `sweeps:` options `canary_size`,
`canary_gate`, `canary_window_ms`, `canary_timeout_ms`, `guard_window_cells`,
`guard_error_rate`, `guard_min_cells`, `guard_poll_ms` and `guard_attempts`;
an operation may set any of them at creation (`POST /operations` or
`Atanor.Sweeps.start/2`) to any valid value, and the record keeps the values
it started with. An operation record written before this section has no
`canary` or `guard` and runs unguarded.

### 15.9 Undo positions

An operation created with `undo: true` (the instance default is `sweeps:
undo`, false) records where each target cell stood before it applied. The
transaction that inserts the job runs with `isolated: true`, and the position
is `Alambique.Tx.before/1` inside it:

```elixir
Cell.transaction(instance, cell, fn tx ->
  Schema.ensure!(tx, [:undo])
  {:ok, job_id} = Jobs.enqueue(tx, instance, worker, cell, spec)
  Schema.record_undo!(tx, operation_id, job_id, Alarms.now(config))
  # before_txid = elem(Tx.before(tx), 1)
end, idempotent: true, isolated: true)
```

An isolated transaction owns its replicated batch: Alambique uploads the
commits that are waiting first, so `Tx.before/1` is the TXID of a state that
holds exactly what was committed before the transaction and nothing of it.
Rewinding to `before_txid` therefore drops the operation and every write after
it, and keeps every write before it, also one that was still waiting for its
upload. The cost is one more upload per positioned cell, paid only by an
undoable operation.

The position lives in `_atanor_undo (operation_id, job_id, before_txid,
before_at_ms)`, primary key `(operation_id, job_id)`. It is a lazy feature of
the private schema (§15.1): `Schema.ensure!(tx, [:undo])` creates it only for
an undoable operation, so a cell that never runs one pays nothing. The row and
the job commit or roll back together: a failed insert leaves neither the job
nor the table. A replay finds the operation marker (§15.6), enqueues nothing
and inserts no second row; the cell is counted as positioned when its row is
there. The record gets `"undo": {"enabled": true, "positions": n}`, with `n`
the positioned cells counted with the pages. A cell whose first batch is the
operation's records position 0, and `{:txid, 0}` restores an empty database
(a rewind refuses it with `bad_target`). Waking a cell commits its initial
batch, so a cell reached through Atanor records at least 1.

Like `_atanor_alarms` and `_atanor_jobs`, `_atanor_undo` is internal to the
change feed (§15.1): its row is not published. The record is small: one row
per operation per cell.

### 15.10 The undo report and the undo

An undo has two steps that share one JSON object, `<prefix>/undos/<operation-id>`
in the metadata store (not under `operations/`, so `Sweeps.list` never reads it
as an operation). `POST /operations/:id/undo` with `{"mode":"report"}` makes
the report; `{"mode":"apply"}` rewinds the cells of a finished report. Each
answers `202 {undo_id, state: "running"}` and runs as a task on the node that
received the request. A new report replaces a finished record; a `running` one
that was updated within `sweeps.undo_stale_ms` refuses it (409
`already_running`). A `running` record older than that reads as `stale`: its
node died, and no other node resumes it, but the next call of the same mode
continues from the record (below). The record is removed with its operation,
after `sweeps.retention_ms`, by the manager that removes the operation.

**The report.** The task walks the operation's selector again from its start
(`Sweeps.pages/2`; an index selector is read again). `undo_concurrency` cells
at a time, `Atanor.Sweeps.Undo.Cell`:

1. reads the cell's position, the job's state and Alambique's frozen flag
   through the live cell (a routed read, so it works from any node); a cell
   without `_atanor_undo` or without a row for the operation was created after
   it and is skipped. It also reads the cell's head TXID with
   `Alambique.position/3`, as `head_txid`, which the apply passes to
   `if_head`;
2. restores the cell at `{:txid, before_txid}` and at `:latest` into two files
   under `data_dir/undos/<operation-id>/` with the code the rehearsal uses
   (`Atanor.Restore`, over `Alambique.Ops.restore/5`), after finding the cell's
   location with `Alambique.list_cells/2` in each location of the placement;
3. opens both with `Alambique.Sqlite`, read-only, and compares them table by
   table: the row count and a hash of the rows, the
   sum of the SHA-256 of each row, so it does not depend on their order (each table
   is read in pages of 1 000 rows, by keyset on the rowid or on the primary key of
   a `WITHOUT ROWID` table, so memory stays bounded), plus a hash of the normalized `sqlite_master`
   definitions. Tables named `_atanor_*` are reported in `host_tables` and
   left out of the schema hash; `_alambique_*` and `sqlite_*` are skipped;
4. deletes both files, and the task deletes the directory when it ends,
   whether it succeeded, failed or was killed. Directories that a killed node
   left, older than `undo_stale_ms`, are removed when the next report starts.

A cell is `restorable: false`, with the stage and message, when it cannot be
read, located or restored (`target_not_reached` after the removal of history),
when the store holds it only up to before the position, or when it outlives
`undo_timeout_ms`, the budget of its restores and comparisons. The restore
deadline is passed to Alambique and SQLite is interrupted at it; a task still
running at twice the budget is killed. Either way the report completes and the
live cell was only read. The whole report is bounded by `undo_max_cells`
cells with a position. A failure to list the targets fails the report
(`state: "failed"`).

The comparison is between two points in the store, not between the operation
and nothing: the `:latest` copy contains every write after the operation, and
a copy of a cell that has not uploaded its last batches lags the live cell.
`current_txid` says which. The report is the review before the apply.

**The apply.** `Atanor.Sweeps.Undo.rewind/2` starts from the record and
refuses (409) when it should not run:

| Error | Why |
| --- | --- |
| `undo_not_enabled` | the operation has no positions |
| `operation_active` | the operation is not `done` or `cancelled`: its driver can still enqueue jobs into cells that were rewound |
| `report_required` | there is no report, or it is not `done` |
| `report_truncated` | the report stopped at `undo_max_cells`; raise it and make a new report, because a partial undo is not offered |
| `jobs_active` | some cell has a `pending` or `running` job of the operation: the kept job table would run it again after the rewind; wait, and make a new report |
| `already_running` | a record is `running` |

It copies the report's cells into a record with `mode: "apply"` and processes
them in groups of `undo_concurrency` (a rewind needs about five times the size
of the cell in memory). For each cell, `Atanor.Sweeps.Undo.Rewind`:

1. calls `Atanor.Cell.rewind/4`, which is `Alambique.rewind/4` with `{:txid,
   before_txid}`, `if_head: {head_txid, :data}` (the report's head), `keep:
   :internal`, `schema: :same` and `timeout: undo_timeout_ms`. The `:data` form
   refuses the rewind with `{:data_written, data_txid}` when data
   was committed after the report's head, and ignores wakes, which commit empty
   fences (alambique design §6). Alambique checks it before the lease and again
   under it, so a write cannot slip in between and no retry is needed.

**The choices.**

* **Mismatch.** A cell written since the report is not rewound. Its entry is
  `data_written`, with the `data` TXID of its last data commit and the
  `expected` head of the report, and the apply
  goes on with the other cells. A new report reads the cell again (it keeps the
  entries of the cells already rewound), and an apply from it rewinds the cell
  if the operator still wants that. Atanor never decides alone to drop later
  writes.
* **`keep: :internal`.** Alambique carries the tables named by `feed:
  [internal_prefixes: ["_atanor_"]]` (§16.5) from the current state into the
  rewound one, with their indexes and triggers. The job of the operation
  therefore stays `done`, the operation marker stays (a replay of the operation
  does not run it again), the position row stays, and the alarms and the other
  jobs of the cell are neither lost nor run twice. With `keep: :none` the job
  would be gone with its marker and the `@jobs` alarm would not exist. The
  report's `host_tables` shows these tables as different; that is expected.
* **`schema: :same`.** A target with another `user_version` than the cell has
  now (a deployment migrated the cell after the operation) is refused for that
  cell: `:migrate` is refused with carried tables, and Atanor needs them. The
  entry is `failed`, with `schema_differs`.
* **External effects.** Mail that was sent and calls that were made stay made.
  The rewind restores the cell, not the world.
* **Foreign keys and triggers** that tie the carried `_atanor_*` tables to
  worker tables are not reconciled by Alambique. Atanor's own tables have none.

**The ledger.** The record is the idempotency of the apply. It is stored before
each group, with the cells of the group `rewinding`, and after each cell. The
state of a cell's `apply` is:

| State | Meaning | A repeated apply |
| --- | --- | --- |
| `rewound` | rewound, with `txid`, `from`, `to`, `kept` | skips it |
| `data_written` | written since the report, left alone | tries it again |
| `failed` | Alambique refused it (`behind_retention`, `owned`, `schema_differs`, `too_large`, `mixed_cluster`, a store error): `error.stage` and `error.message` | tries it again |
| `unknown` | the rewind may have landed: `outcome_unknown`, a timeout, a killed task, or data written after a `rewinding` or `unknown` try (a rewind counts as data) | tries it, and ends `unknown` again if data was written |
| `rewinding` | the node died during the rewind | same as `unknown` |
| `skipped` | the report has no head for the cell | tries it again |

A rewind counts as a data commit for Alambique, so a cell that may have been
rewound already is tried like any other and answers `data_written` if the
rewind landed: the entry is then `unknown`, the cell is left alone and the
operator looks at it (`position/3`, the feed marker of §16.6). If the rewind
did not land, the cell is rewound now. This is what stops a second rewind from
dropping the writes made after the first. A failure inside the task ends the record with
`state: "failed"` and the ledger so far. `state: "done"` says the pass ended,
not that every cell was rewound: read `summary` (`rewound`, `data_written`,
`failed`, `unknown`, `rewinding`, `skipped`, `waiting`). Call the apply again
for the cells that are left.

**While a cell is rewound** Alambique fences it: its owner hibernates, and
calls for the cell answer `{:unavailable, "rewind", _}` until the new state is
in the store. Atanor sees an owner that is not a node and answers 503
`owner_unreachable`, which a client may retry. The rewind marker reaches the
change feed (§16.6). The rewind needs every node of the instance on
Alambique's protocol 3 (`mixed_cluster` otherwise), room in `data_dir` for two
copies of the cell and a cell no larger than Alambique's `rewind: [max_bytes:]`
(256 MiB by default; `too_large`); its costs are in Alambique's design §20.

Settings, all under `sweeps:`: `undo_concurrency` (2, cells at a time, for the
report and the apply), `undo_timeout_ms` (120 000, the budget of one cell),
`undo_max_cells` (1 000), and `undo_stale_ms` (600 000). Alambique's own `rewind: [fence_attempts:,
timeout_ms:, poll_ms:, max_bytes:]` is set under `alambique:`. The public
Alambique API used: `Tx.before/1`, `transaction/4` with `isolated: true`,
`position/3`, `rewind/4`, `Ops.restore/5`, `Replication.ctx/1`, `Sqlite`,
`list_cells/2`, `Feed.ctx/1` (clock, locations) and `frozen?/2`.

A cell that cannot be rewound (too large, migrated since) is repaired with an
inverse job, as before
([how-to-run-a-bulk-operation.md](how-to-run-a-bulk-operation.md)).

### 15.11 The claims of a node confirmed down

A job claimed by a node that dies would wait for `claim_ms`, which stays above
the job timeout, before it runs again, although the cell moves in seconds
(§8.10). With `jobs.release_claims` (default true), the takeover makes those
jobs claimable on the new owner as soon as the old lease has ended (§8.13; at once with the deferral off). The evidence is the one the takeover
uses: the detector confirmed the node down, and `Alambique.take_over/4` raised
the epoch of the cell, which fences the old owner. No timer decides.

**What happens.** `Atanor.Takeover` calls `Atanor.Jobs.release_claims/4` after a
takeover it made succeed, with the node it took the cell from and the epoch it
raised (the epoch it read plus one). It runs as a task, off the path of the
request that needed the cell. It runs one cell transaction on the owner:

1. It counts the jobs that are `running`, with a live claim, whose `claimed_by`
   is that node. None: it ends, with no further read.
2. It reads the lease (`Alambique.lease/3`) inside the transaction. It goes on
   only if the lease still names the epoch of the takeover and this node as the
   owner. If the cell changed hands again, or the epoch is another one, it
   leaves the claims (`:stale`): they expire as before.
3. It sets `claimed_until_ms` of those jobs to now, so they are due as an
   expired claim, re-arms the `@jobs` wake-up and, after the commit, asks the
   owner to run the claim (`Dispatch.internal/3`, no wait for the scan). The job
   keeps its id, idempotency key and attempt count (the claim counts the new
   attempt), and the event `[:atanor, :job, :released]` records how many.

**Who claims.** `claimed_by` is the node that runs the claim and awaits the
attempt (the runner), not the cell owner whose transaction records it. The
runner lives on the node whose alarm scan fired, which can be another node than
the owner; it forwards the handler to the owner. A release matters when the
runner is the node taken over, which is the usual case, since the shard of a
cell's alarm often falls on its owner. Claims of a runner that is alive are
never released: when the owner dies and the runner survives, the runner sees the
handler lost, or has it rerouted to the new owner, writes the result itself and
the job is retried after `backoff_ms` if it failed. Releasing such a claim
would start the job a second time next to the attempt that the runner rerouted.
When the runner dies and the owner lives, the cell is not taken over and nothing
is released: the claim expires.

**Why it is safe.**

* *Only a fenced node's claims.* The old owner is fenced at the new epoch: its
  next write to the cell is refused, so it cannot claim again or write a
  result. Every claim it holds is older than the epoch the release checks, and
  the check is made in the owner's transaction. A node that restarts with the
  same name and gets the cell back later has a higher epoch, so a late release
  does not touch its new claims (the epoch check). `claimed_by` limits the
  release to the dead node: a claim of another node is never released.
* *Only on a takeover.* A node that is `link_broken` or only `suspect` is not
  taken over (§8.10), so nothing is released and its claims stand. A takeover
  that lost its race (`epoch_changed`, `contended`) releases nothing, and
  neither does one refused by the quorum. With `takeover: [enabled: false]`
  nothing is taken or released.
* *A frozen node that comes back.* It is fenced. Its running attempts are not
  killed by the fence, so a running job would go on and overlap the new
  attempt. The node that executes a job handler (the cell owner) therefore
  checks, every `jobs.fence_check_ms` (1 s) while the handler runs, that it
  still owns the cell, with the check that stops new handlers (§8.13,
  `routing.owner_check_ms`), and kills the handler when it does not
  (`Atanor.Fence`, result `{:error, :handler_fenced}`, which writes nothing: the
  new owner decides). Only a definite answer stops it (the lease names another
  node, or the cell was fenced); a read that failed for another reason, such as
  a timeout, does not. The overlap is bounded by `fence_check_ms` plus
  `routing.owner_check_ms` plus a lease read after the node can run again.
  A node that is cut off from its peers but reaches the store reads the lease
  and stops the handler. A node that cannot read the lease (it is cut off from
  the store too, or the read times out) stops it at the end of its own lease,
  `expires_at_ms - skew_margin_ms` by its clock (§8.13): the handler is killed
  there whatever `release_claims` is, and the new owner starts the job only
  after the lease has expired on its clock plus the margin, so with skew below
  the margin the two attempts do not overlap. A node that is frozen cannot stop
  anything while it is frozen; its timer fires when it thaws. After an early
  takeover (§8.10) the new owner claims no job of the cell until the old lease
  has ended plus the margin (§8.13), so a released job waits for that instant
  instead of starting at once: up to `lease_ttl_ms`. With
  `routing.fence_defer_after_takeover: false` it starts at once and the overlap
  is bounded by the lease that is left.
* *A job still running when its node is fenced.* Same as above: the attempt is
  stopped at the next check. An attempt that completes before the check
  completes: its side effects happened and the new owner repeats the job. This
  is the at-least-once guarantee of §15.4 and §8.13: effects outside the
  cell need the job id or `idempotency_key` at the receiver.
* *A dead node.* Its attempts are gone with it. The job runs again once.

**What it does not do.**

* The release is lazy and per cell, like the takeover. A cell nobody asks for
  stays with its dead lease, and its jobs wait for their claim: the claim's
  expiry is also the wake-up (`@jobs` alarm), which takes the cell over and
  runs the job. A cell that receives any work (a request, an enqueue) is taken
  at once and its jobs are released. Atanor does not list the cells of a lost
  node.
* A job whose side effect completed on the old node, but whose result the
  fenced node could not write, runs again.
* With `release_claims: false`, claims expire at `claim_ms` and nothing is
  released; the fence (§8.13) still stops an attempt on a node that lost its cell.

| Option (`jobs:`) | Default | Meaning |
| --- | --- | --- |
| `release_claims` | true | release the claims of a node whose cell this node took over (§15.11), and this node's own claims when it drains (§15.12) |

The fence that stops an attempt is configured in `routing:` (§8.13: `fence`, `fence_check_ms`).

Tests: `test/atanor/jobs_claim_test.exs` (the release on one node: only the
named node's claims, only at the epoch, nothing to release) and
`test/cluster/jobs_release_test.exs` (a killed node, `release_claims: false`, a
`link_broken` node, a frozen node that returns, and a property over generated
sequences of kills, restarts, freezes and cuts: a job starts again on another
attempt only after a release of the previous owner's claim, or a claim that
expired, and the old attempt stops within the bound).

### 15.12 The claims of a node that hands its cells back

A node that drains (§8.11) leaves jobs behind that it did not finish: claims it wrote and no longer serves.
Left alone they would wait for `claim_ms` (60 s) although the node that takes the cell is ready at once.
With `jobs.release_claims` (default true), the drain releases them. The evidence is the node's own state, not
a detector: the drain closed the runner (`Slots.close/1`), so the node claims nothing more, and it still
owns the cells because the hibernation that hands them back has not started.

**What happens.** In `Atanor.Drain`, after the jobs wait (`stop.jobs_ms`) and before `Alambique.drain/2`,
`Atanor.Jobs.Drain.release/1` lists the cells that have a process on the node (`Alambique.cells/2`) and, for
each (up to `stop.drain_concurrency` at a time), calls `Atanor.Jobs.release_own/2`. It is the transaction of
§15.11 with the node itself as `claimed_by`: the `running` jobs with a live claim of this node get
`claimed_until_ms` set to now, and the `@jobs` wake-up is re-armed to now. No scan starts here. The event
`[:atanor, :job, :released]` records the count (`epoch` is `nil`).

**Why it is safe.**

* *Only when no job runs here.* `release/1` releases nothing while `Jobs.stats/1` shows a running attempt
  (the wait ended at `stop.jobs_ms` with a job still going). That attempt is not over, and releasing its claim
  would let the next node run the job beside it. The drain logs a warning, and those claims expire at
  `claim_ms` as after a crash. With no attempt running, every live claim of this node in a cell it owns
  belongs to no task: it is an orphan (a start that failed, a result write whose answer was lost).
* *A job that finished stays finished.* Only `running` rows are touched; `done`, `dead` and `pending` rows
  are not. A finishing job writes its result with a conditional update on its claim, so a release cannot
  undo it, and a job that ends after the drain closed the runner claims no next job (the chaining
  decision is taken when the job ends, not when it starts).
* *Fencing.* The release runs in the owner's cell transaction, before the lease is released. After the
  handback the next node takes the lease at a higher epoch, claims the job (the claim counts a new attempt)
  and runs it. The job keeps its id and idempotency key, so the at-least-once rule of §15.4 stands: an
  effect outside the cell needs the id or `idempotency_key` at the receiver. There is no takeover, so there
  is no fence deferral (§8.13): the new owner starts the job as soon as it wakes the cell.
* *Distinct node names.* `claimed_by` is the Erlang node name. Two nodes that share a name
  (`nonode@nohost`) cannot tell their claims apart; name each node.

**When the new node starts them.** Nothing needs to wake the cell: the `@jobs` row has a store index entry,
and every scheduler scans the index (§7.4). The new node's next tick (`alarms.tick_ms`, 1 s) finds the entry
that is due, takes the cell (the lease is free) and claims the jobs. Before the handback the same scan finds
the cell held by the other node and leaves the entry. A job that is pending and due starts the same way.

Tests: `test/atanor/jobs_handback_test.exs` (a claim released at the drain, a running job left to finish, a
finished job not repeated, a pending job started promptly by the node that takes the cell) and
`test/atanor/alarms_handback_test.exs` (an alarm due while two nodes scan fires once).

## 16. The change feed for workers

Alambique publishes every row change committed in any cell as a feed object
in the store (Alambique design §13). Reading the feed does not wake a cell.
Atanor exposes it to **native** workers through `Atanor.Env.changes/4`,
`Atanor.Env.feed_position/2`, `Atanor.Env.subscribe/3` and
`Atanor.Env.unsubscribe/2` (design §4). The namespace must be granted under
the manifest's `cells` binding; there is no separate feed binding. WASM workers
have no import for the feed.

### 16.1 Reading changes

`changes(env, namespace, position, limit)` calls `Alambique.Feed.read/3` with
the instance's feed context and keeps only the records and rewind markers (§16.6) whose cell belongs to
`namespace`. Atanor's own `_atanor_*` tables are not in the feed (§16.5). It returns
`{:ok, changes, next_position}`; an ungranted namespace is
`{:error, {:not_granted, {:cell, namespace}}}` and a store or position error
is passed through.

The position is Alambique's opaque, instance-wide position (it covers every
location and feed shard), not a per-namespace cursor. Consequences:

* `nil` starts at the oldest retained object.
* A position is instance-wide, not a per-namespace cursor: keep one position
  per namespace you read independently.
* One read can return **fewer changes than `limit`** after filtering, because
  the page is filled with objects of other namespaces and of `_atanor_*`
  tables. An object can carry several row changes, so a page can also contain
  more changes than `limit` objects.
* `next_position` can equal `position` when nothing new has settled. Store it
  and pass it back; do not build positions.
* A change can appear again in a later read, and the same change can repeat
  after an owner move or a lost acknowledgement. `Atanor.Change.id` is the
  idempotency key.
* A feed object that Alambique cannot decode (not JSON, an unknown shape or
  `op`, a body that is not a feed object, an unknown format version, a damaged or too large compressed object:
  a faulty or hostile writer of the store, or a writer newer than this node)
  comes from `Alambique.Feed.read/3` as an `Alambique.Feed.Rejected` in place of
  its records, and the position moves past it. It has no cell, so it belongs to
  no namespace: Atanor leaves it out of every result and every delivery, so
  workers never see it and it never stops the tailer. It is not silent: each
  one emits `[:atanor, :feed, :rejected]` with `reason` and the object `key`
  (§16.4), is counted in the `rejected` measurement of `[:atanor, :feed, :read]`,
  and the tailer logs a warning, at most one per `feed.max_backoff_ms` (the
  slowest rate of its read-failure warnings), with the number of objects since
  the last warning and the last key and reason.
* **The position is not held on `{:unsupported_format, _}`.** Holding was
  considered and not done. The position is the tailer's one shared cursor for
  every namespace of the instance, so one object of a newer writer would stop
  every subscriber, including those of namespaces it does not touch; the
  object would not become readable until this node is upgraded, and retention
  removes it after seven days anyway, so a held tailer would only delay the
  loss and stall everyone meanwhile; and the catch-up pages of subscribers and
  `changes/4` use positions of their own that Alambique moves past, so holding
  would have to be added in three places and still could not stop a reader that
  stores its position. What the operator needs is the alarm: the event, the
  counter on the dashboard (Feed group) and the warning. The remedy is to
  upgrade the node.

`Atanor.Change` is plain data:

| Field | Meaning |
| --- | --- |
| `namespace` | the granted namespace |
| `cell` | the cell key (the id is `<namespace>.<cell>`) |
| `table` | the changed table |
| `op` | `:insert`, `:update` or `:delete` |
| `key` | the primary key as a map of column to value, or `%{"rowid" => n}` |
| `row` | the new row as a map of column to value; `nil` for a delete. It lacks the columns that `alambique: [feed: [tables: ...]]` omits (§4.3): an absent key is a column left out of the feed, not NULL, which is a key with the value `nil` |
| `txid` | the TXID of the replicated batch |
| `at` | Alambique's record time in Unix milliseconds (the commit time when the batch was published within the feed window, otherwise its publication time) |
| `id` | Alambique's record id, the idempotency key |

`feed_position(env, :now)` returns the position at the clock's current time,
for a first read or subscription that should ignore older changes.

### 16.2 The tailer and subscriptions

`subscribe(env, namespace, from: position | :now)` registers the calling
process and returns `{:ok, ref}`. Subscriptions are per node and instance.
The first subscriber starts a lazily supervised tailer; the tailer stops when
the last subscriber unsubscribes or exits. Subscribers are monitored.

The tailer polls every `feed.poll_ms` and reads up to `feed.page_size` feed
objects per read (the same size is used for a catch-up page). When a read moved
the shared position, or a subscriber is still catching up, the next read follows
at once, so a backlog drains at the speed of the store and not at one page per
`feed.poll_ms`; a read that finds nothing new waits `feed.poll_ms`. A feed that
gets a new object every poll therefore costs two reads per interval, one of
them empty. It keeps one shared read position and fans out:

```elixir
{:atanor_changes, ref, changes, position}
```

Only non-empty pages for the subscriber's namespace are sent. The position is
the feed position after the page: store it and pass it to a later `subscribe/3`
or `changes/4`. Delivery is **at least once**; changes of one cell keep
Alambique's commit order, and changes across cells keep publication order.

A subscriber that starts at `:now` joins the shared stream immediately and
drops records whose `at` is before its subscription time minus the instance's
Alambique `skew_margin_ms`. The start position and the filter both move back
by that margin, because `at` is the publisher's clock: a change committed
after `subscribe/3` can carry a time before the subscriber's now when the
publisher's clock is behind. `:now` can therefore repeat up to the margin of
earlier changes, but it does not lose the change. A subscriber that
starts at an older position is `pending`: each poll (they follow one another
without a wait while any subscriber is pending) reads one page from its
own position with the same filtering and sends those changes, until a read
returns its position unchanged (it reached the end of the feed); then it joins
the shared stream. This choice keeps positions opaque: Atanor cannot order two
positions, so it cannot compute one minimum. Catching up independently avoids
missing changes and does not replay them to other subscribers; when the shared
stream is behind the catch-up, the new subscriber can see changes it already
caught up with again, which at-least-once delivery permits.

### 16.3 Backpressure, drops and errors

The tailer checks the subscriber's mailbox after each page. When it holds more
than `feed.max_backlog` messages, the subscriber is removed and receives

```elixir
{:atanor_feed_dropped, ref, position}
```

where `position` is the last position sent to it. The subscriber can process
the messages before the drop and resubscribe from the position; it must not
treat the drop as a cluster or store failure. A slow subscriber therefore
neither blocks the others nor grows without bound. Unsubscribing with
`unsubscribe(env, ref)` is idempotent; an exiting subscriber is removed.

A feed read error (a store failure, a bad position, a raised exception) does
not drop subscribers. The tailer retries after `feed.retry_ms`, doubling the
wait up to `feed.max_backoff_ms`, and keeps the shared position, so no change
is skipped. A successful read resets the wait.

### 16.4 Telemetry

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:atanor, :feed, :read]` | `duration` (native units), `records` read, `kept` after namespace filtering, `rejected` (objects Alambique could not decode) | `instance`, `namespace` (`nil` for the shared stream), `result`, `reason` on error |
| `[:atanor, :feed, :rejected]` | `count` (1) | `instance`, `namespace` (`nil` for the shared stream), `reason` (`:invalid_json`, `:bad_object`, `:bad_record`, `{:bad_op, op}`, `{:unsupported_format, version}`, `:bad_format`, `:too_large`, `:bad_compression`), `key` of the object |
| `[:atanor, :feed, :error]` | `count` (1), `retry_ms` | `instance`, `reason` |
| `[:atanor, :feed, :subscriber, :dropped]` | `count` (1), `backlog` (messages waiting) | `instance`, `namespace`, `reason`: `:backlog` |

### 16.5 Limits and options

Atanor starts Alambique with `feed: [internal_prefixes: ["_atanor_"]]`, so
the `_atanor_*` tables get no capture triggers and never enter the feed
(§15.1). The prefix is fixed, not an option: every node must use the same
value, and `:alambique` rejects `feed: [internal_prefixes: ...]`. Records
published before the prefix was adopted stay in the store until retention
removes them. The feed is in the store, so
a tailer on every node sees writes made on any node; each node runs one tailer
per instance. The Alambique feed itself is configured under `:alambique`, not
under Atanor's `:feed`: `window_ms`, `retention_ms`, `shards` and the rest. With
Alambique's defaults a record is readable after about 24 s (`window_ms` 10 s +
`op_timeout_ms` 10 s + 2 × `skew_margin_ms` 2 s); lower those when freshness
matters. A position older than the retained feed starts at the oldest object
left. `:now` positions and filters use `skew_margin_ms` from Atanor's
`:alambique` options, falling back to Alambique's documented default of 2 000
ms when the operator did not set it; that margin is why `:now` can repeat
earlier changes.

Atanor's `:feed` options are validated by `Atanor.Config`:

| Option | Default | Meaning |
| --- | --- | --- |
| `:poll_ms` | 1 000 | time between feed reads |
| `:page_size` | 100 | feed objects per read, shared and catch-up |
| `:retry_ms` | 1 000 | first wait after a read error |
| `:max_backoff_ms` | 30 000 | longest wait after repeated read errors |
| `:max_backlog` | 1 000 | messages in a subscriber's mailbox before it is dropped |

#### Limits

**WASM workers cannot read the change feed.** `Atanor.Env.changes/4`,
`Atanor.Env.feed_position/2` and `Atanor.Env.subscribe/3` are native-only. The
WIT packages in `wit/` have no change feed import, so a WASM component cannot
read changes directly and its manifest cannot grant them. Workaround: keep the
subscription in a native worker and call the WASM worker with
`Atanor.Env.call/3`, or query a cell from the guest on a timer; a native worker
can also maintain the cache and pass the result to the guest. Evidence: `wit/`,
`test/atanor/feed_test.exs`.

### 16.6 Rewind markers

`Alambique.rewind/4` (used by the undo of an operation, §15.10) puts a cell
back to an earlier state. Alambique publishes an `Alambique.Feed.Rewind`
record after the records it undoes, and Atanor delivers it as
`Atanor.Change.Rewind` in the same list as the `Atanor.Change`s, to
`Atanor.Env.changes/4` and to subscribers, filtered by the namespace of the
cell:

| Field | Meaning |
| --- | --- |
| `namespace`, `cell` | the cell that was rewound |
| `from_txid` | the last TXID of the state that was replaced |
| `to_txid` | the TXID that was restored |
| `txid` | the TXID of the rewind itself, `from_txid + 1` |
| `target` | what was asked: `{:txid, n}` or `{:timestamp, ms}` |
| `kept` | the tables that stayed as they were (`_atanor_*` with the undo) |
| `at` | the publication time in Unix milliseconds |
| `id` | `"<namespace>.<cell>:<txid>:rewind"`, the idempotency key |

After the marker the cell holds the state it had at `to_txid`. The changes of
the cell with a `txid` above `to_txid` and at most `from_txid` were undone;
they stay in the feed, before the marker. A worker that keeps a copy of the
cell must put the copy back to that state (keep its own history by `txid`, or
read the cell again) and go on with the changes after the marker. Changes at or
below `to_txid` that arrive after the marker are repeats, with the `id` they
had. A rewind to a state from before an earlier rewind brings the changes
that one had undone back.

The marker is written inside the rewind and published when the cell wakes next,
so it is not instant; a worker that reads the cell before then still sees the
rewound state. A worker that matches only `%Atanor.Change{}` fails visibly (a
function clause) when a marker arrives. One that filters with a comprehension
(`for %Atanor.Change{} = c <- changes`) ignores it and keeps a stale copy: it
must match the marker. The tailer, `changes/4` and the counts of
`[:atanor, :feed, :read]` (`kept`) treat the marker as a record of the
namespace. It needs no option or grant.

## 17. Release identity and crash diagnostics

### 17.1 Release identity

Atanor does not build or deploy OS releases; the operator does. It records
which build a node runs so the dashboard and a crash report can name it. The `:release` option has an `:id`: an operator-supplied immutable image
digest or commit. The default `"atanor-" <> Application.spec(:atanor, :vsn)`
is a development convenience, not a build identity: two builds of the same
version are different releases.

`Atanor.Release.info/1` returns the id, the Atanor, Elixir, OTP and Alambique
versions, an optional `:built_at`, and the paths and SHA-256 of
`atanor_wasm.so` and `alambique_nif.so` (unless `:hash_nifs` is false).
`GET /deployments` includes the `release` in each node's entry, and the
dashboard's Deployments page shows its short id. Nothing is stored for it.

Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `:id` | `"atanor-" <> vsn` | immutable release identity; production sets it |
| `:built_at` | `nil` | optional ISO 8601 build time |
| `:hash_nifs` | `true` | compute NIF SHA-256s once per file and mtime |

### 17.2 Crash diagnostics

Alambique's quarantine identifies the cell and the kind of native work in
flight (`cell`, `hydrator`, `compaction`, `query`, `relocate`) and records a
crash on the next start. It does not know Atanor's job, sweep operation,
deployment or release. Atanor adds a **breadcrumb** for durable units:
a file under `data_dir/diagnostics/units/`, a first byte `1` while busy and
`0` otherwise, a one-time JSON body with `unit_id`, `kind`, `worker`,
`deployment`, `cell`, `job_id`, `operation_id`, `release` and
`started_at_ms`. The tracker removes the file when the holder process ends,
so only a VM crash leaves a busy file. There is no fsync (see the limits below).

`:breadcrumbs` selects the units: `:off`, `:durable` (default: job attempts,
alarms, sweep driver pages, migration tasks, deployment activation and
WebSocket connections) or `:all` (every HTTP and TCP callback too). A WASM
HTTP request is not covered under `:durable`; a WASM job, alarm or WebSocket
runs inside the corresponding durable unit. A WebSocket keeps its marker file open
for its whole life (see the limits below). `:all` writes one file per
request and is for incident reproduction; §12 measures both.

At start, after `:settle_ms` (1 000 ms) so Alambique's quarantine tracker can
settle, the diagnostics process reads busy files, groups them into one report,
enriches each unit that names a cell with `Alambique.crashes/2` and
`Alambique.frozen?/2`, writes `<prefix>/crashes/<node>/<id>`, and removes the
files. If the store fails, the report stays under
`data_dir/diagnostics/pending/` and is retried every `:pending_retry_ms`; the
pending files stay under `:max_bytes`, the oldest removed first, so a store that
stays down does not fill the disk (§4.4). Reports older than `:retention_ms` are deleted every `:cleanup_ms`.

`GET /crashes` lists reports (`?node=`, `?after=`, `?limit=`), `GET
/crashes/:node/:id` reads one, and `POST /cells/:ns/:key/unfreeze` calls
`Alambique.unfreeze/2` after logging the admin action. The unfreeze forgets
the crash counter, so it is the operator's decision that the cell may start
from zero.

Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `:enabled` | `true` | the whole diagnostics subsystem |
| `:breadcrumbs` | `:durable` | `:off`, `:durable` or `:all` |
| `:dir` | `data_dir/diagnostics` | local breadcrumbs and pending reports |
| `:settle_ms` | 1 000 | wait before reading the previous boot's markers |
| `:max_files` | 10 000 | stale marker files read at start; the rest are counted and removed |
| `:max_units` | 1 000 | units in one report |
| `:max_bytes` | 33 554 432 | bytes of pending reports kept on disk while the store refuses them; the oldest are removed first |
| `:pending_retry_ms` | 60 000 | retry interval after a failed report write |
| `:retention_ms` | 2 592 000 000 | report retention (30 days) |
| `:cleanup_ms` | 3 600 000 | retention-cleaner interval |

A clean stop removes the markers through the tracker and produces no report.
A process killed with an Elixir `:kill` is monitored and removed; only a VM
crash leaves a busy marker. A machine that never restarts, and a crash with no Atanor unit,
write no report (see the limits below).

`Atanor.Diagnostics` owns the tracker, scan, pending retries and cleaner. It
starts after the Alambique instance and before the workload children.

#### Limits

**A WebSocket costs a file descriptor and a marker file.** With
`diagnostics: [breadcrumbs: :durable]` (the default) each WebSocket opens a
marker file for its whole life, so it holds two descriptors (the connection and
the marker) and one file in `data_dir/diagnostics/units/`. A node at the default
`http.max_connections` (16 384) can need more than the 1 024 descriptors that a
service manager often allows. Opening the marker for the length of a frame
instead puts a file create and delete on every frame, which was judged worse for
a busy socket. Workaround: raise the limit (`LimitNOFILE=65536` in the unit, or
`ulimit -n`) to at least twice `http.max_connections` plus the cells' files, or
lower `http.max_connections`; `diagnostics: [breadcrumbs: :off]` removes the
marker at the price of the crash reports of WebSocket handlers.

**A crash report does not survive a machine that never returns.** The
breadcrumb file is not fsynced: a VM crash keeps the page cache and the next
start reports it, but a whole-machine crash or a lost disk may lose it. A node
that never restarts writes no report, although Alambique's own quarantine may
still record the cell on the next start. That quarantine has the same
page-cache limit and is shown in the report when its counter is readable.
Workaround: treat `/crashes` as a best-effort record, not an audit log; keep the
OS core and `erl_crash.dump` as described in
[how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md), and use
`mix alambique.inspect` for the cell's stored crash counter.

**`:durable` breadcrumbs do not cover HTTP requests.** A crash in an ordinary
HTTP or TCP callback, native or WASM, may name only the cell (from Alambique) or
nothing. `:all` records every callback, at the cost of one marker file per
request; the measured cost is in §12. Workaround: use
`diagnostics: [breadcrumbs: :all]` while reproducing an HTTP crash, then return
to `:durable`. A WASM job or alarm is still covered by its job/alarm unit.
Evidence: `test/atanor/diagnostics_test.exs`.

**A crash with no Atanor unit writes no `/crashes` report.** A VM crash inside a
cell wake, a restore, a compaction or a queries-only cell call has no durable
unit; Alambique still records the cell in its quarantine counter and
`[:alambique, :cell, :crash_recorded]`, but Atanor does not know the cell list to
enrich, so `/crashes` stays empty for that death. Workaround: use
`mix alambique.inspect CELL` for the stored crash counter and the quarantine
events in the node log; the next job, alarm or other durable unit that touches
the cell produces a report. Evidence for these limits:
`test/cluster/diagnostics_test.exs`.

### 17.3 Migration rehearsal

A rehearsal answers "will this package's migrations apply to my real cells?"
before the package is activated. `POST /rehearsals` with `{worker, id}` fetches
the package (it must be in the store and belong to the worker), and
`Atanor.Rehearsal` runs the work as a task of the instance's task supervisor
on the node that received the request, wrapped in a `rehearsal` breadcrumb
(§17.2) like a migration task. It is not an activation: it changes no head,
registry entry or live cell.

**Sampling.** For every namespace of the package whose migration list is not
empty, in name order, it pages `Alambique.list_cells/2` (`prefix:
"<namespace>."`, `after:`, `limit: page_size`) in each location of the
placement (`Alambique.Feed.ctx/1` gives the locations) and takes
`sample_size` ids by reservoir sampling, with `:rand` seeded by `seed`. A
request without a seed gets a random one, recorded in `options.seed`. It
stops scanning a namespace after `max_scan` ids and stops sampling at
`max_cells`. The listing reads Alambique's schema index, so it has the limit
of any sweep: a cell that has not woken since the index exists is missing,
and a cell created after the listing is missed.

**Copies.** For each sampled cell, `Alambique.Ops.restore/5` restores the
latest state into `<dir>/<rehearsal-id>/<n>.db`, with a context built from the
cell's location (`Alambique.Replication.ctx/1`). No call goes through the
cell: no lease, no wake, no migration, no feed object, no quarantine marker.
`Alambique.frozen?/2` is read for the report. A copy that restores to nothing
is `empty` and skipped. Up to `concurrency` cells run at once, each in its own
task; the run directory is removed when the task ends, and a directory a
killed node left is removed by the next rehearsal on that node once it is
older than `stale_ms`.

**Migrations.** `Atanor.Migrations` hands migrations to Alambique as
functions of an `Alambique.Tx`, which only exists inside a live cell, so the
rehearsal cannot reuse that path. `Atanor.Rehearsal.Cell` does the file-level
equivalent with `Alambique.Sqlite`, as Alambique's wake does: one `BEGIN
IMMEDIATE` transaction per version, the version's statements one by one, then
`PRAGMA user_version = N` and `COMMIT`; a failure rolls the version back and
the later ones are not applied. A cell past the candidate's last version is
`schema_too_new`. Alambique drops its change-capture triggers around every DDL
statement of a live cell, because SQLite refuses to drop a column a trigger
names; the copy has no such wrapper, so the rehearsal drops the triggers (those whose
SQL names `_alambique_feed`) before the first version and leaves them out of the
schema comparison. After the last version it runs `PRAGMA quick_check` (or
`integrity_check`), counts the rows of every user table and hashes the
normalized `sqlite_master` entries of the user objects.

**Time and failure.** A cell has `timeout_ms`, counted from its start, for restore,
migrations and check. Restore gets `timeout_ms` as its own deadline, a watchdog
calls `Alambique.Sqlite.interrupt/1` on a statement that outlives the deadline,
and a version does not start after it. A copy that fails is a failed cell; the rehearsal
continues and ends `failed`.

**Record and report.** The record is `<prefix>/rehearsals/<id>`; the id is
`h-` plus the creation time in milliseconds (13 digits), so the listing is
chronological and retention needs no read. States:

| State | Meaning |
| --- | --- |
| `running` | written at the start; the task updates `updated_at_ms` and `progress` after every cell (compare-and-swap on the etag) |
| `done` | every sampled cell migrated, or the package has no migrations (`reason: "nothing_to_rehearse"`) |
| `failed` | a cell failed, sampling failed, the task crashed, or `strict_schema` found different schemas in a namespace (`error` names the stage) |
| `cancelled` | `POST /rehearsals/:id/cancel` set `cancel_requested`; the task reads it after each cell and stops, keeping the cells done |
| `stale` | not stored: a `running` record whose `updated_at_ms` is older than `stale_ms` is read as `stale` |

The newest record decides whether a new rehearsal may start (409
`already_running` while it is `running`); that is a best-effort check, not a
lock, so two nodes that start at the same instant can both run. Times are on
the instance clock (`alarms.clock`), so a test controls them.
Reports older than `retention_ms` are deleted when a rehearsal starts or the
list is read; there is no cleaner process. A report holds a `summary`
(counts, `schema_consistent`, `schema_groups`, `max_duration_ms`, versions,
sampling) and one entry per cell (outcome, versions, row counts before and
after, `schema_hash`, `integrity`, durations, `error`). A decrease of rows
is listed, not a failure; a different schema between the cells of one
namespace is reported, and a failure only with `strict_schema`. If the store
fails while the task writes, the task logs and the record stays `running`
until it reads as `stale`; the admin request that cannot reach the store is
503. No other node resumes a rehearsal.

Options (`rehearsal:` of `Atanor`, all validated; a request may lower
`sample_size`, `max_cells` and `timeout_ms`, and sets `seed`, `strict_schema`
and `integrity_check`):

| Option | Default | Meaning |
| --- | --- | --- |
| `:sample_size` | 10 | cells sampled per namespace |
| `:max_cells` | 100 | cells sampled in total |
| `:max_scan` | 10 000 | ids scanned per namespace |
| `:page_size` | 1 000 | ids per `list_cells/2` page |
| `:concurrency` | 2 | cells restored and migrated at once |
| `:timeout_ms` | 120 000 | one cell's restore, migrations and check; below `stale_ms` |
| `:integrity_check` | `:quick_check` | `:quick_check` or `:integrity_check` |
| `:strict_schema` | `false` | different schemas in a namespace fail the rehearsal |
| `:seed` | `nil` | sampling seed; `nil` is random per run |
| `:dir` | `nil` | temporary directory; `nil` is `data_dir/rehearsals` |
| `:stale_ms` | 600 000 | age of a `running` record's last update after which it reads as `stale` |
| `:retention_ms` | 604 800 000 | report retention (7 days) |

Public Alambique API used: `Alambique.list_cells/2`, `Alambique.Feed.ctx/1`
(locations and clock), `Alambique.Replication.ctx/1`, `Alambique.Ops.restore/5`,
`Alambique.Sqlite` (`open`, `execute`, `run`, `transaction_status`, `interrupt`,
`close`) and `Alambique.frozen?/2`. It uses no internal module. The
optional worker-provided check, a Mix wrapper and a dashboard page are not
built. [how-to-run-a-migration-rehearsal.md](how-to-run-a-migration-rehearsal.md)
shows the use.

#### Limits

**A migration rehearsal checks a sample, and a killed one is not resumed.** A
rehearsal applies the migrations to `sample_size` cells per namespace (10 by
default, 100 in total), not to every cell, so a cell with unusual data can still
fail when the package is activated. The sample has the limit of any sweep (Sampling, above). The copies are restored from the
store, so writes a live cell has not uploaded yet are not in them. The
rehearsal runs on one node; if that node dies, the record stays `running` and
reads as `stale` after `rehearsal.stale_ms` (10 minutes by default), and no
other node resumes it. Workaround: raise `sample_size` and `max_cells` on the
node for a package that changes a lot, rehearse again with another `seed`, and
start a new rehearsal after a `stale` one. A migration that cannot be undone
still needs a backup or Alambique's point-in-time restore. Evidence:
`test/atanor/rehearsal_test.exs`, `test/cluster/rehearsal_test.exs`.

### 17.4 The release as the product artifact

The product is one artifact: a Mix release named `atanor`, built from `daemon/` (the
application `atanor_daemon`), which starts one instance from `Atanor.Daemon` (the configuration is
[configuration.md](configuration.md#the-daemon-environment-and-file)). It holds the Erlang runtime,
`atanor_wasm.so` and `alambique_nif.so`, and the dashboard (Phoenix, LiveView, LiveDashboard). It holds
no worker: a WASM worker is deployed to a running node, and a native worker needs an image derived
from this one, because its module has to be loaded in the node.

**Layout.** `daemon/` is a Mix project of its own, next to the library, so that the library keeps its
optional dependencies optional and its `Atanor.Application` starts no instance. Its `mix.exs` reads
the lock of the repository root (`lockfile: "../mix.lock"`): one set of versions is tested and shipped.
Its version is kept in step with Atanor's by release-please (`extra-files` of
`release-please-config.json`).

**Image.** The `Dockerfile` at the root has these targets: `runtime`, the product image (the default
target), with only the libraries the release links (libssl3, libstdc++6, libncurses6, ca-certificates);
`harness`, the same plus `curl`, `iproute2`, `iptables` and `procps`, which `cluster/` needs for
faults, `tc` and healthchecks; and `artifact`, a scratch image with the release directory, from which
the tarball is cut. Both images run as the user `atanor` (uid 10001), with the data directory
`/var/lib/atanor/cells` owned by it. The entrypoint is `/opt/atanor/bin/atanor-entrypoint`, a release
overlay (`daemon/rel/overlays/bin`) of one `case`: the commands of the `atanor` CLI (`deploy`, `status`, ...)
run `Atanor.CLI.main/1` through `bin/atanor eval`, which starts no node, so `docker run IMAGE deploy /w --bucket
s3://...` needs no advertise address and no cookie (`rel/env.sh.eex` skips its checks for `eval`); any other
argument goes to `bin/atanor`, and the default command, `start`, runs the node. The settings are
environment variables, the secrets come through the `*_FILE` variables, and the start script
`rel/env.sh.eex` checks the cookie and names the node before the VM boots.

**Derived images.** Elixir code that has to share the VM with a node (a Phoenix and LiveView app, a native
worker's module) is built into a release of its own, not added to this one. The app depends on `atanor`
(a path or git dependency, never Hex) and starts the node itself: `Atanor.Daemon.children/1` returns the
processes of a node (renewable credentials and the instance named
`Atanor.Daemon.instance/0`, which finds the other nodes through the store), `AtanorDaemon.Application` starts exactly those, and the app's supervision
tree puts them before its own processes. There is one loader of the settings, `Atanor.Daemon`, and one
list of processes. The release is named `atanor`, so the image has the layout, the entry point and
`rel/env.sh.eex` of the product image. `mix atanor.release` copies those two files from the dependency
(`daemon/rel`) and writes a `Dockerfile`, which builds the release on the same bases as the root one
(a test compares the pins) and runs it as the user `atanor`. The Rust crates are compiled in the build stage, as for the
product image, so the first build costs about the same. `cluster/load` is the first consumer and
`examples/live-counter` the second. A native worker of such an image reaches a node only through a node
(`atanor deploy --url`, or a profile): `--bucket` refuses it because no node has checked the module. Embedding
Atanor in an arbitrary app, with your own release, is not a supported way to install it; the library API stays
because this image is built with it. [how-to-build-a-derived-image.md](how-to-build-a-derived-image.md) walks through one.

**Sources.** The build uses public sources only: Hex, crates.io and the git tag of Alambique in
`alambique.ref`, which `mix deps.get` clones. Nothing is rewritten in `mix.lock`.

**Publication.** When release-please creates a release, `.github/workflows/release.yml` builds the
`runtime` target on a native runner per architecture (`ubuntu-latest` for linux/amd64,
`ubuntu-24.04-arm` for linux/arm64; no emulation), pushes each image by digest to
`ghcr.io/this-is-npc/atanor`, tags a manifest list `<version>` and `latest`, and attaches
`atanor-<version>-linux-<arch>.tar.gz` (with its `.sha256`) to the GitHub Release. How to build the same
thing locally, what the tarball needs on the host, and the measured sizes and times are in
[how-to-build-the-release.md](how-to-build-the-release.md).

**Limits.** Only Linux, glibc, amd64 and arm64. The arm64 build is proved by the first run of the
workflow; it is not built locally. The tarball links the glibc and OpenSSL of its build base (Debian 13); the newest symbols are glibc 2.38 and OpenSSL 3.4.

## 18. Node releases

Atanor has no gate for rolling out node releases: a new build replaces the
whole cluster at once, and a canary for it returns once compatibility between
releases is designed. Worker deployments are a different object and roll one
node at a time (§5, §8.3). A native deployment needs its module in the node's
build: a node that does not have it refuses the head with
`{:code_mismatch, expected, loaded}` and keeps the old deployment serving
(§5.3), and a WASM package that imports a new interface or has an unknown
manifest key is refused the same way. Prefer expand/contract migrations,
because `migration_window` lets an old node serve a cell one schema version
ahead.

## 19. Reading a hot cell from other nodes

A cell has one writer, and until now it had one reader too: every call for the
cell, a read included, ran on its owner (§8.2). For a cell that is mostly read
this puts the whole read load on the one node that also has the writer.
Alambique can now answer a read on a node that does not own the cell, from a
local copy that polls the store, when the caller accepts data up to a bound old
(Alambique design §21). This section is how Atanor lets a worker ask for it,
which requests then stop going to the owner, and how a hot cell gets its
replicas without the operator choosing them. The ceiling that stays: the writes
of a cell still go through one writer. What moves is the reads, and, with
Alambique's pipelined commits (§19.5), some of the write latency.

### 19.1 The guarantee

`Alambique.query(inst, cell, sql, params, consistency: {:bounded, ms})` returns a
state that contains every write whose caller was told it was done more than `ms`
milliseconds before the read started. It may miss newer writes. It is served by
a fresh replica on the node, or, when there is none (the instance has no
`replicas:` option, the cell's switch is off, the replica is still being built
or too old), by the owner, so asking is always correct and works against an
owner that runs an Alambique release without replica reads. A node that owns the cell
answers from the cell. `consistency: :strong` is the default and does not
change. Two reads of one caller, one on a replica and one on the owner, can see
time go back by up to the bound. Atanor adds nothing to the guarantee and checks
it (§19.6).

### 19.2 The API of a handler

Native: `Atanor.Env.query(env, cell, sql, params, consistency: :strong |
{:bounded, ms})`. `ms` is a positive integer. The options are checked before the
call: `{:error, {:invalid_option, :consistency}}` for a bound that is not a
positive integer, for any other value, and for `{:bounded, _}` together with
`verify_lease: true` (the lease check and a replica contradict each other);
`{:error, {:invalid_option, key}}` for an unknown key. `execute/5` and
`transaction/4` take no `consistency:`: Alambique refuses it for a write.

WASM: a new function in `atanor:cell/sql`, `query-bounded(cell, sql, params,
max-lag-ms: u32)`, next to `query`. A new function and not a changed `query`, as
for `partition` (§4.2): a guest built against the previous interface still
loads, because the host may define more than a guest imports. The fixtures
other than `cell.wasm` were not rebuilt on purpose and still run. The error is
the interface's `error`: `failed("invalid option: consistency")` for a bound of
0. `query` is unchanged and strong.

The handler's own request can carry a default (§19.3).

### 19.3 Bounded requests: the reads that leave the owner

A handler that runs on the owner (§8.2) reads the cell locally: a bounded read
there is a strong read, and replicas would gain nothing. Replicas pay when the
handler runs on **another** node. So a request can declare that it is a read
that tolerates a bound, and then it is **not forwarded**: it runs on the node
that received it.

`route_key/2` says so with an options list at the end of the key:

```elixir
def route_key(%Request{method: "GET", path: "/notes/" <> room}, _env),
  do: {:cell, "notes", room, consistency: {:bounded, 500}}

def route_key(%Request{path: "/notes/" <> room}, _env), do: {:cell, "notes", room}

# a partitioned namespace: the partition key comes before the options
{:cell, "events", "stream", partition_key, consistency: {:bounded, 500}}
```

The options are `consistency: :strong | {:bounded, ms}` and nothing else; any
other key or value makes the key invalid (`{:error, {:bad_route_key, key}}`, 500
`internal_error`, logged like the other bad keys). The decision belongs to the
worker, per request, because only the worker knows that a `GET` reads and a
`POST` writes. A manifest flag per route would force the same answer on both.

What the request is:

* **It runs on the ingress node**, in `Atanor.Dispatch.execute/3`, with the env
  the ingress resolved, so the deployment is the one pinned at ingress (D1, §8.3)
  without the pinning machinery: nothing crosses nodes. It is not counted as
  forwarded (`forwarded: false` in `[:atanor, :call]`), emits no
  `[:atanor, :forward]`, and does not wait for the owner of the cell to be
  looked up or to be alive. The `Atanor.Env` has `consistency: {:bounded, ms}`.
* **Its reads default to the bound.** `Env.query/5` without `consistency:` uses
  the request's. It can ask for `consistency: :strong` or `verify_lease: true`
  for a single read, and Alambique then sends that read to the owner.
* **It may only read.** `Env.execute/5`, `Env.transaction/4`, `set_alarm/4`,
  `cancel_alarm/2`, `enqueue/3` and `cron/3` return `{:error, :read_only}`.
  *Decision.* The alternative was to let writes through and have Alambique
  forward them to the owner, which is correct for the cell. It was left out for
  three reasons. The handler would run its writes outside the owner's checks
  (§8.13: no handler starts on a node that lost the cell), so a request that
  reads from a replica and writes could act on stale data it read earlier on
  this node and write on top of it; the rule "a request that reads a bounded
  state cannot write" cannot be broken by accident. A request that wants both is
  an ordinary request: it goes to the owner and reads there. And the refusal is a
  clear error where a forwarded write would be a slow success. A worker nested
  with `Env.call/3` inherits the env and so the rule.
* **A failure of the cell is handled as for any call.** An owner reported down
  makes `Atanor.Cell` run the takeover for the cell (§8.10) and repeat the read,
  from the node that received the request.
* **Only HTTP requests of native workers.** WebSocket frames and TCP chunks are
  bound to the owner for the life of the connection (§8.5): a TCP `route_key`
  with options is a bad key, and the options of a WebSocket upgrade are ignored
  (the socket is served by the owner as before). Plug and WASM workers have no
  routing key and run on the ingress (§8.14); their `Env.query` and `query-bounded`
  already spread the reads over nodes, with Alambique forwarding to the owner.
* **The schema is the owner's.** A replica holds the state the owner last
  wrote, with the migrations the owner applied (§4.1). A request of a new
  deployment on a replica that the owner has not migrated yet can fail with an
  SQL error until it has (§5.3 says the same of a cell that is awake on old
  code).

Telemetry shows where each read was answered: Alambique's
`[:alambique, :replica, :read]` has `source` (`:replica` or `:owner`) and, for
the owner, the `reason`.

### 19.4 Replicas for a hot cell, by themselves

Replicas cost something on every node that reads the cell: disk for a full copy,
and about 12 store requests per second while they poll (Alambique's how-to).
Alambique leaves the choice of cells to the caller, with `Alambique.replicas/3`
(a marker object in the store that every node sees within `marker_ttl_ms`).
Atanor offers `Atanor.Cell.replicas/3` and `/2` for the operator, and
`Atanor.HotCells` for the automatic choice (§8.15): with `hot_cells: [replicas:
true]` the owner of a cell turns the switch on when the cell is read
`replica_enter` times a second in the cluster, for `sustain_ms`, and off when the
rate has been under `replica_exit` for `replica_hold_ms`.

* **The owner decides, from the reads of the whole cluster.** The reads that
  replicas serve are not seen by the owner: they run on other nodes. Each node
  counts the reads it makes (§8.15 does this for the cell load already) and, for
  the cells it does not serve, sends the rate to its peers in the load message it
  sends every `interval_ms`, the `max_tracked` hottest. The owner adds the rates
  it received within `stale_ms` to its own. Without this the owner would see the
  rate fall as soon as the replicas worked and switch them off.
* **Hysteresis.** Two thresholds (`replica_enter` 1000, `replica_exit` 500 reads
  a second), the sustained window `sustain_ms` that the placement already has,
  and `replica_hold_ms` (60 s): the switch stays on at least that long after the
  rate was last at the exit threshold. A cell that is read near the thresholds
  does not switch on and off. The decision is the pure function
  `Atanor.HotCells.Policy.replicas/4`; its properties are in
  `test/atanor/hot_cells_policy_test.exs`.
* **A change that fails is repeated** at the next sample (the store was down); the
  change runs in a task, so a slow store does not hold the sampling.
* **When the cell moves or sleeps**, the entry of the old owner is dropped; the
  marker stays in the store. A marker left on costs nothing until somebody reads
  the cell with a bound, and an unused replica stops after Alambique's `idle_ms`
  (10 minutes). The new owner decides again by the rates it sees. To switch it off
  by hand: `Atanor.Cell.replicas(instance, {ns, key}, false)`.
* **`move: false`** keeps the loop from moving cells (§8.15) while it still
  switches replicas, for an operator who wants only this.
* **Needs the instance option.** `hot_cells: [replicas: true]` without
  `alambique: [replicas: ...]` is refused at start (`ArgumentError`), since the
  switch would do nothing.
* **Partitioned cells (§4.2)** need nothing: a partition is a physical cell with
  its own marker, rates and replica, and `max_cells` of Alambique counts the
  partitions.

The default of `hot_cells.replicas` is **false**, and `alambique: [replicas:]`
is **off**. A replica is a copy of the whole database on each reader, a read that
can be older than the last write, and a few store requests a second per cell and
node. That is a choice for the operator who knows the cell, as is the placement
(§8.15). Alambique's own defaults are used for everything else (`pipeline_depth`
8, `replicas: []` limits).

Telemetry: `[:atanor, :hot_cell, :replicas]` (`reads` per second in the cluster;
the cell, `action` `:on` or `:off`, `result`). `GET /hot-cells` lists the cells
whose replicas this node switched on under `replicas`.

### 19.5 Pipelined commits

Alambique's `pipeline_depth` (1 to 16, default 8) lets a cell encode the next
batch while earlier ones upload, and answers callers in TXID order, each only
after its batch and all the earlier ones are durable. Atanor passes the option
through `alambique:` (`alambique: [pipeline_depth: 4]`) and checks it at start.
Atanor keeps Alambique's default: it was measured by Alambique against a store
with latency, and it applies to every worker without a change in them. Atanor's
own code did not need a change for it. `test/support/c1.ex` reads
`[:alambique, :cell, :commit]` events (now emitted at the acknowledgement, with
`inflight` and `queued_ms`) and the C1 checks pass unchanged.

### 19.6 Tests

* **R1** `test/cluster/replica_bound_property_test.exs`. Three peers, one counter
  cell, replicas on. Random operations: writes through random nodes, bounded
  reads through random nodes with a bound of 50, 150, 400 or 1000 ms (the
  replicas poll every 400 ms, so the short bounds make a read wait for a refresh
  and the long ones let the replica answer as it is), a write followed, after the
  bound has passed, by a read through another node, the switch turned on and off
  from random nodes, and moves of the cell between nodes. Writes and reads are
  stamped with the clock the peers share, as in C1. Every read must contain every
  write acknowledged to its caller more than `ms` before the read started, and
  only numbers that were sent, once each; and the runs together must contain
  reads served by a replica. **Mutation:** passing `ms * 100` to Alambique in
  `Env.query/5` fails the property on its first run (a read with a bound of 50 ms
  missed a write acknowledged more than 50 ms before it); the code was restored.
* `test/cluster/replica_reads_test.exs`: a bounded request runs on the ingress
  node with no forward and is answered by its replica; a write in it is refused
  with 409; a request without the option still runs on the owner; and with
  `hot_cells: [replicas: true]` a cell read through the other two nodes gets its
  switch on (event, marker and replicas serving) and, once the reads stop, off
  after `replica_hold_ms`, and is not switched on again.
* `test/atanor/bounded_reads_test.exs`: `Env.query/5` options and errors, the
  read-only env, the keys of `route_key/2`; `test/atanor/hot_cells_policy_test.exs`
  and `hot_cells_config_test.exs`: the policy as properties and the options;
  `test/atanor/wasm_test.exs`: `query-bounded`.

### 19.7 Measurements

The lab ran a hot cell with the reads bounded and replicas on, against strong
reads, at Alambique's default pipeline depth and at depth 1
([how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md)).

### 19.8 What it does not do

* It does not make writes faster than one writer; pipelining shortens the wait
  for the store, not the queue.
* A WebSocket frame, a TCP chunk, a job and an alarm still run on the owner.
* The limits of bounded reads and replicas are below.


#### Limits

**A bounded read can be older than the last write, and a replica is a full
copy.** A `consistency: {:bounded, ms}` read (§19) can miss writes acknowledged
less than `ms` before it, and two reads of one caller, one served by a replica
and one by the owner, can see time go back by up to the bound. There is no monotonic read across a
bounded and a strong read (Alambique's list). A replica
downloads the whole database before it serves, so the first bounded reads of a
node go to the owner, and each node that reads the cell keeps a full copy (at
most `max_bytes` of Alambique's `replicas:` per node, 1 GiB by default). A
request whose `route_key/2` declares a bound runs on the node that received it
and cannot write; only HTTP requests of native workers can be bounded
(WebSocket frames, TCP chunks, jobs and alarms run on the owner). The owner of a
cell that Atanor switched on moves it to another node: the marker stays on in
the store and the new owner decides again, so a cell that cooled down meanwhile
keeps its marker until somebody turns it off (`Atanor.Cell.replicas/3`).
Workaround: use `:strong` (or `verify_lease: true`) for reads that must not go
back in time, keep replicas for cells that fit `max_bytes`, and turn a stale
marker off by hand. Evidence: Alambique's `docs/what-does-not-work.md` and
`test/replica_properties_test.exs`; Atanor's
`test/cluster/replica_bound_property_test.exs`.