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

## Run the gate before you push

`master` requires the commit status `local-check`. Nothing on GitHub runs the
gate; your machine does, and posts the status.

```sh
mise run hooks:install   # sets core.hooksPath to .githooks (once per clone)
mise run check           # the gate
```

`mise run check` runs, in order: `mix compile --warnings-as-errors` in the
test and dev environments (forced, so old warnings show), `mix format
--check-formatted` and `cargo fmt --check` for each Rust crate
(`mise run check:format`), the link and anchor check of the tracked Markdown
files (`mise run check:links`), and the quick suite (`mise run test`). It
stops at the first failure. Two optional stages are off by default:

- `ATANOR_CHECK_CLUSTER=1` adds `mise run test:cluster`.
- `ATANOR_CHECK_COVERAGE=1` adds `mise run test:coverage` (about 30 minutes).

The hooks:

- `pre-commit` runs only `mise run check:format`.
- `pre-push` runs the gate on each pushed commit. A red gate refuses the
  push. A green one posts `local-check` as `success` once GitHub has the commit.
  Tag pushes and deletions pass.

The hook and `mise run local-check` also save the full gate output to
`_build/local-check.log`, which git ignores. Each run overwrites it, and a red
gate prints its path. Read it to find the failing test after the terminal
output is gone.

The status is posted with `gh`, so it needs `gh auth login`. Without it the
gate still runs and the push goes through, but `master` will refuse the merge.
The gate vouches only for a clean checkout of the pushed commit.

The pull request that release-please opens is pushed by a bot. Check out its
branch, run `mise run check`, then post the status for that commit:

```sh
scripts/local-check --post-only --state=success --sha=<commit of the PR head>
```

`--dry-run` prints the API calls instead of sending them. To skip on purpose
set `ATANOR_SKIP_LOCAL_CHECK=1` (for example `ATANOR_SKIP_LOCAL_CHECK=1 git
push`); no status is posted, so `master` still refuses the merge until an
administrator bypasses the rule or you post one. `git commit --no-verify` and
`git push --no-verify` skip the hooks.

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
