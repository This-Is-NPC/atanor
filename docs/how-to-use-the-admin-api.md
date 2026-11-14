# How to inspect and control an Atanor node with the admin API

**The question:** How do I see which workers and versions run on my nodes,
which routes they serve and which cells are alive, without attaching to a VM?

This guide stands alone for a single node. The answers that cover several
nodes are shown in [how-to-run-a-cluster.md](how-to-run-a-cluster.md).

## Prerequisites

- A node started with the `admin:` option, or `mix atanor.dev --admin-port PORT
  --admin-token TOKEN`. The token is required. The listener is on loopback
  (`127.0.0.1`) unless you pass `ip:`; a token is required there too.
- `curl`. The commands below use the example project in
  [examples/hello-native](../examples/hello-native):

  ```sh
  cd examples/hello-native
  mise exec -- mix atanor.dev --port 4010 --admin-port 5010 --admin-token demo-token
  ```

  In an application, give the option to `Atanor`:

  ```elixir
  {Atanor, name: MyApp.Atanor, store: store, data_dir: dir, admin: [token: System.fetch_env!("ATANOR_ADMIN_TOKEN"), port: 4001]}
  ```

Every request answers JSON and needs the header `authorization: Bearer
<token>`: the operator token of the `admin:` option, which holds every scope, or
a scoped token (step 12). Most are `GET`; the write endpoints are the hint that a node is gone
(step 7), dead-letter retry/discard (step 8), bulk-operation
create/pause/resume/cancel and undo report and apply (step 9), the TLS certificate reload (step 10), the
migration rehearsal start/cancel (step 11) and, with scoped tokens, deploys, token management and the audit log
(step 12).
Every write is logged and emits `[:atanor, :admin, :action]`.

## Steps

1. Check authentication. Without the token, or with another, the answer is 401.

   ```sh
   curl -si localhost:5010/health
   ```

   ```text
   HTTP/1.1 401 Unauthorized
   www-authenticate: Bearer
   content-type: application/json; charset=utf-8

   {"error":"unauthorized"}
   ```

2. Ask for the health of the node and the nodes it sees.

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/health
   ```

   ```json
   {"node":"nonode@nohost","status":"ok","nodes":["nonode@nohost"],"workers":1,"store":{"<location>":{"state":"closed","since_ms":1731456000000,"failures":0}}}
   ```

   `store` is the circuit breaker of each store location: `closed`, `open`
   (requests fail at once with 503 `store_unavailable`) or `half_open` (the next
   request is the probe), since when (`since_ms`, Unix milliseconds) and the
   failures in a row. It is read from the node without a request to the store.
   An open breaker does not change `status` or the readiness paths below: the
   node still serves its awake cells, and the other nodes share the store
   ([design §10.2](design.md#102-admin-api)).

   Ask whether the node serves. A load balancer or a rolling restart polls
   this path on the admin port (the HTTP ingress has no health path of its
   own; it opens only when the node is ready).

   ```sh
   curl -si -H "authorization: Bearer demo-token" localhost:5010/health/ready
   ```

   ```text
   HTTP/1.1 200 OK
   content-type: application/json; charset=utf-8

   {"node":"nonode@nohost","status":"ready"}
   ```

   A load balancer should ask `/health/serving` instead: it answers 200
   `serving` while the node is ready and has a quorum, and 503 `no_quorum`
   when the node cannot reach a majority of the nodes it knows (it is cut off,
   for example), where every call that needs another node would fail fast with
   503 `no_quorum`. `/health/ready` keeps its meaning for a rolling restart: it
   stays 200 on a node without a quorum, since that node has applied its
   deployments. With `takeover: [quorum: false]` the quorum is not asked and
   `serving` is `ready`. A node that has just regained its majority waits
   `takeover.settle_ms` (2 s) before it says `serving` again.

   A node that was told to drain (step 13) answers 503 `draining` on both
   paths, so the balancer stops sending it requests; `/health` stays 200 and
   says `"status":"draining"`.

   While the node loads its deployments the answer is 503 with the reason, for
   example when the store cannot be read (output of the test
   `test/atanor/readiness_test.exs`):

   ```json
   {"node":"nonode@nohost","reason":"could not list the workers: :injected","status":"starting"}
   ```

   Every other endpoint answers 503 `not_ready` then. The listener
   itself opens before the node is ready, so a refused connection means the
   VM is still starting.

3. List the workers in the store: the active package and the previous ones.

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/workers
   curl -s -H "authorization: Bearer demo-token" localhost:5010/workers/hello
   ```

   ```json
   {"workers":[{"active":"8e86f9aac079de7217ac8a7279c6890e999d86d0780e6ea3e8cbf2227a264b80","worker":"hello","revision":1,"previous":[],"updated_at":"2026-10-27T02:07:45.094329Z"}]}
   ```

   `/workers/hello` adds `deployment`: the manifest of the version this node
   serves (bindings, routes, limits). Secret values are never in it, only their
   names. An unknown worker is 404.

