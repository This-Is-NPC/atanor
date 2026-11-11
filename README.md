# Atanor

Atanor is a generic runtime on the BEAM, in the family of Cloudflare
`workerd`. It runs **workers** and the stateful **cells** they use across a
cluster of nodes, with compute and S3-compatible storage only. It is built on
Alambique, which provides the cells, and it knows no product, organization,
tenant or region.

**Status:** 0.1.0 pre-release, not published on a package registry. Open defects are in
[docs/what-does-not-work.md](docs/what-does-not-work.md); the limits of the
design are in [Limitations](#limitations) and in [docs/design.md](docs/design.md).

## What it is for

Use Atanor to host many small tenants of one application: each tenant's data
lives in its own SQLite database (a cell) that is replicated to S3, wakes on
demand and sleeps when idle. Code is deployed as native Elixir workers or as
WebAssembly components, behind HTTP, WebSocket or TCP routes.

| Concept | Meaning |
| --- | --- |
| Worker | A unit of code that handles requests. Stateless by itself. |
| Cell | A named stateful unit with its own SQLite: single owner, replicated to S3, wakes on demand, sleeps when idle. |
| Binding | A capability granted to a worker. The worker can use only what it was granted. |
| Deployment | An immutable version of a worker, identified by the hash of its package. |
| Route | Maps incoming traffic to a worker: a domain or path for HTTP, a port for TCP. |
| Job | A row in a cell's SQLite; runs on the cell owner, with retries, cron, unique keys and a dead-letter set. |
| Bulk operation | One job enqueued in many cells, throttled, resumable and idempotent per cell; with `undo`, the cells can be rewound to just before it. |

What it provides: native and WASM workers, HTTP, WebSocket and TCP ingress,
jobs and alarms, a change feed, bulk operations, a cluster with failover,
worker rollouts and migration rehearsal, an admin API, a CLI, telemetry and a
read-only dashboard. The model is in [docs/design.md](docs/design.md).

## Installation

Atanor is not published yet. Add it to a Mix project as a path or git
dependency:

```elixir
{:atanor, path: "path/to/atanor"}
```

Alambique is a required dependency; the release Atanor is built against (a tag) is in
`alambique.ref` ([how to move it](docs/how-to-update-alambique.md)).

## A minimal example

Write a worker and its manifest, then add one instance to your supervision
tree ([full walk-through](docs/how-to-write-a-native-worker.md)):

```elixir
children = [
  {Atanor,
   name: MyApp.Atanor,
   store: {Alambique.Store.S3, s3_config},
   prefix: "myapp",
   data_dir: "/var/lib/myapp/cells",
   port: 4000,
   hosts: %{"notes" => ["notes.example.com"]}}
]
```

The worker implements `Atanor.Worker` and reaches cells through its
`Atanor.Env`. A cell is addressed by `{namespace, key}`:

```elixir
def handle_request(request, env) do
  {:ok, _} = Atanor.Env.execute(env, {"notes", "alice"}, "INSERT INTO notes (body) VALUES (?)", ["hi"])
  {:ok, %{rows: [["hi"]]}} = Atanor.Env.query(env, {"notes", "alice"}, "SELECT body FROM notes")
  %Atanor.Response{body: "ok"}
end
```

To try it on a development machine without a store, run a local node
([how to build and run it](docs/how-to-build-and-test.md#run-a-local-node)):

```sh
mise run dev -- --port 4000
```

```text
Atanor listening on http://127.0.0.1:4000
```

## Requirements

- Elixir 1.17 or later. Development uses the versions pinned in `mise.toml`
  (Erlang 28.5, Elixir 1.20.4, Rust 1.97.1).
- Rust and a C compiler: Alambique and `native/atanor_wasm` (Wasmtime) compile
  native libraries. WASM guests need the `wasm32-wasip2` target.
- Alambique, fetched from its public git repository at the release tag in `alambique.ref`.
- An S3-compatible store with conditional writes. Only SeaweedFS is tested.
- Optional: Ranch for `protocol: :ranch` listeners, and Phoenix with four extra
  dependencies for the dashboard. The runtime depends on neither.
- Optional, for the end-to-end OIDC test only: set `MAESTRO_TESTKIT` to a
  checkout of the Maestro testkit.

## Limitations

- WASM workers cannot serve TCP yet, and cannot read the change feed
  ([design §14.8](docs/design.md#148-alarms-sockets-and-what-is-left-out)).
- Atanor does not find other nodes: the operator connects them with a cluster
  library, `Node.connect/1` or `mix atanor.dev --connect`. Nodes that are not
  connected each serve the cells they can lease, and Alambique's fencing keeps
  each cell's data safe ([run a cluster](docs/how-to-run-a-cluster.md)).
- Cluster behavior was measured on one machine: three nodes and one SeaweedFS
  process in VMs on one host, with injected latency and loss, not a real network
  or a replicated bucket ([the lab](docs/how-to-run-the-cluster-lab.md)). Run the
  scenarios on your own network before sizing.
- Other limits of the design, each with its workaround, are in the "Limits"
  paragraphs of [docs/design.md](docs/design.md) (for example the failover
  window of [§8.10](docs/design.md#810-acting-on-a-confirmed-failure)).
- The memory of a node grows with its awake cells ([configuration](docs/configuration.md#cells-limits-memory-and-store-requests)).
- A file system that stalls writes slows the cells and the store; see
  [the container cluster guide](docs/how-to-run-a-cluster-in-containers.md#keeping-the-data-in-memory).
- A new build of the nodes replaces the whole cluster at once: Atanor has no
  canary for node releases yet, and one returns once compatibility between
  releases is designed.
- Open defects: [docs/what-does-not-work.md](docs/what-does-not-work.md).

## Documentation

[docs/README.md](docs/README.md) maps every page. Start with:

- [Write a native worker](docs/how-to-write-a-native-worker.md) or [a WASM worker](docs/how-to-write-a-wasm-worker.md).
- [Configure an instance](docs/configuration.md).
- [Deploy a worker](docs/how-to-deploy-a-worker.md) with the `atanor` command ([reference](docs/cli.md)).
- [Run a cluster](docs/how-to-run-a-cluster.md).
- [Open the dashboard](docs/how-to-open-the-dashboard.md) and [read the telemetry](docs/telemetry.md).
- [Design](docs/design.md) and [build and test](docs/how-to-build-and-test.md), for contributors.
- [Changelog](CHANGELOG.md).

## License

MIT; see [LICENSE](LICENSE).
