# How to build the release

**The question:** How do I build the Atanor daemon as a container image or a
tarball, check that the image works, and know what a release publishes and what
the tarball needs on the host?

This guide stands alone for someone with the repository and Docker. To run
the image you built as a cluster, see
[how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md);
for the settings of a node, [configuration.md](configuration.md#the-daemon-environment-and-file);
for the design, [design.md §17.4](design.md#174-the-release-as-the-product-artifact).

## What you get

The product is a Mix release named `atanor`, built from [daemon](../daemon): the
Erlang runtime, both native libraries (`atanor_wasm.so` and `alambique_nif.so`)
and the dashboard. It starts one node from environment variables and runs
WASM workers. It holds no worker of yours.

The [Dockerfile](../Dockerfile) at the root builds it from public sources only
(Hex, crates.io and the git tag of Alambique in `alambique.ref`). Its targets:

| Target | What it is |
| --- | --- |
| `runtime` | The product image, and the default target. A Debian slim base with libssl3, libstdc++6, libncurses6 and ca-certificates. No `curl`, no `iptables`. Runs as the user `atanor` (uid 10001). |
| `harness` | `runtime` plus `curl`, `iproute2`, `iptables` and `procps`: what the faults, `tc` and the healthchecks of [cluster/](../cluster/compose.yml) use. |
| `artifact` | A scratch image that holds only the release directory, for the tarball. |

## Prerequisites

- Docker with BuildKit (Docker 23 or later). Nothing else: Elixir, Erlang and
  Rust are inside the build stage.
- Internet for the first build. The Rust build of both NIFs dominates it
  ([measured below](#what-it-costs)).
- To run the check below, `mise install` (for `mise run`), plus `curl` and `openssl` on the host.

## Build the image

1. From the repository root:

   ```sh
   docker build --target runtime -t atanor:local .
   ```

   To build the harness image, use `--target harness`. Build arguments: `RELEASE_ID`
   (the id the node reports at `GET /deployments`; default `atanor-<version>`) and
   `CARGO_BUILD_JOBS`.

2. Start a node. It needs a store, a cookie and an address the other nodes
   reach it at; all of them are environment variables
   ([the reference](configuration.md#the-daemon-environment-and-file)). Secrets
   are read from files with the `*_FILE` variables, so they do not show in
   `docker inspect`. `<...>` marks a value you choose:

   ```sh
   docker run -d --name atanor-1 \
     -v <secrets dir>:/run/secrets:ro \
     -e ATANOR_STORE=s3://<bucket>/<prefix> \
     -e ATANOR_S3_ENDPOINT=<S3 endpoint URL> \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key \
     -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     -e ATANOR_ADMIN_TOKEN_FILE=/run/secrets/admin_token \
     -e ATANOR_ADVERTISE=<host or IP with a dot, such as node-1.example> \
     -e ATANOR_COOKIE_FILE=/run/secrets/cookie \
     atanor:local
   ```

   The node is ready when `GET /health/ready` on the admin port (4001) answers 200
   with the admin token. Without a cookie, or with an `ATANOR_` variable the
   daemon does not know, it stops at once and says why in its log.

## Check the image

`mise run image:smoke` builds the `runtime` and `harness` targets and checks, against a
disposable SeaweedFS (all its containers and its network are named `atanor-smoke-*`
and removed at the end):

- a node started with environment variables only is ready on `/health/ready`;
- it refuses to start without a cookie, and on an unknown `ATANOR_` variable, with the reason in the log;
- the runtime image has no `curl` and no `iptables`, and runs as a user that is not root;
- the harness image has `curl`, `iptables`, `tc` and `ps`.

It prints the image sizes, the build times and the time from `docker run` to ready.
`ATANOR_SMOKE_REUSE=1` skips the builds and uses the images of the last run.

```text
SMOKE_OUTPUT
```

## Build the tarball

The same release, without the image, as a directory:

```sh
docker build --target artifact --output type=local,dest=out .
tar --owner=0 --group=0 -C out -czf atanor-<version>-linux-<arch>.tar.gz atanor
```

Unpack it anywhere. `atanor/bin/atanor start` starts the node, with the same
environment variables as the image, and `atanor/bin/atanor remote` attaches to a running one.
Set the cookie with `RELEASE_COOKIE` or `ATANOR_COOKIE_FILE`, as for the image.

**What the tarball needs on the host.** It is built in the Debian 13 (trixie)
base of the image, and its native code links that base's libraries. The host
needs glibc and OpenSSL at least as new as Debian 13 has (glibc LIBC_VERSION,
OpenSSL 3), `libstdc++6` and `libncurses6`. It does not run on musl (Alpine) or on an
older distribution; use the image there. It does not need Erlang, Elixir or Rust.

## What a release publishes

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs on every push to
`master`. release-please opens or updates the release pull request; when the owner
merges it, release-please creates the tag and the GitHub Release (`release_created`),
and then:

1. `build` runs twice, on native runners (`ubuntu-latest` for amd64,
   `ubuntu-24.04-arm` for arm64, no emulation). Each pushes its `runtime` image
   to `ghcr.io/this-is-npc/atanor` by digest and packs
   `atanor-<version>-linux-<arch>.tar.gz` (with a `.sha256` file).
2. `manifest` creates the manifest list `ghcr.io/this-is-npc/atanor:<version>` and `:latest`
   from the two digests.
3. `attach-tarballs` attaches the tarballs to the GitHub Release.

The workflow has no test job: the gate is local (`mise run check`). Every action is
pinned by commit SHA, the default token is read-only, and `packages: write` and
`contents: write` are given only to the jobs that push images and attach files. The
build cache is the GitHub Actions cache (`type=gha`), one scope per architecture.
`mise run check:workflows` lints it with `actionlint`. The arm64 build is not made
locally: the first release run is its proof.

## What it costs

MEASUREMENTS

## Troubleshooting

- **The build stops with a git error.** `mix deps.get` clones Alambique at the tag in
  `alambique.ref`. Check the network, and that the tag is published.
- **The Rust build runs out of memory.** Pass fewer jobs:
  `docker build --build-arg CARGO_BUILD_JOBS=2 ...`.
- **The node exits at once.** Read `docker logs`: a missing cookie, an unknown variable or
  an invalid setting is named there.
- **The node starts but another node cannot reach it.** `ATANOR_ADVERTISE` must be a
  name or an address the other nodes resolve, and the ports 4369 and 9100 to 9110 must be open between them.

## Next steps

- [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md) runs
  several nodes of the harness image over SeaweedFS.
- [configuration.md](configuration.md#the-daemon-environment-and-file) lists every variable.
- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) deploys a worker to a running node.
