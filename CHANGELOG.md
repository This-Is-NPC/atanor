# Changelog

## [0.3.0](https://github.com/This-Is-NPC/atanor/compare/v0.2.0...v0.3.0) (2026-11-11)


### Features

* **config:** accept the new alambique limit keys ([f8269ef](https://github.com/This-Is-NPC/atanor/commit/f8269ef873cc2c59fdc17a86ffadf0d7fc380d9f))


### Bug Fixes

* **admin:** limit failed token attempts per address ([a07c09c](https://github.com/This-Is-NPC/atanor/commit/a07c09cd3dcd7f8ed15b3bf5aa730709bed4f8b6))
* **detector:** hear a peer through bytes on a busy link ([94d0299](https://github.com/This-Is-NPC/atanor/commit/94d02996c0cd1896a77563fed3acc44bdd3bc6ab))
* **env:** pin nested worker calls to one deployment ([d79a18d](https://github.com/This-Is-NPC/atanor/commit/d79a18dde0403387cd8dde968284472dc2e3fcfb))
* **feed:** report a feed read timeout as a store error ([5d333aa](https://github.com/This-Is-NPC/atanor/commit/5d333aa6fb3dcf7185e3caa831dfc6d14e80abbb))
* **start:** log why a data_dir is refused ([ab6522e](https://github.com/This-Is-NPC/atanor/commit/ab6522eb6730efde835a3365c8a15c74330650f0))
* **sweeps:** page the undo table hash ([4579ffc](https://github.com/This-Is-NPC/atanor/commit/4579ffccab3673fe4c0433c50149a54289683811))
* **sweeps:** read undo tables without a row cursor ([d762fe4](https://github.com/This-Is-NPC/atanor/commit/d762fe4b9df80e7e271c4fd7408a241ee928c28c))
* **takeover:** rate-limit no_quorum events ([46598fc](https://github.com/This-Is-NPC/atanor/commit/46598fc4b301c28eaf9b521c9277fa126dc3b4c4))
* **wasm:** cap batch results and cell messages ([40a55b0](https://github.com/This-Is-NPC/atanor/commit/40a55b03a6fb8517cbb4d694c0a0783fb4d255ab))
* **wasm:** compile off the dirty schedulers ([7d62aaa](https://github.com/This-Is-NPC/atanor/commit/7d62aaa14bd885eaf29069c43a1e135957bf6626))
* **wasm:** decode large host replies on a dirty nif ([2fca06c](https://github.com/This-Is-NPC/atanor/commit/2fca06cd4c6c4234e016e429828bae65bf15f756))
* **wasm:** free the right to run while a guest waits ([36dc2e5](https://github.com/This-Is-NPC/atanor/commit/36dc2e59215e8b6154a8298b2f0af3817a38c9b3))
* **wasm:** name the settings when pooling fails ([623c5e5](https://github.com/This-Is-NPC/atanor/commit/623c5e5f9abe9e97e622dfb79ebf66afb2c8e432))


### Performance Improvements

* **env:** pin ids of nested callees, not deployments ([dc92858](https://github.com/This-Is-NPC/atanor/commit/dc928589515cd3ea33b4d9da2deecf3a3e9531c3))
* **wasm:** wake one idle pool thread per job ([3c15a15](https://github.com/This-Is-NPC/atanor/commit/3c15a15c0f2b4d730ea866ce113a4dd568572d14))

## [0.2.0](https://github.com/This-Is-NPC/atanor/compare/v0.1.0...v0.2.0) (2026-11-11)


### Features

* **auth:** flush the OIDC key cache from the admin API ([dce59ab](https://github.com/This-Is-NPC/atanor/commit/dce59ab2de7c97c886f6db02c94c0afd614a78fa))
* **cluster:** allow nodes with no peers ([4d95753](https://github.com/This-Is-NPC/atanor/commit/4d95753fa58ccdbe4e0a3d0c4dd556b2637b3c63))
* **drain:** drain a node on demand or on sigterm ([ef82294](https://github.com/This-Is-NPC/atanor/commit/ef822945b612b81d5be3781eda653e563fe08cbc))
* **drain:** report the progress of a running drain ([767379a](https://github.com/This-Is-NPC/atanor/commit/767379a2cda1b975cc3aeece75236358aea87da7))
* **http:** answer draining and held_elsewhere 503s ([e49991c](https://github.com/This-Is-NPC/atanor/commit/e49991c159a914a189d98efa64aa294204aea384))
* **jobs:** release claims when a node drains ([ca040db](https://github.com/This-Is-NPC/atanor/commit/ca040dbb7e90ff91f897c9950aa5a8cb873f4a01))


### Bug Fixes

* **cli:** read the login token without echo ([4ad86af](https://github.com/This-Is-NPC/atanor/commit/4ad86afed23a8be26f7b895d11dbeeac4a9693bf))
* **dashboard:** add Max-Age and Secure to the cookie ([267d8ac](https://github.com/This-Is-NPC/atanor/commit/267d8ac200c0a063afe351478df178314794ea95))
* **drain:** omit progress until alambique begins ([3257f76](https://github.com/This-Is-NPC/atanor/commit/3257f76d367e70c1aacc4ed825a3ea6be7a4a546))
* **http:** use a fixed retry-after for held_elsewhere ([2ebdebf](https://github.com/This-Is-NPC/atanor/commit/2ebdebfd4a6a05cb12368f1dbe0caf852dc76eb0))

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
