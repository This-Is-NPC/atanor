# How to build and test Atanor

**The question:** How do I build Atanor from source, run it on a development
machine, and run its tests and benchmarks?

This guide stands alone. It is for contributors. Install the tools in
`mise.toml` with `mise install`; the [README](../README.md#requirements) lists
the requirements. The rules for changes are in [AGENTS.md](../AGENTS.md). Docker is needed only
for the SeaweedFS tests and `--store seaweedfs`; the cluster lab needs KVM,
libvirt, `virt-install`, `xorriso` and about 14 GB of free RAM
([lab guide](how-to-run-the-cluster-lab.md)).

## Run a local node

```sh
mise run dev -- --port 4000
```

```text
Atanor listening on http://127.0.0.1:4000
```

The node uses the in-memory store of the alambique test kit, so nothing
survives a restart and only this VM can reach it. `--store seaweedfs` uses
the bucket `atanor-dev` of a local SeaweedFS after `mise run seaweedfs:up`.
With `--admin-port` and `--admin-token` the `atanor` command can switch the
node's workers ([how-to-deploy-a-worker.md](how-to-deploy-a-worker.md)).
`--data-dir` sets the directory for the local copies of cells. `--admin-port` and `--admin-token` start the admin API, `--dashboard-port`, `--dashboard-token` and `--no-dashboard` set the dashboard (it starts on 4002 with a random token when your project has its dependencies), and `--connect NODE` joins other
nodes ([how to run a cluster](how-to-run-a-cluster.md)). The node
deploys the workers of `./atanor.json`, or of each `--manifest FILE`, and
prints their routes. Without manifests every request
gets a 404:

```text
$ curl -i http://127.0.0.1:4000/x
HTTP/1.1 404 Not Found
content-type: application/json; charset=utf-8

{"error":"not_found"}
```

[examples/hello-native](../examples/hello-native) is a runnable worker project
(HTTP, a WebSocket and an alarm): `cd examples/hello-native && mise exec -- mix
atanor.dev`. [examples/echo-tcp](../examples/echo-tcp) serves a line protocol:
`mise exec -- mix atanor.dev --listener visits=2525`.

## Run the checks and benchmarks

```sh
mise run test            # default suite, no external services
mise run build:cli         # the atanor command, into _build/cli/atanor (cli.md)
mise run test:cluster    # properties and tests on peer nodes (about 2 minutes; needs epmd)
mise run check:no-phoenix  # compile and run examples/hello-native, which has no Phoenix
mise run docs:dashboard-screenshots  # regenerate docs/img (needs Playwright)
mise run test:native     # Rust unit tests of the WASM library
mise run test:coverage   # line coverage of lib/ and the Rust crate over all test runs; fails below 90% each (about 30 minutes)
mise run build:wasm-fixtures  # rebuild the test guests in test/fixtures/wasm
mise run bench:wasm      # WASM measurements (design 12.1)
mise run bench:http      # requests/s and latency of native and WASM workers (12.2)
mise run bench:cells     # thousands of cells per node through Atanor (12.3)
mise run bench:fetch     # latency of sequential outbound HTTP fetches (4)
mise run bench:jobs      # enqueue, job execution and bulk-operation throughput (12.9)
mise run bench:job-trips # store requests per job and jobs/s in one cell with added store latency (12.13)
mise run bench:cluster   # forwarded against local requests on three nodes (12.4)
mise run bench:micro     # ns per call of the per-request and per-job costs (12.14)
mise run bench:feed      # time for a change feed subscriber to receive a burst (12.14)
mise run bench:idle-polls  # store reads of an idle node polling finished sweeps (12.14)
mise run bench:hot-cell-tail  # latency tail of one hot cell over a slow store (12.14)
mise run bench:auth      # cost of verifying a bearer token (12.14)
mise run bench:detector  # time to detect a lost node and to serve its cells again, heartbeat cost (12.7)
mise run lab:up          # cluster lab: three KVM VMs and a SeaweedFS VM (needs libvirt; see the lab guide)
mise run lab:test        # every lab scenario, about 90 minutes; results in lab/results/
mise run lab:down        # remove the lab VMs, disks and network
mise run dev             # single local node
mise run test:seaweedfs  # tests tagged seaweedfs, against a disposable SeaweedFS
mise run seaweedfs:down  # remove the SeaweedFS container
```

`check:no-phoenix` builds the example's dependencies before starting it;
`ATANOR_CHECK_START_TIMEOUT_MS` (milliseconds, default 20 000) bounds the
start wait.

`testkit/` holds `atanor_testkit`; its sources are compiled into the test
build, with the worker modules for tests in `test/support/`.
`AtanorTestkit.Node.start/1` starts an instance over a memory store with a
temporary data directory and an ephemeral port; `stop/1` removes it.
`AtanorTestkit.Cluster` starts peer nodes over one store, with fault injection
(kills, partitions of the store and of the distribution, clock skew); the tests
that use it are tagged `cluster` and run with `mise run test:cluster`.

## Releases

Releases are cut by [release-please](https://github.com/googleapis/release-please)
from the Conventional Commits on `master` (`.github/workflows/release.yml`).
Each push to `master` updates a release pull request with the next version and
its `CHANGELOG.md` entry. Merging that pull request tags `vX.Y.Z` and publishes
the GitHub release. Before 1.0, `feat` bumps the minor version and `fix` the
patch. The version lives in `mix.exs` and `testkit/mix.exs`. The Rust crates
are internal and keep their own version.

## Next steps

- [how-to-measure-test-coverage.md](how-to-measure-test-coverage.md) for the coverage gate.
- [properties.md](properties.md) for the property tests.
- [how-to-update-alambique.md](how-to-update-alambique.md) to move the Alambique release.
- [design.md](design.md) for the architecture.
