# Atanor

Atanor is a generic runtime on the BEAM, in the family of Cloudflare
`workerd`. It runs **workers** and the stateful **cells** they use across a
cluster of nodes, with compute and S3-compatible storage only. It is built on
Alambique, which provides the cells, and it knows no product, organization,
tenant or region.

**Status:** version <!-- x-release-please-start-version -->0.3.0<!-- x-release-please-end -->,
shipped as one daemon: a container image and a tarball ([install](#install)). The first
release, 0.1.0, is from 2026-11-06; [CHANGELOG.md](CHANGELOG.md) lists every release and
change. Open defects are in [docs/what-does-not-work.md](docs/what-does-not-work.md); the
limits of the design are in [Limitations](#limitations) and in [docs/design.md](docs/design.md).

## What it is for

Use Atanor to host many small tenants of one application: each tenant's data
lives in its own SQLite database (a cell) that is replicated to S3, wakes on
demand and sleeps when idle. Code is deployed as WebAssembly components, or as
native Elixir workers in a [derived image](docs/how-to-build-a-derived-image.md),
behind HTTP, WebSocket or TCP routes.

## Run it in 1 minute

You start one node over a local S3 (SeaweedFS), deploy a WASM worker to it and call it.
Everything runs in containers named `atanor-*`; the last step removes them.

You need Docker, `git`, `curl` and `openssl`, on Linux or macOS. Run the blocks in order, in one
shell, in an empty directory.

1. Name the image and fetch the example worker: a manifest and a compiled WASM component.

   ```sh
   export IMAGE=ghcr.io/this-is-npc/atanor:latest
   git clone --depth 1 https://github.com/This-Is-NPC/atanor.git atanor-src
   mkdir atanor-hello atanor-secrets
   cp atanor-src/examples/hello-wasm/atanor.json atanor-src/test/fixtures/wasm/hello.wasm atanor-hello/
   ```

2. Make the secrets: S3 keys, the admin token and the cookie that lets nodes join each other. The node
   reads them from files, so they do not show in `docker inspect`. The container runs as a user that
   is not you, so the files must be readable by everyone.

   ```sh
   for f in access_key secret_key admin_token cookie; do openssl rand -hex 24 | tr -d '\n' > atanor-secrets/$f; done
   chmod 755 atanor-secrets && chmod 644 atanor-secrets/*
   ```

3. Start SeaweedFS as the S3 store and create the bucket `atanor`.

   ```sh
   docker network create atanor-net
   docker run -d --name atanor-store --network atanor-net -p 127.0.0.1:8333:8333 \
     -v "$PWD/atanor-secrets:/run/secrets:ro" --entrypoint /bin/sh chrislusf/seaweedfs:4.48 -c \
     'export AWS_ACCESS_KEY_ID="$(cat /run/secrets/access_key)" AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/secret_key)"; \
      exec /entrypoint.sh mini -dir=/data -ip=atanor-store -ip.bind=0.0.0.0 -s3.port=8333 -admin.ui=false'
   until curl -s -o /dev/null http://127.0.0.1:8333/; do sleep 1; done
   curl -sS -o /dev/null -w 'create bucket: HTTP %{http_code}\n' --aws-sigv4 aws:amz:us-east-1:s3 \
     --user "$(cat atanor-secrets/access_key):$(cat atanor-secrets/secret_key)" -X PUT http://127.0.0.1:8333/atanor
   ```

   ```text
   create bucket: HTTP 200
   ```

4. Start one node and wait until it is ready. Port 4000 serves your workers; port 4001 is the
   admin API, which `/health/ready` answers with the admin token.

   ```sh
   docker run -d --name atanor-node --network atanor-net \
     -p 127.0.0.1:4000:4000 -p 127.0.0.1:4001:4001 -v "$PWD/atanor-secrets:/run/secrets:ro" \
     -e ATANOR_STORE=s3://atanor -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     -e ATANOR_ADMIN_TOKEN_FILE=/run/secrets/admin_token -e ATANOR_COOKIE_FILE=/run/secrets/cookie \
     -e ATANOR_ADVERTISE=atanor-node.local "$IMAGE"
   until [ "$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $(cat atanor-secrets/admin_token)" \
     http://127.0.0.1:4001/health/ready)" = 200 ]; do
     [ "$(docker inspect -f '{{.State.Running}}' atanor-node 2>/dev/null)" = true ] \
       || { docker logs atanor-node; echo "atanor-node is not running" >&2; break; }
     sleep 1
   done; docker ps -q -f name=atanor-node | grep -q . && echo ready
   ```

   ```text
   ready
   ```

   If the loop prints `atanor-node is not running` instead, read the log above it. A failed
   pull or a wrong `IMAGE` leaves no container to wait for. If a container was created, remove it with
   `docker rm -f atanor-node` before you run the step again.

5. Deploy the worker. The image holds the `atanor` command; `--bucket` writes the package into the
   bucket, and the node applies it at its next poll (at most 5 seconds).

   ```sh
   docker run --rm --network atanor-net -v "$PWD/atanor-secrets:/run/secrets:ro" -v "$PWD/atanor-hello:/w:ro" \
     -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     "$IMAGE" deploy /w --bucket s3://atanor --activate
   ```

   ```text
   package 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77 (hello, wasm, 181410 bytes)
   hello: active 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77, revision 1, previous none
   stored in s3://atanor; the nodes apply it at their next poll
   ```

6. Call it. The route of the manifest is the host `localhost` and the path `/hello`.

   ```sh
   until curl -sf -H 'Host: localhost' http://127.0.0.1:4000/hello/world; do sleep 1; done
   ```

   ```text
   hello GET /hello/world? authority=localhost body=
   ```

7. Remove everything this section created, the downloaded images included. If you use the SeaweedFS
   image for something else, leave out its name on the `docker rmi` line. `-v` also removes the
   anonymous volume that the SeaweedFS image declares.

   ```sh
   docker rm -fv atanor-node atanor-store && docker network rm atanor-net
   docker rmi "$IMAGE" chrislusf/seaweedfs:4.48
   rm -rf atanor-src atanor-hello atanor-secrets
   ```

Measured from a clean container with Docker on a laptop (linux/amd64, images already pulled), the
steps take 12.9 s in all: step 3 1.3 s, step 4 2.4 s, step 5 3.8 s, step 6 5.0 s (the node applies the new
deployment at its next poll). The times leave out the image pulls (the SeaweedFS image is about
725 MB). On a clean 2 vCPU, 3 GB virtual machine the first start of the node in step 4 took 38.6 s,
the next two 15.2 s and about 6.4 s, against 2.4 s on the laptop; the whole sequence took about 51 s
there, pulls excluded. The image is 55 MB to pull (compressed) and 224 MB on disk once
unpacked. The `package` id and the byte count in your output may differ.

From here: [deploy changes and roll back](docs/how-to-deploy-a-worker.md), [write your own WASM
worker](docs/how-to-write-a-wasm-worker.md), [run it in production](docs/how-to-run-in-production.md).

## Key concepts

| Concept | Meaning |
| --- | --- |
| Worker | A unit of code that handles requests. Stateless by itself. |
| Cell | A named stateful unit with its own SQLite: single owner, replicated to S3, wakes on demand, sleeps when idle. |
| Binding | A capability granted to a worker. The worker can use only what it was granted. |
| Deployment | An immutable version of a worker, identified by the hash of its package. |
| Route | Maps incoming traffic to a worker: a domain or path for HTTP, a port for TCP. |
| Job | A row in a cell's SQLite; runs on the cell owner, with retries, cron, unique keys and a dead-letter set. |
| Bulk operation | One job enqueued in many cells, throttled, resumable and idempotent per cell; with `undo`, the cells can be rewound to just before it. |
| Node | One daemon process. Nodes of a cluster share only the bucket and find each other through it. |

What it provides: WASM workers (and native ones in a derived image), HTTP, WebSocket and TCP ingress,
jobs and alarms, a change feed, bulk operations, a cluster with failover, worker rollouts and migration
rehearsal, an admin API, a CLI, telemetry and a read-only dashboard. The model is in
[docs/design.md](docs/design.md).

## Install

Atanor ships as one daemon, configured by `ATANOR_*` environment variables or a JSON file
([reference](docs/configuration.md#the-daemon-environment-and-file)).

- **Container image:** `ghcr.io/this-is-npc/atanor` (`:latest` or a version tag), for linux/amd64 and
  linux/arm64. It starts a node with no argument and runs the `atanor` command for `deploy`, `status`
  and the rest.
- **Tarball:** `atanor-<version>-linux-<arch>.tar.gz` on each GitHub release. It needs glibc 2.38 or later,
  OpenSSL 3.4 or later, `libstdc++6` and `libncurses6` ([details](docs/how-to-build-the-release.md#build-the-tarball)).
- **From source:** [how to build the image](docs/how-to-build-the-release.md).
- **Your own Elixir code beside a node** (Phoenix, LiveView, native workers): [build a derived
  image](docs/how-to-build-a-derived-image.md). Putting Atanor into an arbitrary application's
  supervision tree is not a supported way to install it.

## Interface

| What | Where |
| --- | --- |
| Your workers | HTTP and WebSocket on port 4000, TCP on the ports your manifests claim. |
| Operations | The admin API on port 4001, with a bearer token: health, deploys, tokens, jobs, drains ([how](docs/how-to-use-the-admin-api.md)). |
| Deploys | The `atanor` command, through a node or straight into the bucket ([reference](docs/cli.md)). |
| Dashboard | Read-only, on port 4002 when `ATANOR_DASHBOARD_TOKEN` is set ([how](docs/how-to-open-the-dashboard.md)). |
| Telemetry | `:telemetry` events and counters ([reference](docs/telemetry.md)). |

## Requirements

To run it:

- Docker, or a Linux host (amd64 or arm64) for the tarball.
- An S3-compatible store with conditional writes, and a bucket. Only SeaweedFS is tested; AWS
  credentials are read as the AWS SDKs do ([configuration](docs/configuration.md#aws-credentials)).
- For a cluster: a private network between the nodes, with the ports 4369 and 9100 to 9110 open
  ([production](docs/how-to-run-in-production.md)).
- To write a WASM worker: a toolchain that produces a WASI 0.2 component, such as Rust with the
  `wasm32-wasip2` target ([how](docs/how-to-write-a-wasm-worker.md)).

To develop Atanor ([how to build and test](docs/how-to-build-and-test.md)):

- `mise` and Docker. `mise.toml` pins Erlang 28.5, Elixir 1.20.4 and Rust 1.97.1.
- A C compiler: Alambique and `native/atanor_wasm` (Wasmtime) compile native libraries, and WASM
  guests need the `wasm32-wasip2` target.
- Alambique, fetched from its public git repository at the release tag in `alambique.ref`.
- Optional: Ranch for `protocol: :ranch` listeners, and Phoenix with four extra dependencies for the
  dashboard when you build the library yourself. The daemon image holds both.
- Optional, for the end-to-end OIDC test only: set `MAESTRO_TESTKIT` to a checkout of the Maestro testkit.

## Limitations

- WASM workers cannot serve TCP yet, and cannot read the change feed
  ([design §14.8](docs/design.md#148-alarms-sockets-and-what-is-left-out)).
- Discovery trusts the bucket: whoever can write `<prefix>/nodes/` decides whom the
  nodes dial, so write access to the bucket must be as trusted as the cluster
  ([discovery](docs/configuration.md#discovery)).
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

- [Run it in production](docs/how-to-run-in-production.md): balancer, TLS, private network, credentials.
- [Deploy a worker](docs/how-to-deploy-a-worker.md) with the `atanor` command, through a node or straight into the bucket ([reference](docs/cli.md)).
- [Write a WASM worker](docs/how-to-write-a-wasm-worker.md), or [a native one](docs/how-to-write-a-native-worker.md).
- [Configure a node](docs/configuration.md).
- [Run a cluster](docs/how-to-run-a-cluster.md).
- [Build a derived image](docs/how-to-build-a-derived-image.md) with your Elixir code, Phoenix and LiveView included, in the same VM as the node.
- [Open the dashboard](docs/how-to-open-the-dashboard.md) and [read the telemetry](docs/telemetry.md).
- [Design](docs/design.md) and [build and test](docs/how-to-build-and-test.md), for contributors.
- [Changelog](CHANGELOG.md).

## License

MIT; see [LICENSE](LICENSE).
