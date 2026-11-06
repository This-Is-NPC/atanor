# Atanor documentation

| Page | Question it answers |
| --- | --- |
| [design.md](design.md) | How is Atanor built: model, processes, bindings, storage layout, guarantees? |
| [configuration.md](configuration.md) | Which options does an instance take, and what do they bound? |
| [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md) | How do I write a native worker, give it a cell, and run it locally? |
| [how-to-write-a-wasm-worker.md](how-to-write-a-wasm-worker.md) | How do I write a worker as a WebAssembly component and run it locally? |
| [how-to-serve-tcp.md](how-to-serve-tcp.md) | How do I speak a TCP protocol from a worker, bind a connection to a cell, and serve it over TLS, STARTTLS or a Ranch protocol such as gen_smtp? |
| [how-to-use-websockets.md](how-to-use-websockets.md) | How do I accept WebSockets and push to the sockets attached to a cell? |
| [how-to-share-ephemeral-messages.md](how-to-share-ephemeral-messages.md) | How do I send cursors, presence and signals to every socket of a cell, on any node, without writing to the cell or calling its owner? |
| [how-to-use-alarms.md](how-to-use-alarms.md) | How do I run code in a cell at a later time? |
| [how-to-follow-cell-changes.md](how-to-follow-cell-changes.md) | How does a native worker read or follow the change feed of a granted namespace without waking its cells? |
| [how-to-use-jobs.md](how-to-use-jobs.md) | How do I run work later in a cell, retry it, and make its effects idempotent? |
| [how-to-measure-job-round-trips.md](how-to-measure-job-round-trips.md) | How many requests does the store receive for each job, of which kind, and how many jobs a second does one cell finish when the store is slow? |
| [how-to-run-a-bulk-operation.md](how-to-run-a-bulk-operation.md) | How do I run the same job across many cells, throttled, guarded and resumable, and see what it changed? |
| [how-to-protect-a-route-with-oidc.md](how-to-protect-a-route-with-oidc.md) | How do I require a valid OIDC access token on a route, with any provider, and read its claims in the worker? |
| [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) | How do I upload a new version with a scoped token, switch nodes to it, and roll back, without holding the bucket credentials? |
| [cli.md](cli.md) | Which commands, options, environment variables and errors does the `atanor` command have? |
| [openapi/admin.json](openapi/admin.json) | What is the contract of the admin API endpoints for deploys, tokens and the audit log (OpenAPI 3.1)? |
| [how-to-run-a-migration-rehearsal.md](how-to-run-a-migration-rehearsal.md) | How do I check that a new package's migrations apply to copies of my real cells before I activate it? |
| [how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md) | How do I find the core dump and the work a node was running when it died, and what do the crash reports and quarantine mean? |
| [how-to-run-a-cluster.md](how-to-run-a-cluster.md) | How do I run Atanor on several nodes, see requests follow their cells, see what a node failure does (and how fast its cells move), tune the failure detector and takeover, stop a node without errors and tell Atanor that a node is gone? |
| [how-to-place-hot-cells.md](how-to-place-hot-cells.md) | How do I let a very busy cell move to a less loaded or a dedicated node by itself, see why it did or did not, and tune it so that it does not keep moving? |
| [how-to-read-from-replicas.md](how-to-read-from-replicas.md) | How do I serve the reads of a very busy cell on every node, accepting data a little old, from a replica, and let the cell get its replicas by itself? |
| [how-to-partition-a-cell.md](how-to-partition-a-cell.md) | How do I spread a very busy cell over several partitions that have a writer each, route requests to the right one, and read across them? |
| [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md) | How do I run Atanor in Docker containers over their own SeaweedFS and a load balancer, deploy an app with a scoped token, kill, pause, partition or restart a node or the store, and measure what a fault or a rollout costs under load? |
| [operating-a-cluster-compared.md](operating-a-cluster-compared.md) | What did running the scoreboard on the container cluster take from an operator, and how does it compare with an app server, Postgres, a queue and Redis: what is simpler, harder or missing? |
| [how-to-run-the-cluster-lab.md](how-to-run-the-cluster-lab.md) | How do I run Atanor on three VMs over one SeaweedFS, break them on purpose, and measure what clients see? |
| [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) | How do I see workers, deployments, routes, live cells and the state of the peers of my nodes, control jobs and bulk operations, say that a node is gone, and deploy with scoped tokens and an audit log? |
| [how-to-open-the-dashboard.md](how-to-open-the-dashboard.md) | How do I open the read-only dashboard and see workers, deployments, routes, cells, alarms and metrics? |
| [screens.md](screens.md) | What does each dashboard page show, and how do I move between them? |
| [telemetry.md](telemetry.md) | Which telemetry events and native counters does Atanor emit? |
| [what-does-not-work.md](what-does-not-work.md) | Which defects and limits are known and still open, and what do I do about them? |
| [properties.md](properties.md) | Which rules have property tests, what does each prove, and which rules are left to example tests? |
| [how-to-build-and-test.md](how-to-build-and-test.md) | How do I build Atanor from source, run a local node, and run the tests and benchmarks? |
| [how-to-measure-test-coverage.md](how-to-measure-test-coverage.md) | How do I measure which production lines the tests run, in Elixir and Rust, and what is left out of the count? |
| [how-to-update-alambique.md](how-to-update-alambique.md) | How do I move Atanor to a new Alambique release, and why is it pinned? |
| [prior-art.md](prior-art.md) | What do workerd, celld, Spin and wasmCloud do, and which choices did Atanor make? |

Recommended path: the [README](../README.md), the worker how-tos (native or WASM) and `configuration.md`, then TCP, WebSockets (and ephemeral messages for them), alarms, the change feed, jobs and bulk operations, then protecting a route with OIDC, deploying a worker with the `atanor` command (reference in `cli.md`; and rehearsing its migrations), running a cluster (placing its hot cells, reading them from replicas, partitioning a cell that one writer cannot serve, the cluster in containers, what operating it takes compared with a classic stack, and the cluster lab), then the admin API, the dashboard and `telemetry.md`.

Contributors continue with `how-to-build-and-test.md`, then `design.md` sections 1 to 5, then 7, 8, 15, 16, 17, 18 and 19, and `prior-art.md` before reading the worker and binding formats. Read `what-does-not-work.md` before relying on a guarantee.