4. See what every node applied. `head` is what the store says, `applied` what
   the node loaded and `serving` what its registry serves; `error` says why a
   head could not be applied, for example `{:code_mismatch, ...}` when the node
   runs other native code.

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/deployments
   ```

   ```json
   {"nodes":{"a@myhost":{"release":{"id":"image-sha"},"status":"ok","workers":[{"error":null,"worker":"hello","head":"8e86f9a...","applied":"8e86f9a...","serving":"8e86f9a..."}]}},"partial":false}
   ```

   (Ids and the `release` fields are shortened here.) With several nodes there is one entry per node. A node
   that does not answer within 5 seconds appears as `{"status":"error",
   "reason":"..."}` and `partial` is `true`. `release` is the build that node
   reported (`release: [id: ...]`, design §17.1).

   `GET /crashes` lists the reports written at the start after a VM crash:
   the unit (job, alarm, sweep, migration, deployment, WebSocket), its cell,
   job and operation ids, the release that ran and Alambique's
   `crashes`/`frozen` view of the cell. `?node=` filters one node, and
   `GET /crashes/:node/:id` returns one report. See
   [how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md) for the core-dump
   side and for unfreezing:

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/crashes
   curl -s -X POST -H "authorization: Bearer demo-token" \
     localhost:5010/cells/notes/alice/unfreeze
   ```

5. List the routes of the node.

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/routes
   ```

   ```json
   {"http":[{"path":"/hello","host":"localhost","worker":"hello"}],"node":"nonode@nohost","tcp":[]}
   ```

   `tcp` holds `{"listener", "port", "worker"}` for each open listener.

6. Count the live cells, then list them. Counts cover every node; a list is
   one node's cells, in id order, `limit` at a time (1 to 1,000, default 100).
   Pass the `next` of a page as `after` to get the following one; `next` is
   `null` on the last page.

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/cells
   curl -s -H "authorization: Bearer demo-token" "localhost:5010/cells?node=nonode@nohost&limit=10"
   ```

   ```json
   {"total":1,"nodes":{"nonode@nohost":{"count":1,"status":"ok"}},"partial":false}
   {"node":"nonode@nohost","next":null,"cells":[{"id":"hits.alice","key":"alice","namespace":"hits"}]}
   ```

   A page costs in proportion to its size. A cell that has just woken or
   stopped may be missing from a page or listed late.

