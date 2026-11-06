# Changelog

## 0.1.0 (2026-11-05)

First release.

### Features

* **cells:** a named stateful cell per tenant, with its own SQLite, a single owner, replication to S3, wake on demand and sleep when idle; migrations per namespace; partitioned cells for namespaces that one writer cannot serve; limits on statements, awake cells and local files, and a memory budget that hibernates the least used cells
* **workers:** native Elixir workers and WebAssembly components (`wasi:http`, run by Wasmtime through an own NIF with CPU, memory and wall-clock limits), with manifests and grant-checked bindings: cells, secrets, outbound HTTP and calls to other workers
* **ingress:** HTTP routing by host and path, WebSockets attached to cells, ephemeral channels for cursors and presence, raw TCP listeners with routing keys, TLS and STARTTLS with reloadable certificates, Ranch protocol listeners (gen_smtp, for example), and OIDC access tokens required per route
* **jobs:** jobs and alarms per cell, with retries, cron, unique keys, a dead-letter set and idempotent effects; native and WASM workers alike
* **feed:** a change feed per namespace that native workers read by page or subscribe to without waking cells, at least once, with grouped objects, table selection and compressed objects
* **sweeps:** bulk operations that enqueue one job in many cells, throttled, guarded and resumable, with an undo that reports and rewinds the cells
* **cluster:** routing of every request to the owner of its cell, a phi accrual failure detector, takeover with leases and epoch fencing, graceful stop, a platform hint that a node is gone, automatic placement of hot cells, bounded reads from replicas, and failover in milliseconds for a killed process and seconds for a lost machine
* **deploy:** deployments by package hash, the `atanor` command (deploy, activate, rollback) through an admin API with scoped tokens and an audit log, and migration rehearsals on copies of sampled cells
* **observe:** telemetry per worker, deployment and cell, an admin API for workers, deployments, routes, live cells and peers, crash reports that name the job or operation that died, and an optional read-only dashboard
* **dev:** `mix atanor.dev` for a local node over an in-memory store, the `atanor_testkit` helpers (nodes, clusters with fault injection) and runnable examples
* **lab:** a cluster of three VMs over one SeaweedFS and a Docker Compose cluster, both with fault injection, and benchmarks for the main costs

### Miscellaneous

* **license:** MIT
