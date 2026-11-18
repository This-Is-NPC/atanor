# How to build and test Atanor

**The question:** How do I build Atanor from source, run it on a development
machine, and run its tests and benchmarks?

This guide stands alone. It is for contributors. Install the tools in
`mise.toml` with `mise install`; the [README](../README.md#requirements) lists
the requirements. The rules for changes are in [AGENTS.md](../AGENTS.md). Docker is needed only
for the SeaweedFS tests and `--store seaweedfs`; the cluster lab needs KVM,
libvirt, `virt-install`, `xorriso` and about 14 GB of free RAM
([lab guide](how-to-run-the-cluster-lab.md)).

The Rust NIF (`native/atanor_wasm`, with wasmtime) is the slow part of a build. Outside CI, `mise.toml` shares
it between every checkout and worktree of the machine:

- `CARGO_TARGET_DIR` is `~/.cache/atanor/cargo-target`. Cargo locks it, so two builds at once queue
  ("Blocking waiting for file lock") instead of compiling wasmtime twice.
- `ATANOR_NIF_CACHE` is `~/.cache/atanor/nif`. A built `atanor_wasm.so` is kept there under a hash of
  the crate's `Cargo.toml`, `Cargo.lock`, `src/` and `wit/` and of the Rust pin. A checkout whose crate has
  that hash copies it into `priv/native/` and runs no cargo at all. A change under `native/atanor_wasm`
  changes the hash and builds again.

Measured on the development laptop, 2026-11-18: a new worktree with the shared target already built
compiled the NIF in 13 s; with the NIF in the cache, the compile of `Atanor.Wasm.Native` ran no cargo and
took under a second. CI keeps the in-tree target that it caches, and has no NIF cache; `mise run
test:coverage` always builds the instrumented NIF. Remove `~/.cache/atanor` to start over.

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
mise run check:fast      # warnings as errors and formatting, what pre-push runs
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
mise run load -- --config load/rounds/example.toml --dry-run   # load test: print the plan of a round, start nothing (how-to-run-the-load-tests.md)
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

## Run the gate

CI is the merge gate. `master` requires the check `ci` of the workflow
`.github/workflows/ci.yml`, which runs on every pull request to `master` and on
every push to `master`. A new push to a pull request cancels its older run.
The release pull request is opened by release-please with the workflow token,
which starts no pull_request run, so its `ci` check comes from a run that
`release.yml` dispatches on the release branch. To dispatch it by hand:
`gh workflow run ci.yml --repo This-Is-NPC/atanor --ref <release-branch>`.
The pre-push hook runs only the fast checks, so a loaded machine does not
block a push.

```sh
mise run hooks:install   # sets core.hooksPath to .githooks (once per clone)
mise run check:fast      # what pre-push runs: warnings as errors and formatting
mise run check           # the quick gate of CI, on this machine
```

The jobs of the workflow, each a mise task:

| Job | Runs |
| --- | --- |
| `static` | `check:compile` (test and dev with warnings as errors), `check:format`, `check:links`, `check:workflows` |
| `plan` | `scripts/ci-coverage-matrix`: lists the parts below from the two partition counts |
| `part` (one job each) | `mise run test:coverage --no-report ...`: `native` (Rust unit tests), `seaweedfs` (against a disposable SeaweedFS in Docker; the runner has Docker), `unit-1` to `unit-U` (the quick suite) and `cluster-1` to `cluster-C` (the tests on peer nodes). Each part uploads its coverage as an artifact and fails only when a test fails |
| `coverage` | downloads the artifacts and runs `mise run test:coverage --report-only`: merges them and fails below 90% line coverage of `lib/` or the Rust crate |
| `ci` | waits for the others and fails unless all passed; the only check branch protection needs |

Each test runs once, inside coverage, so CI has no separate `mise run test`,
`test:cluster`, `test:native` or `test:seaweedfs` job. The unit and cluster
suites are split with ExUnit partitions: every part gets a share of the test
files (round-robin over the sorted file list), so the parts take about the same
time. A failing part shows the test name and the seed in its log.

The tools come from `mise.toml`. The caches of `deps`, `_build`, the cargo
target and the cargo registry are keyed on `mise.toml`, `mix.lock`,
`alambique.ref` and `native/atanor_wasm/Cargo.lock`. Every action is pinned by
commit SHA.

Repository variables (Settings, Secrets and variables, Actions, Variables)
tune a run; each has a default:

| Variable | Default | Meaning |
| --- | --- | --- |
| `ATANOR_CI_TIMEOUT_STATIC`, `_PART`, `_COVERAGE` | 20, 30, 15 | Timeout of each `static` job, each `part` job and the `coverage` job, in minutes. |
| `ATANOR_CI_UNIT_PARTS` | `3` | Number of unit parts (ExUnit partitions). |
| `ATANOR_CI_CLUSTER_PARTS` | `6` | Number of cluster parts. The cluster suite is the longest: raise this first when a run is slow. |
| `ATANOR_TEST_MAX_CASES` | empty (ExUnit's default, twice the cores) | Test modules run at once; the same variable works locally. |
| `ATANOR_COVERAGE_THRESHOLD` | `90` | Minimum line coverage per language, in percent. |

To run one part on your machine, pass the same arguments the job does (the
instrumented build takes a few minutes the first time):

```sh
mise run test:coverage --no-report --partition 2/6 cluster   # cluster-2 of 6
mise run test:coverage --no-report native                    # the native part
mise run test:coverage --report-only                         # merge what is in cover/
```

Coverage, the cluster suite and SeaweedFS also run locally on demand, for
example `mise run test:coverage` (all of it, about 30 minutes) to find what
lowered the coverage, or `mise run test:cluster` for the cluster tests alone.
The benchmarks,
the load tests, the container cluster, the image smoke tests and the lab are
never in CI: they measure a machine or need KVM, libvirt or privileged
containers.

`mise run check` runs, in order: `mix compile --warnings-as-errors` in the
test and dev environments (forced, so old warnings show), `mix format
--check-formatted` and `cargo fmt --check` for each Rust crate
(`mise run check:format`), the link and anchor check of the tracked Markdown
files (`mise run check:links`), and the quick suite (`mise run test`). It
stops at the first failure. Two optional stages are off by default:

- `ATANOR_CHECK_CLUSTER=1` adds `mise run test:cluster`.
- `ATANOR_CHECK_COVERAGE=1` adds `mise run test:coverage` (about 30 minutes).

`mise run check` keeps the full output of every stage, including the `mix
test` failures and the ExUnit seed, in `_build/check/check-<UTC stamp>-<pid>.log`
(git ignores `_build`). `_build/check/last.log` links to the newest. A red run
ends by printing the failing tests, the test counts, the seed and the log path,
so the last 15 lines are enough to name the failure. Only the newest 10 logs
stay; set `ATANOR_CHECK_LOG_KEEP=<n>` to change that. `scripts/check-log
<command>` does the same for any command.

The hooks:

- `pre-commit` runs only `mise run check:format`.
- `pre-push` runs `mise run check:fast` once per push. A red check refuses the
  push. Tag pushes and deletions pass. `git commit --no-verify` and `git push
  --no-verify` skip the hooks.

`mise run local-check` is for manual use. It runs `mise run check` on a clean
HEAD that is already pushed and posts a `local-check` commit status with `gh`.
`master` no longer requires that status; CI does the gating. `--dry-run` prints
the API calls. It keeps the gate output in `_build/local-check.log` and, for a
red gate, in `_build/local-check-failed-<UTC stamp>.log` (newest 10; set
`ATANOR_LOCAL_CHECK_KEEP_FAILED=<n>` to change it).

## Releases

Releases are cut by [release-please](https://github.com/googleapis/release-please)
from the Conventional Commits on `master` (`.github/workflows/release.yml`).
Each push to `master` updates a release pull request with the next version and
its `CHANGELOG.md` entry. Merging that pull request tags `vX.Y.Z` and publishes
the GitHub release. Before 1.0, `feat` bumps the minor version and `fix` the
patch. The version lives in `mix.exs`, `testkit/mix.exs` and `daemon/mix.exs`. The same
workflow then builds the image and the tarballs ([how-to-build-the-release.md](how-to-build-the-release.md)). The Rust crates
are internal and keep their own version.

## Next steps

- [how-to-measure-test-coverage.md](how-to-measure-test-coverage.md) for the coverage gate.
- [properties.md](properties.md) for the property tests.
- [how-to-update-alambique.md](how-to-update-alambique.md) to move the Alambique release.
- [design.md](design.md) for the architecture.