7. See how this node sees its peers, and tell it that one is lost. `/nodes`
   shows the failure detector's `state` of each peer (`alive`, `suspect`,
   `link_broken`, `down`), `phi`, the milliseconds since its last heartbeat and
   the `reason` of the last verdict. It is this node's view only. The hint
   confirms a node down at once, here and at its peers, for an infrastructure
   hook that knows a machine is gone ([how-to-run-a-cluster.md](how-to-run-a-cluster.md)
   shows it end to end):

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/nodes
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/nodes/NODE/gone
   ```

   ```json
   {"node":"nonode@nohost","nodes":[]}
   {"error":"unknown_node"}
   ```

   (A node alone has no peers, so the hint for `NODE` is 404. With peers:
   `{"node":"c@myhost","state":"down"}`.) A hinted node that is alive
   comes back by itself when its heartbeats arrive.

   `GET /hot-cells` shows what the placement of hot cells (the `hot_cells:` option)
   knows on this node: its CPU, the hot cells it serves and why each stayed or moved,
   the load of its peers, the moves and the cells whose replicas it switched on
   (`replicas`); `{"enabled":false}` when the loop is off
   ([how-to-place-hot-cells.md](how-to-place-hot-cells.md)).

   `GET /runtime` shows what this node's memory is made of: the VM memory by type,
   the biggest ETS tables and processes (by message queue and by memory), the cgroup
   counters (`memory.current`, `memory.stat`, `oom_kill`), the Wasm gauges and the
   admission counters (`admission`: requests in flight, refusals by reason (`memory`, `disk`,
   `in_flight`), the last working set, the disk use of `data_dir` against its budget,
   and whether the node is refusing, see
   [configuration](configuration.md)) and `store`, the circuit breaker of
   each store location as in `/health`. A
   cgroup field is `null` when its file cannot be read. The load harness samples it
   ([how-to-run-the-load-tests.md](how-to-run-the-load-tests.md)).

8. See jobs and dead letters. Without a cell, `/jobs` is the per-node slot
   count. With `?cell=namespace.key`, it is one page of that cell's jobs;
   `?state=dead` selects the dead-letter set. Retry or discard one dead job
   (the cell wakes):

   ```sh
   curl -s -H "authorization: Bearer demo-token" localhost:5010/jobs
   curl -s -H "authorization: Bearer demo-token" "localhost:5010/jobs/mail/alice?state=dead"
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/jobs/mail/alice/JOB/retry
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/jobs/mail/alice/JOB/discard
   ```

   A dead job's `last_error` starts with `infrastructure: ` when errors of the
   store or the cell outlasted `jobs.infrastructure_timeout_ms`; otherwise it is
   the last error of the handler after `max_attempts`.

   `GET /jobs/:namespace/:key/:id` returns one job. A retry of a job that is
   not dead is 409 `not_dead`.

9. Create and control bulk operations. The body is the operation record:
   selector, action (worker, kind, payload), rate, concurrency and page size.
   The full example is in
   [how-to-run-a-bulk-operation.md](how-to-run-a-bulk-operation.md).

   ```sh
   curl -s -X POST -H "authorization: Bearer demo-token"      -H "content-type: application/json"      -d '{"selector":{"kind":"namespace","namespace":"mail"},"action":{"worker":"mail","kind":"reindex","payload_base64":""},"rate_per_s":25,"concurrency":8}'      localhost:5010/operations
   curl -s -H "authorization: Bearer demo-token" localhost:5010/operations
   curl -s -H "authorization: Bearer demo-token" localhost:5010/operations/OP_ID
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/operations/OP_ID/pause
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/operations/OP_ID/resume
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/operations/OP_ID/continue
   curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/operations/OP_ID/cancel
   ```

   `continue` confirms an operation in `awaiting_confirmation`; `resume`
   restarts a `paused` or `halted` one. An action the state does not allow, such
   as a pause on a completed operation, is 409 `invalid_state`; an unknown
   operation is 404. The canary and error-rate options of the body are in
   [how-to-run-a-bulk-operation.md](how-to-run-a-bulk-operation.md).

   An operation created with `"undo": true` records a position in each cell.
   `POST /operations/OP_ID/undo` has two modes. `{"mode":"report"}` (the
   default) starts, on the node that receives it, a report that compares each
   cell before and after the operation. `{"mode":"apply"}` then rewinds each
   cell of a finished report to its position, if the cell was not written since
   the report. Both answer `202 {"undo_id": "u-...", "state": "running"}`;
   `GET /operations/OP_ID/undo` returns the record from any node, with `state`
   `running`, `done`, `failed` or `stale`, and `mode` `report` or `apply`.

   ```sh
   curl -s -X POST -H "authorization: Bearer demo-token" -H "content-type: application/json" -d '{"mode":"report"}' localhost:5010/operations/OP_ID/undo
   curl -s -H "authorization: Bearer demo-token" localhost:5010/operations/OP_ID/undo
   curl -s -X POST -H "authorization: Bearer demo-token" -H "content-type: application/json" -d '{"mode":"apply"}' localhost:5010/operations/OP_ID/undo
   ```

   Any other mode is 400 `invalid_mode`. An unknown operation, or a `GET`
   before the first report, is 404. 409 has an `error` of: `undo_not_enabled`
   (the operation was created without `undo`), `already_running` (a record is
   `running`), and, for `apply` only, `operation_active` (not `done` or
   `cancelled`), `report_required` (no finished report), `report_truncated`
   (the report stopped at `sweeps.undo_max_cells`) and `jobs_active` (a job of
   the operation is still `pending` or `running`). A store error is 503
   `store_unavailable`. Each `apply` is logged and emits
   `[:atanor, :admin, :action]` with `action: :undo_apply`. The record and the
   per-cell results are described in
   [how-to-run-a-bulk-operation.md](how-to-run-a-bulk-operation.md#undo-and-the-undo-report).

10. Reload the TLS certificate of one listener after replacing its files. New
    handshakes use the new pair; connections that already negotiated keep
    their session. A pair that does not load keeps the previous certificate
    and the answer is 422.

    ```sh
    curl -s -X POST -H "authorization: Bearer demo-token" \
      localhost:5010/listeners/submission/reload-tls
    ```

    ```json
    {"listener":"submission","reloaded":true}
    ```

    An unknown listener is 404 `unknown_listener`, and a listener without TLS
    409 `no_tls`. The node also polls the files every `tls.reload_ms`; the
    endpoint is for an immediate reload.

11. Rehearse a package's migrations on copies of sampled cells before you
    activate it. The answer is 202 and the report is read with `GET`. The
    steps, the report fields and the options are in
    [how-to-run-a-migration-rehearsal.md](how-to-run-a-migration-rehearsal.md).

    ```sh
    curl -s -X POST -H "authorization: Bearer demo-token" -H "content-type: application/json" \
      -d '{"worker":"notes","id":"PACKAGE_ID"}' localhost:5010/rehearsals
    curl -s -H "authorization: Bearer demo-token" localhost:5010/rehearsals
    curl -s -H "authorization: Bearer demo-token" localhost:5010/rehearsals/REHEARSAL_ID
    curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/rehearsals/REHEARSAL_ID/cancel
    ```

    ```json
    {"id":"h-1793475888683-13754174","package":"4ae1c188910b5e3ab17f95a39ef6125f50f255fde6c14fa402516fc24f4dc3df","state":"running","worker":"notes"}
    ```

    A missing package is 404 `package_not_found`, a package of another worker
    400 `wrong_worker`, a field above the node's bound 400 `invalid_rehearsal`,
    a rehearsal that is already running 409 `already_running`, and cancelling
    one that is not running 409 `invalid_state`.

12. Deploy through the API with a scoped token, so the deployer never holds
    the bucket credentials (`atanor deploy --bucket` is the way for one that does).
    The nodes talk to the store. The `atanor` command
    does all of this ([cli.md](cli.md), [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md));
    the contract of these endpoints is [openapi/admin.json](openapi/admin.json). First create a token
    with the operator token. The answer holds the secret `token` once; the
    store keeps only its hash, so a lost token is revoked and replaced.

    ```sh
    curl -s -H "authorization: Bearer demo-token" -d '{"name":"ci-hello","description":"CI of hello","scopes":["worker:hello:deploy","worker:hello:activate","worker:hello:read"],"expires_at":"2027-06-01T00:00:00Z"}' localhost:5010/tokens
    ```

    ```json
    {"created_at":"2026-11-01T20:36:34Z","created_by":"operator","description":"CI of hello","expires_at":"2027-06-01T00:00:00Z","id":"atn_0123456789abcdef01234567","name":"ci-hello","revoked_at":null,"scopes":["worker:hello:deploy","worker:hello:activate","worker:hello:read"],"token":"atn_0123456789abcdef01234567_EXAMPLE-SECRET-NOT-A-REAL-TOKEN"}
    ```

    A scope is `cluster:admin` or `worker:<name>:<action>`, with `<action>`
    one of `deploy`, `activate`, `rollback` and `read`. `worker:*:<action>`
    covers every worker for that action; there are no other patterns.
    `cluster:admin` is token management, the audit log and every endpoint
    of the other steps; it does not include any worker scope. `expires_at` is
    optional (ISO 8601 with an offset, in the future). A bad scope, name or date
    is 400 `invalid_token` with the reason.

    Upload a package built with `Atanor.Package` (the body is the package
    bytes) together with its SHA-256 in `x-package-sha256`. The node
    recomputes the hash, parses the package, validates the manifest and
    checks that it belongs to the worker in the path. Nothing is stored
    otherwise.

    ```sh
    TOKEN=atn_0123...   # the secret from the previous answer
    curl -s -H "authorization: Bearer $TOKEN" -H "x-package-sha256: $SHA256" --data-binary @hello.pkg localhost:5010/workers/hello/packages
    ```

    ```json
    {"size":331,"head":null,"worker":"hello","kind":"native","package_id":"2b1294c007ec8b2ff45a97a1bc75243cceffa24737338966eb728cbb15bd6f78"}
    ```

    A wrong hash is 422 `hash_mismatch`, bytes that are not a valid package are
    422 `invalid_package`, a package of another worker is 422
    `package_of_other_worker`, and more bytes than `max_package_bytes` is 413
    `package_too_large`. Activating a package that declares another number of
    partitions than its namespace was activated with (or none), or that
    partitions a namespace that has cells, is 409 `partitions_changed` or
    `namespace_has_data` ([how-to-partition-a-cell.md](how-to-partition-a-cell.md)).
    `?activate=true` also activates the package, and then
    the token needs `worker:<name>:activate` too. Activate a stored package,
    list the versions, see the status and roll back:

    ```sh
    curl -s -H "authorization: Bearer $TOKEN" -d '{"package_id":"2b1294c0..."}' localhost:5010/workers/hello/activate
    curl -s -H "authorization: Bearer $TOKEN" localhost:5010/workers/hello/versions
    curl -s -H "authorization: Bearer $TOKEN" localhost:5010/workers/hello/status
    curl -s -X POST -H "authorization: Bearer $TOKEN" localhost:5010/workers/hello/rollback
    ```

    ```json
    {"active":"2b1294c007ec8b2ff45a97a1bc75243cceffa24737338966eb728cbb15bd6f78","worker":"hello","revision":1,"previous":[],"updated_at":"2026-11-01T20:36:34.791360Z"}
    {"error":"forbidden","required":"worker:hello:rollback"}
    ```

    The two answers shown are those of the first command and of the rollback,
    which this token may not do: 403, and nothing changed. `versions` is the head (`active`, `previous` newest first, `revision`)
    plus `versions`: every package uploaded for the worker, oldest first, each
    with `package_id`, `kind`, `size`, `uploaded_at`, `uploaded_by` (the
    operator or token that uploaded it; `{"type":"script"}` for a deploy made in-process) and `state`
    (`active`, `previous` or `null`). Page with `?limit=` and `after=<next>`
    (`limit` as in the other lists). Any listed `package_id` can be activated.
    A worker with no head and no uploads is 404. Uploading the same package
    again keeps its first entry. Packages stored before the index existed are
    not listed. `status` adds `node`, the
    package this node `applied` and the `error` if the head could not be
    applied. `GET /heads` lists the heads of the workers the token may read.

    Manage tokens and read who did what. These need `cluster:admin`.

    ```sh
    curl -s -H "authorization: Bearer demo-token" localhost:5010/tokens
    curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/tokens/atn_0123456789abcdef01234567/revoke
    curl -s -H "authorization: Bearer $TOKEN" localhost:5010/heads
    curl -s -H "authorization: Bearer demo-token" "localhost:5010/audit?limit=2"
    ```

    ```json
    {"error":"unauthorized"}
    {"next":"1793565394790799-c349ebf5","entries":[{"action":"token.create","actor":{"type":"operator"},"error":null,"id":"1793565394785461-42240e64","node":"nonode@nohost","remote_ip":"127.0.0.1","result":"ok","status":201,"target":"atn_0123456789abcdef01234567","time":"2026-11-01T20:36:34.785461Z"},{"action":"package.upload","actor":{"id":"atn_0123456789abcdef01234567","name":"ci-hello","type":"token"},"error":null,"id":"1793565394790799-c349ebf5","node":"nonode@nohost","remote_ip":"127.0.0.1","result":"ok","status":201,"time":"2026-11-01T20:36:34.790799Z","version":"2b1294c007ec8b2ff45a97a1bc75243cceffa24737338966eb728cbb15bd6f78","worker":"hello"}]}
    ```

    The two answers shown are those of the last two commands: `/heads` with the
    token the second command revoked, and the audit page. A revoked token is
    rejected on the very next request, on every node, because each request
    reads the token from the store. An expired, revoked, unknown or malformed
    token is 401, and the answer never repeats it. A well-formed token id that
    the store does not have is refused from memory for `admin.unknown_token_ms`
    (2 seconds), so a client that tries random tokens does not make a store
    read each. Failed tokens are also limited per client address: after
    `admin.max_failures` (10) in `admin.failure_window_ms` (60 seconds) the
    address gets 429 `{"error":"too_many_attempts"}` with `Retry-After`, with
    the right token too, until the window ends. The address is the peer of the
    connection, so behind a proxy all clients share one limit. A valid token without the
    scope is 403 with `required`. The audit log lists events oldest first;
    page with `limit` and `after=<next>`. Each entry has the `actor` (the
    `operator` or a token `id` and `name`), `action` (`package.upload`,
    `version.activate`, `version.rollback`, `token.create`, `token.revoke`),
    `worker`, `version`, `result` (`ok`, `denied` for a 403 on a write, or
    `failed`), `status`, `error`, `time`, `node` and `remote_ip`. Reads and 401
    answers are not in it.

    | Method and path | Scope | Answers |
    | --- | --- | --- |
    | `POST /workers/:w/packages[?activate=true]` | `worker:<w>:deploy` (+ `activate`) | 201; 400 `missing_hash`, `invalid_hash`, `invalid_worker`; 413; 422 |
    | `POST /workers/:w/activate` `{"package_id"}` | `worker:<w>:activate` | 200 head; 400, 404 `package_not_found`, 409 `conflict`, `partitions_changed` or `namespace_has_data`, 422 |
    | `POST /workers/:w/rollback` | `worker:<w>:rollback` | 200 head; 409 `no_previous` or `partitions_changed` |
    | `GET /workers/:w/versions[?limit&after]`, `GET /workers/:w/status` | `worker:<w>:read` | 200; 400 `invalid_limit`; 404 |
    | `GET /heads` | any token | 200, only the readable workers |
    | `POST /tokens`, `GET /tokens`, `GET /tokens/:id`, `POST /tokens/:id/revoke` | `cluster:admin` | 201 / 200; 400 `invalid_token`; 404 |
    | `GET /audit` | `cluster:admin` | 200 `entries` and `next` |

    The limits are options of `admin:`: `max_package_bytes` (default
    67,108,864), `max_scopes` (64 per token), and `default_limit` and
    `max_limit` (100 and 1,000), which also bound the token and audit pages.

13. Hand the cells of a node back before you stop it. `POST /drain` makes the
    node report `draining`, hibernate every cell it holds and release each
    lease, so another node takes each cell at its next call; then the node
    stops itself. The answer comes when the cells are back, at most
    `stop.shutdown_ms` (75 seconds by default) later. Needs `cluster:admin`.
    The same as `atanor drain` ([cli.md](cli.md)).

    ```sh
    curl -s -H "authorization: Bearer demo-token" localhost:5010/drain
    curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/drain
    curl -si -H "authorization: Bearer demo-token" localhost:5010/health/ready
    ```

    Output of the test node, started with `stop: [exit: false]` so it stays
    up (without it the VM stops after the answer):

    ```text
    GET /drain -> 200 {"errors":[],"node":"nonode@nohost","state":"idle"}
    POST /drain -> 200 {"duration_ms":6,"errors":[],"hibernated":1,"node":"nonode@nohost","state":"drained"}
    GET /health/ready -> 503 {"node":"nonode@nohost","reason":"the node is handing its cells off","status":"draining"}
    GET /health/serving -> 503 {"node":"nonode@nohost","reason":"the node is handing its cells off","status":"draining"}
    GET ingress /c/a -> 503 retry-after=["1"] {"error":"unavailable","reason":"draining"}
    ```

    While it drains the node keeps serving the cells it still holds on every
    listener. A request that needs a cell it handed back is 503 `draining`
    with `Retry-After`; the node that takes the cell answers it. `errors`
    lists cells that stayed with their leases until these expire (`cell` and
    `reason`; `:drain` with `:deadline` when the whole drain ran out of
    time), and the node then stops with status 1. A cell that another node
    still holds is 503 `held_elsewhere` on the node that asks. `GET /drain` reads `idle`,
    `draining` or `drained`; while `draining` it adds `cells_at_start`, `done`,
    `left` and the `errors` so far, so a poll shows the progress (they are absent while
    the node waits for its running jobs, before the cells are handed back). The options are `stop: [drain_timeout_ms,
    drain_concurrency, shutdown_ms, exit]`
    ([configuration](configuration.md), design
    [§8.11](design.md#811-draining-and-stopping-gracefully)).

14. Forget the OIDC keys of a node after a provider withdrew one. A node
    caches the keys of each issuer for `oidc.jwks_max_age_ms` (1 hour), so a
    withdrawn key keeps verifying until then. `POST /auth/keys/flush` drops the
    cached discovery documents and keys of every issuer on the node that
    answers; the next request that needs a key fetches it. Needs
    `cluster:admin`. Call it on each node of the cluster. `flushed` is the
    number of issuers the node held, 0 when it has no `auth:` rule.

    ```sh
    curl -s -X POST -H "authorization: Bearer demo-token" localhost:5010/auth/keys/flush
    ```

    ```json
    {"flushed":1,"node":"nonode@nohost"}
    ```

    The action is logged and emits `[:atanor, :admin, :action]` with
    `action: :flush_auth_keys`. The same from a remote shell:
    `Atanor.Auth.Keys.flush(MyApp.Atanor)`. How the keys are cached is in
    [how-to-protect-a-route-with-oidc.md](how-to-protect-a-route-with-oidc.md).

## Troubleshooting

- **401 with the right token.** The header must be exactly `authorization:
  Bearer <token>`. `Basic` and a bare token are refused.
- **`ArgumentError: :admin needs a :token`.** The option is invalid without a
  non-empty token.
- **Connection refused.** The listener is on `ip:` (loopback by default) and
  `port:` (4001 by default). With `port: 0` the port is
  `Atanor.admin_port(name)`.
- **`/health/ready` stays 503 `starting`.** The reason names what is missing:
  the store cannot be listed or a head cannot be read. The node retries every
  `ready: [retry_ms:]` (1 second) and, after `ready: [timeout_ms:]` (60
  seconds), its instance does not start. A worker that cannot be applied does
  not keep the node out: see `/deployments`.
- **`/cells?node=...` is 404.** The node is not in the `nodes` of `/health`.
  Use the name exactly as it appears there.
- **`/crashes` is empty after a crash.** The old VM may have stopped cleanly,
  or the breadcrumb files were lost with the machine. Check the node's
  `data_dir/diagnostics/pending/` and [how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md).
- **A cell refuses to wake with `:frozen`.** Alambique's quarantine froze it
  after repeated crashes; inspect the report and unfreeze it only after
  deciding the cell may start from zero.
- **401 `unauthorized` with a scoped token.** The token is expired, revoked,
  mistyped or from another prefix or store. Create a new one. A 403 `forbidden`
  names the scope the request needs in `required`.
- **`versions` does not list a package.** It was stored before the version index existed, or by other means than a deploy. Upload it again to index it.
- **A deploy is 503 `store_unavailable`.** The node cannot reach the bucket.
  The body has no detail, because an error of the object store can hold its
  response; the cause is in the node's log (`atanor admin: store unavailable`).
  After an `?activate=true` upload failed at the activation, the package may be
  stored; upload again (it is idempotent) or call `activate`.
- **A node is missing from `/deployments`.** It is not connected to the others
  (see [how-to-run-a-cluster.md](how-to-run-a-cluster.md)).
- **`/jobs?cell=...` is 400 `invalid_cell`.** Use `namespace.key`, with no
  slash and a key that the placement accepts.
- **An operation is 429 `too_many_operations`.** The store holds
  `sweeps.max_records` (1 000) operation records. Finished ones are removed
  after `sweeps.retention_ms` (30 days); raise the option or wait.
- **An operation is 400 `invalid_operation`.** A selector namespace is not
  granted, the action is missing, or `rate_per_s`, `concurrency` or
  `page_size` is above the instance's `sweeps:` bound.
- **`/rehearsals` is 400 `invalid_rehearsal`.** The message names the field:
  `sample_size`, `max_cells` and `timeout_ms` cannot exceed the node's
  `rehearsal:` bounds, and unknown fields are refused.
- **`/listeners/:name/reload-tls` is 409 `no_tls`.** The listener has no
  `tls:` option. A 422 `reload_failed` means the new files do not load (an
  unreadable file, no certificate, or a key that does not belong to it); the
  previous certificate keeps serving and the reason is in the answer and the
  node log.

## Next steps

- [telemetry.md](telemetry.md) for metrics: the API answers "what is there
  now", the events answer "what happened".
- [how-to-use-jobs.md](how-to-use-jobs.md) and
  [how-to-run-a-bulk-operation.md](how-to-run-a-bulk-operation.md) for the
  records these endpoints show.
- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) to change what the
  API shows.
