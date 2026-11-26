# Atanor

Atanor is a generic runtime on the BEAM, in the family of Cloudflare
`workerd`. It runs **workers** and the stateful **cells** they use across a
cluster of nodes, with compute and S3-compatible storage only. A cell is a
SQLite database with a single owner, replicated to S3, that wakes on demand
and sleeps when idle. Atanor is built on Alambique, which provides the cells,
and it knows no product, organization, tenant or region.

## Install

Atanor ships as one daemon, from the release. Pick one:

- **Container image (the default):** `docker pull ghcr.io/this-is-npc/atanor:0.11.0` <!-- x-release-please-version -->
  (`:latest` or a version tag), for linux/amd64 and linux/arm64. It pulls without a login. It starts
  a node with no argument and runs the `atanor` command for `deploy`, `status` and the rest.
- **Tarball:** `atanor-<version>-linux-<arch>.tar.gz`, with its sha256, on each GitHub release. It needs
  glibc 2.38 or later, OpenSSL 3.4 or later, `libstdc++6` and `libncurses6`.

The daemon takes `ATANOR_*` environment variables or a JSON file
([reference](docs/configuration.md#the-daemon-environment-and-file)).
Remove it with the [uninstall steps](docs/how-to-operate-atanor.md#uninstall).

## Start here

- [Run a node locally](docs/how-to-run-a-node-locally.md): one node over a local S3 store, a worker
  deployed to it and called. Start here.
- [Deploy a worker](docs/how-to-deploy-a-worker.md): put a new version on the nodes, switch to it and
  roll back.
- [Write a WASM worker](docs/how-to-write-a-wasm-worker.md), or [a native one](docs/how-to-write-a-native-worker.md).
- [Run it in production](docs/how-to-run-in-production.md): balancer, TLS, private network, credentials.
- [The map of the documentation](docs/README.md) lists every page by the question it answers.

## Big ideas

**[Design](docs/design.md)** — the model: workers, cells, bindings, storage layout and guarantees.

**[Configuration](docs/configuration.md)** — the options a node takes, and the environment variables and file keys that set them.

**[WASM workers](docs/how-to-write-a-wasm-worker.md)** and **[native workers](docs/how-to-write-a-native-worker.md)** — code that handles requests, with a cell as its state.

**[TCP](docs/how-to-serve-tcp.md)** and **[WebSockets](docs/how-to-use-websockets.md)** — ingress beyond HTTP, and pushes to the sockets of a cell.

**[Ephemeral messages](docs/how-to-share-ephemeral-messages.md)** — cursors, presence and signals sent to every socket of a cell, without writing to it.

**[Jobs](docs/how-to-use-jobs.md)** and **[alarms](docs/how-to-use-alarms.md)** — work that runs later in a cell, with retries and a dead-letter set.

**[Bulk operations](docs/how-to-run-a-bulk-operation.md)** — one job run across many cells, throttled, resumable and, with `undo`, reversible.

**[Change feed](docs/how-to-follow-cell-changes.md)** — read or follow the changes of a granted namespace without waking its cells.

**[OIDC](docs/how-to-protect-a-route-with-oidc.md)** — require a valid access token on a route and read its claims in the worker.

**[Cluster](docs/how-to-run-a-cluster.md)** — several nodes, failover, and stopping a node without errors.

**[Hot cells](docs/how-to-place-hot-cells.md)**, **[replicas](docs/how-to-read-from-replicas.md)** and **[partitions](docs/how-to-partition-a-cell.md)** — how a very busy cell is placed, read and split.

**[Operate it](docs/how-to-operate-atanor.md)** — what to monitor, backup and restore, upgrades and common incidents.

**[Admin API](docs/how-to-use-the-admin-api.md)**, **[dashboard](docs/how-to-open-the-dashboard.md)** and **[telemetry](docs/telemetry.md)** — how to see and control a running node.

**[Derived image](docs/how-to-build-a-derived-image.md)** — your own Elixir code, Phoenix and LiveView included, beside a node.

## Interface

| What | Where |
| --- | --- |
| Your workers | HTTP and WebSocket on port 4000, TCP on the ports your manifests claim. |
| Admin API | Port 4001, with a bearer token ([how](docs/how-to-use-the-admin-api.md)). |
| Deploys | The `atanor` command, through a node or straight into the bucket ([reference](docs/cli.md)). |
| Dashboard | Read-only, on port 4002 when `ATANOR_DASHBOARD_TOKEN` is set ([how](docs/how-to-open-the-dashboard.md)). |

## Requirements

To run it:

- Docker, or a Linux host (amd64 or arm64) for the tarball.
- An S3-compatible store with conditional writes, and a bucket. Only SeaweedFS is tested. AWS
  credentials are read as the AWS SDKs read them ([configuration](docs/configuration.md#aws-credentials)).
- For a cluster: a private network between the nodes, with ports 4369 and 9100 to 9110 open
  ([production](docs/how-to-run-in-production.md)).
- To write a WASM worker: a toolchain that produces a WASI 0.2 component, such as Rust with the
  `wasm32-wasip2` target ([how](docs/how-to-write-a-wasm-worker.md)).

Contributors: [how to build and test](docs/how-to-build-and-test.md).

## License

MIT; see [LICENSE](LICENSE).
