# Prior art

This page is for contributors. It compares four systems that solve the same
problem as Atanor, and records which of their choices Atanor keeps, changes
or rejects. [design.md](design.md) §13 points here.

Pages were read on 2026-10-26. Tags used below:

* **[V]** verified in the cited page or source file.
* **[I]** inference or recollection, not confirmed in a page we read.
* **[S]** measured in the wasmex spike (see "Runtime constraints found by the
  spike").

All four systems are pre-1.0 or fast-moving. Re-check a claim before relying
on it.

## 1. workerd and Durable Objects (Cloudflare)

Sources: [workerd README](https://github.com/cloudflare/workerd),
[workerd.capnp](https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp),
[bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/),
[compatibility dates](https://developers.cloudflare.com/workers/configuration/compatibility-dates/),
[limits](https://developers.cloudflare.com/workers/platform/limits/),
[versions and deployments](https://developers.cloudflare.com/workers/configuration/versions-and-deployments/),
[Durable Objects](https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/).

* **Worker model.** A JavaScript or Wasm module run in a V8 isolate. [V]
* **Manifest.** Two layers. `workerd` reads an operator config in Cap'n Proto
  text with `services`, `sockets` and `extensions`. A service is a `worker`,
  `network`, `external` or `disk`. A worker has `modules`,
  `compatibilityDate`, `compatibilityFlags`, `bindings`,
  `durableObjectNamespaces`, `durableObjectStorage` and `globalOutbound`. [V]
  Developers write `wrangler` config and the platform produces the rest. [I]
* **Capabilities.** The config "uses capabilities instead of global
  namespaces". A worker "has access to no privileged resources at all"
  unless a binding is declared. A binding is "a permission and an API in one
  piece": the worker receives an object in `env`, and the underlying secret
  is never exposed to its code. [V] Binding kinds include `service`, `kvNamespace`,
  `r2Bucket`, `durableObjectNamespace`, `queue`, `text`, `json`, `wrapped`. [V]
* **Outbound network.** Global `fetch()` goes to `globalOutbound`, default
  the `internet` service. The `network` service allows only publicly
  routable addresses by default, "in order to prevent SSRF attacks". [V]
* **State.** A Durable Object has a name, is created on first access, is
  single-threaded, and has private transactional SQLite storage (1 GB per
  object at the time of reading). It hibernates when idle and can set an
  alarm. [V] In `workerd`, a namespace has either a `uniqueKey` (stable,
  persistent; losing it can make stored data unrecoverable) or is
  `ephemeralLocal`. [V]
* **Routing.** Operator config binds `sockets` to services. On Cloudflare,
  traffic reaches a worker through Custom Domains, Routes or `workers.dev`.
  Calls between services run "in the same thread and process" (nanoservices). [V]
* **Versioning.** The runtime version is a **compatibility date**: a worker
  pinned to a past date gets the behavior of that date, and old dates are
  supported "forever". [V] A **version** is an immutable snapshot of code,
  bindings and compatibility settings; a **deployment** says which one or two
  versions receive traffic, with percentage splits and version affinity.
  Storage resources are not versioned. [V]
* **Limits.** 128 MB per isolate. CPU time excludes time waiting for I/O.
  Exceeding CPU or memory returns error 1102 to the client. [V]
* **Isolation.** The README states that `workerd` is not a hardened
  sandbox for hostile code and recommends an extra layer such as a VM. [V]

## 2. Deno celld

Sources: [github.com/denoland/celld](https://github.com/denoland/celld),
[celld.dev](https://celld.dev/).

`celld` exists and is a Deno project. We found no other "celld"; the two
sources above describe the same thing. They disagree on the release number
(v0.4.1 in the README text, v0.6.2 on the site), so it is a fast-moving
beta. [V] Third-party articles found in a search added claims we could not
confirm, including one that says it uses FoundationDB, which contradicts the
README. We ignore those.

* **What it is.** A self-hosted daemon that runs Cloudflare Workers apps and
  Durable Objects on your own machines, with a bucket (S3, GCS or Azure) as
  the only shared state. Each node embeds V8. [V]
* **Worker model.** The unmodified Wrangler bundle. `celld deploy` reads
  `wrangler.json`, accepts a documented subset and fails on unknown keys. [V]
* **Cells.** Each Durable Object instance, and each KV namespace, D1 database,
  queue and workflow, is a "cell": a named server with its own SQLite,
  replicated in LTX format. A conditional bucket write gives one node
  ownership; there is no membership protocol or consensus service. Epoch
  fencing enforces one writer. [V] This is the model Atanor takes from
  `alambique`.
* **Bindings.** The ones Cloudflare defines (Workers, Durable Objects, KV,
  Queues, D1, R2, Workflows, Cron, assets). Granting follows Wrangler. [V]
* **Routing.** Any node can receive a request; the owner is found through
  bucket leases and the request is forwarded over signed peer HTTP. Domain
  mapping is left to the operator's load balancer. [V]
* **Deployment.** `celld deploy . --bucket s3://...` writes deployment objects
  and `deploy/current.json`; nodes load the latest committed one. One fleet
  runs one application. Mixed node versions cannot share a fleet. The docs
  show no version history or rollback command. [V]
* **Limits.** V8 heap 128 MB per isolate by default, a per-node cap on
  resident cells (`CELLD_MAX_RESIDENT_CELLS`) and RSS-based shedding of idle
  cells. CPU time limits are not described. The site quotes a cost model of
  about 0.47 MB per resident cell and 2,500 cells per 8 GB node. [V]
* **Security.** Peer traffic needs a trusted private network or overlay; it
  is HMAC-signed for control operations only. Bucket credentials equal fleet
  administrator access. [V]

Closest to Atanor: the cell and bucket model. Different: V8 and Wrangler
compatibility; Atanor has neither.

## 3. Fermyon Spin

Sources:
[manifest reference](https://spinframework.dev/v3/manifest-reference),
[writing apps](https://spinframework.dev/v3/writing-apps),
[variables](https://spinframework.dev/v3/variables),
[SQLite](https://spinframework.dev/v3/sqlite-api-guide),
[registry](https://spinframework.dev/v3/registry-tutorial).

* **Worker model.** An application is a set of Wasm components plus
  `spin.toml`. Each request instantiates a component; components export an
  HTTP handler. Triggers (`http`, `redis`, cron) connect events to
  components. [V] The docs we read do not name `wasi:http`; Spin 3 does use it. [I]
* **Manifest.** TOML, `spin_manifest_version = 2`. Tables: `application`,
  `variables`, `trigger`, `component`. Component keys are kebab-case. A
  component has `source` (a path, or `{url, digest}` which Spin verifies),
  `allowed_outbound_hosts`, `key_value_stores`, `sqlite_databases`,
  `variables`, `environment`, `files`, `dependencies`, `build`. [V]
* **Capabilities.** Default deny, granted per component in the manifest:
  `allowed_outbound_hosts` takes `scheme://host:port` entries with `*`
  wildcards; empty means no outbound access; it covers HTTP, Redis, MySQL and
  Postgres but not key-value or SQLite. `sqlite_databases = ["default"]`
  grants a database. Custom database names need a runtime config file. [V]
  Enforcement is in the host: the interface exists but checks the grant. [I]
* **State.** No actor model. Key-value and SQLite databases are shared by
  every instance of the application, backed by a store the operator
  configures. Only the `default` key-value store can be named. [V]
* **Variables and secrets.** Declared in `[variables]` with `default`,
  `required`, `secret`. A component sees only variables mapped in its own
  `[component.x.variables]`, with `{{ name }}` templates. Providers: `SPIN_VARIABLE_*`
  environment, HashiCorp Vault, Azure Key Vault, `--variable`. [V]
* **Routing.** Routes live in the application manifest:
  `[[trigger.http]] route = "/users" component = "user-manager"`. A route is
  an exact path, a `:param` pattern or a trailing `...` wildcard; the
  longest prefix wins; `{ private = true }` is for internal chaining. There is
  no host in the manifest; the operator owns hosts and ports. [V]
* **Deployment.** Apps are OCI artifacts: `spin registry push ref:v1`,
  `spin up -f ref:v1`. Tags are mutable by registry convention; components
  can be pinned by SHA-256. [V]
* **Limits.** The pages we read document none. The source of `spin up`
  mentions a max instance memory hook and a pooling allocator. We did not
  find fuel, epoch or timeout settings. [V for the absence in the pages read]

## 4. wasmCloud

Sources:
[application model](https://wasmcloud.com/docs/ecosystem/wadm/model),
[capabilities](https://wasmcloud.com/docs/concepts/capabilities),
[linking](https://wasmcloud.com/docs/concepts/linking-components/),
[host config](https://wasmcloud.com/docs/reference/host-config),
[docs home](https://wasmcloud.com/docs/).

wasmCloud has two generations. The docs mark v1 (NATS lattice, `wadm`) as no
longer actively maintained and point to v2 (`wash`, `wash-runtime`, a
Kubernetes operator). We describe v1 in detail because only it is documented
in the pages we read. [V]

* **Worker model.** A Wasm component whose imports and exports are WIT
  interfaces. At least one export must be linked to run it. Imports need not
  be fulfilled at build time, only at instantiation. [V]
* **Manifest.** `wadm` uses the Open Application Model (YAML or JSON):
  `apiVersion: core.oam.dev/v1beta1`, `kind: Application`, `spec.components`
  of type `component` or `capability`, each with `properties` (image, config)
  and `traits` (`spreadscaler`, `daemonscaler`, `link`). [V]
* **Capabilities.** A **capability provider** is a separate process that
  implements a WIT interface (for example `wasi:keyvalue`) and is swappable.
  A **link** connects importer to exporter by `namespace`, `package` and
  `interfaces`, with `source_config` and `target_config` (string values only)
  that reach only the two ends. The host mediates calls over NATS with wRPC,
  on the same host or across hosts. [V] v2 states that the sandbox is
  deny-by-default and the operator chooses which interfaces a component gets;
  the page does not say how. [V]
* **State.** None in the model. State comes from providers (key-value, SQL,
  blob). [I]
* **Routing.** The HTTP server is a provider. A link from it to a component
  on `wasi:http/incoming-handler`, with `source_config` such as
  `address: 0.0.0.0:8000`, is the route. Hosts and ports are therefore
  operator-side configuration. [V]
* **Deployment.** Components and providers are OCI images. A manifest has an
  optional `version` annotation; `wadm` keeps a history ordered by storage
  time and does not compare version strings. Scalers place instances by host
  labels. [V]
* **Limits.** The v1 host config page lists only RPC, policy and heartbeat
  timeouts. We found no documented memory or CPU limits. [V for the absence]

## 5. Comparison

| | workerd | celld | Spin | wasmCloud v1 |
| --- | --- | --- | --- | --- |
| Code | JS, Wasm | JS (Wrangler bundle) | Wasm components | Wasm components |
| Engine | V8 | V8 | Wasmtime | Wasmtime |
| Manifest | Cap'n Proto (operator) plus Wrangler config | `wrangler.json` subset | `spin.toml` | OAM YAML (`wadm`) |
| Grant unit | binding in `env` | Wrangler binding | manifest field per component | `link` trait per interface |
| Default | no access | as Wrangler | no outbound, no storage | no access |
| Enforced by | object absent from `env` | same | host checks grant | link must exist; provider |
| Outbound HTTP | `globalOutbound`; public IPs only by default | as Wrangler | `allowed_outbound_hosts` (scheme, host, port) | provider and link config |
| Stateful unit | Durable Object (named, one instance) | cell (named, one owner, bucket) | shared KV and SQLite | provider-defined |
| Routing | operator sockets; zone routes | any node, forward to owner | routes in manifest, hosts by operator | HTTP provider link |
| Version unit | version plus deployment, compat date | `current.json`, no history documented | OCI tag, digest pin | `version` annotation, ordered by time |
| CPU limit | CPU ms, I/O excluded | not described | not documented | not documented |
| Memory limit | 128 MB per isolate | 128 MB heap, RSS shedding | not documented | not documented |
| Hostile code | not a hardened sandbox | trusted private network | Wasm sandbox | Wasm sandbox |

## 6. Choices for Atanor

Each choice says what [design.md](design.md) §3 and §4 do today and whether
the prior art supports it.

### 6.1 JSON manifest named `atanor.json` — keep, add a version

* Evidence: `celld` and Wrangler use JSON; Spin uses TOML; `wadm` uses YAML or
  JSON. No system requires a particular syntax. Atanor already stores heads
  as JSON, and Elixir reads JSON without a new dependency. Keep JSON.
* Gap: every system but workerd marks the manifest format version
  (`spin_manifest_version`, `apiVersion`, compatibility date). Add
  `"manifest_version": 1`. Reject unknown keys, as `celld` does, so typos
  cannot silently drop a grant.
* Gap: JSON has no comments. Publish a JSON Schema and let `atanor deploy`
  validate against it.
* The example in design.md lists both `module` and `component`. Spin has one
  `source` per component. Make them mutually exclusive by `kind`.

**Decided (stage 3):** `manifest_version` is required and unknown keys are
errors; see design.md §3. The JSON Schema is not published yet.

### 6.2 One manifest for native and WASM workers — keep

Spin and workerd use one binding model for all code they run, and `celld`
reuses Cloudflare's. Atanor's native/WASM split is its own. One manifest with
one `bindings` section keeps the grant model identical, which is what the
B1 property needs.

### 6.3 `bindings` keyed by kind — keep; make names explicit where it matters

Wrangler declares a name per binding (`binding = "MY_BUCKET"`). Spin and
`wadm` name the resource. In Atanor, `cells.<namespace>` is both the name and
the grant, which is enough. Two details to add:

* `workers: ["auth"]` binds by target name. If two deployments of the same
  worker must be reachable under different aliases, switch to an object
  `{alias: target}`. Not needed yet.
* Cell namespaces are persistent identity, like a `uniqueKey` in workerd,
  which warns that losing it can make stored data unrecoverable. Document
  that renaming a namespace abandons its cells, and that §4.1 refuses lowering
  migrations.

### 6.4 `http.allow` — keep, but tighten the syntax

Spin's `scheme://host:port` entries with `*` wildcards are more precise than
a host list, and an empty list means no outbound access. Adopt both:

* entries are `host`, `host:port` or `scheme://host:port`; define wildcards
  (`*.example.com` only);
* default deny, as design.md already says;
* resolve names and reject private, loopback and link-local addresses unless
  the operator allows them. workerd does the same by default for SSRF. This
  matters for a multi-tenant cluster.

**Decided (stage 3):** adopted as recommended; the syntax and the address
check are in design.md §4.

### 6.5 Secrets — keep names in the manifest, values with the operator

Spin and `wadm` both give a component only the values it names, and keep
values out of the package. Same as Atanor. Optional: `required` so a deploy
fails when the operator has not supplied a name.

### 6.6 Routes — keep path routes in the manifest, move hosts and ports to the operator's approval

Spin keeps paths in the manifest and hosts and ports with the operator.
workerd and `wadm` keep all of it on the operator side. Cloudflare binds routes to
zones that the account owns. Atanor's manifest carries `host` and TCP `port`.
If packages are untrusted, a package could claim another worker's host or a
port like 25.

Recommendation:

* The manifest declares the routes the worker needs (intent).
* A route becomes active only if the operator's configuration allows it
  (host patterns per worker, TCP listeners by name mapped to ports).
* Prefer TCP `"listener": "smtp"` in the manifest and `smtp = 2525` in
  operator config over a literal port.
* Keep longest-prefix matching (same as Spin and design.md §7.1).

This changes §3 and §7.1 slightly. Atanor's trust model is explicit:
everything an instance runs is trusted and the administrator's responsibility;
WASM is least privilege, not a hostile-code sandbox. Route approval therefore
prevents accidents and collisions, not a malicious package.

**Decided (stage 3):** adopted. The operator's `hosts:` and `listeners:`
options approve routes; without `hosts:` any host is allowed. See design.md
§3, §7.1 and §7.3.

### 6.7 Limits — keep the three kinds, drop `fuel` from the manifest for now

Cloudflare limits CPU time excluding I/O waits and memory per isolate. The
others document little. Atanor's manifest has `timeout_ms`, `memory_bytes`
and `fuel`. The spike [S] found that the `wasmex` release we target can
enforce wall-clock and memory limits on components but cannot meter fuel on
them. Until Atanor has its own runtime layer, ship `timeout_ms` and
`memory_bytes` and leave `fuel` out, or accept it as reserved. Wall-clock
includes time spent in host calls (cell SQL); say so in the docs.

### 6.8 Deployments by hash with a head and a previous list — keep

Atanor's content-addressed package with a compare-and-swap head covers what
`celld` documents (a current pointer) and adds rollback, which `celld` does
not document. Cloudflare's version versus deployment split is the same idea:
immutable version, mutable pointer. Not adopted now: gradual deployments
with two live versions. D1 (one request, one version) is compatible with
adding them later.

### 6.9 Runtime ABI version — add what workerd calls a compatibility date

workerd keeps old behavior forever by date. Atanor's equivalent is the
version in the WIT package name. The host must keep registering older
versions of an interface next to newer ones, so a deployed package keeps
running after an Atanor upgrade. A manifest field naming the ABI is not
needed: the imports of the component already state it. [S] confirms that
imports carry the version (`atanor:demo/sql@0.1.0`) and that the host must
provide that exact name.

### 6.10 Custom WIT packages for bindings (`atanor:cell/sql`) — keep, with rules

* Use standard WASI where one exists. `wasmCloud` uses `wasi:keyvalue` and
  `wasi:http`; Spin serves `wasi:http`. Atanor serves `wasi:http` for the
  worker entry point (already decided) and should use `wasi:http` types in
  an outbound binding if the runtime allows it.
* There is no standard cell or SQL interface. Spin and `wasmCloud` ship their
  own packages in such cases. A custom package is justified for `sql`,
  `alarms`, `sockets` and `workers`.
* One WIT interface per binding, versioned (`atanor:cell/sql@0.1.0`), so that
  the presence of an import is the grant. Do not publish a single "everything"
  world: a component must import only what it needs, because an import the
  host does not provide fails instantiation [S].
* Package layout: `atanor:cell` (sql, alarms, sockets), `atanor:worker`
  (call), `atanor:config` (secrets). Group by who implements them, so the
  versions can move independently.
* Do not put worker-specific schemas in the package; the guest owns its SQL.

### 6.11 What Atanor adds

No system we studied combines these, which is the reason for Atanor:

* wasm workers and native Elixir workers on the same bindings;
* named cells with a single owner, provided by `alambique`, as the state model
  for Wasm workers (`celld` has it for V8; Spin and `wasmCloud` do not);
* TCP ingress with a routing-key hook so a connection lands on its cell.

## 7. Runtime constraints found by the spike

The wasmex spike ran against `wasmex` 0.15.1 (Wasmtime 47). It is relevant here
because it limits which of the choices above can be enforced as written.
The facts that affect formats:

* A component's imports must be provided by the host under their versioned
  names; a missing one fails instantiation with `component imports instance ...
  but a matching implementation was not found in the linker`. [S]
* All WASI preview 2 interfaces are linked into every component; they are
  empty (no files, no environment, no sockets). With `allow_http: false`
  there is no `wasi:http` outbound. With `allow_http: true` wasmex also
  inherits the host network, so there is no host allowlist. [S] An
  `http.allow` binding therefore has to be a custom import, not
  `wasi:http/outgoing-handler`, unless Atanor moves to its own NIF.
* `wasmex` 0.15.1 has no API to build the `incoming-request` and
  `response-outparam` resources that `wasi:http/incoming-handler` needs. We
  did not run a `wasi:http` guest to confirm the failure; this comes from
  reading the source. [V] The working entry point in the spike is a custom
  exported function `handle(request) -> response` over WIT records that mirror
  the `wasi:http` types. [S]
