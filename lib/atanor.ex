defmodule Atanor do
  @moduledoc """
  A generic runtime for workers and the stateful cells they use, on a cluster
  of BEAM nodes (design §1).

      children = [
        {Atanor,
         name: MyApp.Atanor,
         store: {Alambique.Store.S3, s3_config},
         prefix: "myapp",
         data_dir: "/var/lib/myapp/cells",
         port: 4000}
      ]

  ## Options

    * `:name` - atom that names the instance (default `Atanor`). The Alambique
      instance is named `<name>.Cells`.
    * `:data_dir` - directory for the local copies of cells (required).
      It belongs to one instance, on a case-sensitive file system: the start locks
      `<data_dir>/lock` and fails with `{:data_dir_in_use, path}` or
      `{:data_dir_case_insensitive, path}`.
    * `:store` - `{module, config}` implementing `Alambique.Store`, with
      `:prefix`: cells and Atanor's metadata share this store (design §5).
    * `:placement` - `{module, opts}` implementing the placement behaviour of Alambique, with
      `:meta_store`: the `{module, config}` that holds Atanor's metadata. Give
      `:store` or `:placement`, not both.
    * `:prefix` - key prefix of Atanor's objects (default `"atanor"`).
    * `:port` - HTTP ingress port, `0` for an ephemeral one (default 4000).
    * `:ip` - address the ingress listens on (default `{127, 0, 0, 1}`).
    * `:poll_interval_ms` - how often the node reloads the workers' heads from
      the store (default 5000). Switches made through an instance also reach
      the other nodes at once (design §2, §5).
    * `:hosts` - `%{"worker" => ["host" | "*.domain" | "*"]}`: the HTTP hosts
      each worker may claim in its routes. `"*"` allows any host, and the
      catch-all route `*` (every host, lowest precedence) in particular. A
      route outside its worker's list makes the activation fail. Without this
      option any host is allowed, which trusts the packages (design §7.1).
    * `:auth` - bearer-token validation per HTTP route: a list of keyword lists
      `[host:, path: "/", issuer:, audience:, scopes: [], types: nil,
      algorithms: ["RS256"], leeway_s: 60, realm: nil]`, each naming a route
      as the manifest declares it. A request without a valid token never
      reaches the worker (design §7.5; `Atanor.Auth`). Without this option
      no route is protected.
    * `:oidc` - fetch settings for `:auth` (OIDC discovery and JWKS), in
      milliseconds unless noted: `min_refresh_ms` 60000 (at most one JWKS
      refresh per issuer in this interval), `error_backoff_ms` 5000,
      `jwks_max_age_ms` 3600000, `jwks_max_stale_ms` 86400000 (how long
      the keys of an issuer that cannot be refreshed keep serving after
      `jwks_max_age_ms`), `discovery_ttl_ms` 3600000,
      `connect_timeout_ms` 2000, `receive_timeout_ms` 5000,
      `max_response_bytes` 1000000 (a longer response ends the fetch while it is
      read), `allow_http` false (http issuers).
    * `:listeners` - the TCP listeners that manifests name. The short form is
      `%{"smtp" => 2525}`: the port, 0 picking a free one. The long form is
      `%{"smtp" => [port: 2525, protocol: :thousand_island, tls_mode: :starttls,
      tls: [...], acceptors: 10, max_connections: 16_384, ip: {0, 0, 0, 0}]}`;
      `:ip` is the address the listener binds, as a tuple or a string
      (`"127.0.0.2"`, `"::1"`), IPv4 or IPv6, and defaults to the ingress
      `:ip`; `:protocol` is
      `:thousand_island` (the default) or `:ranch`, `:tls_mode` is `:implicit`
      or `:starttls` (absent means plain), and `:acceptors` and
      `:max_connections` default to their `:tcp` values. A route to an unknown
      listener, or to a listener of another protocol, makes the activation
      fail. A listener is open while a deployment claims it (design §7.3).
      `:tls` takes `:certfile` and `:keyfile` (required, the key must belong to
      the certificate), `:cacertfile`, `:versions`, `:ciphers`, `:verify`
      (`:verify_none`, or `:verify_peer` with `:cacertfile`),
      `:fail_if_no_peer_cert` (true with `:verify_peer`: a client without a
      certificate is refused) and
      `:handshake_timeout_ms` (10 000). A certificate change is picked up
      without a restart: the files are polled every `:reload_ms` (5 000), an
      invalid replacement keeps the previous certificate, and
      `POST /listeners/:name/reload-tls` on the admin API reloads one listener
      at once. See `Atanor.TCP.TLS`.
    * `:tcp` - defaults of TCP connections: `:idle_timeout_ms` (60 000),
      `:max_chunk_bytes` (65 536), `:max_connections` (16 384) and
      `:acceptors` (10, not more than `:max_connections`). A listener can
      override `:acceptors` and `:max_connections`.
    * `:websocket` - limits of WebSockets served by workers:
      `:idle_timeout_ms` (60 000), `:max_frame_bytes` (1 000 000, also
      the largest message spread over several frames) and the frame rate of
      one socket, `:max_frames_per_s` (100) with a burst of `:frame_burst`
      (200); a socket over it is closed with 1008. A socket on a route with
      an `:auth` rule is also closed with 1008 when its token expires.
    * `:alarms` - `:tick_ms` (1000), `:timeout_ms` (30 000), `:max_attempts`
      (5), `:page_size` (1000 index entries per scan), `:concurrency` (16
      handler tasks), `:backoff_ms` (1000) and `:max_backoff_ms` (60 000) of
      alarm firing, `:shards` (64, the index shards) and `:clock`, an
      `{Alambique.Clock module, config}` for the alarm times (default the
      system clock; design §7.4). The shard count is recorded in the metadata
      on the first start and is fixed for the life of the instance's data; a
      later start with another value is refused.
    * `:admin` - serves the admin API (design §10): `:token` (required, every
      request must send it as a bearer token), `:port` (default 4001, `0` for an
      ephemeral one), `:ip` (default loopback), `:default_limit` (100 cells per
      page) and `:max_limit` (1 000); `:max_connections` (128, shared by
      `:acceptors`, 4), `:read_timeout_ms` (10 000) and `:http_2` (true), as
      in `:http`; `:unknown_token_ms` (2 000, how long a scoped token id that
      the store does not have is refused without asking the store again) and
      `:unknown_tokens` (1 000 such ids kept); `:max_failures` (10) failed
      tokens per client address in `:failure_window_ms` (60 000), after which
      the address gets 429 until the window ends, and `:tracked_addresses`
      (10 000 addresses kept; `:dashboard` takes the same three). A token shorter than 32 bytes
      needs `:ip` to be a loopback address, here and in `:dashboard`. Without this option there is no admin
      listener. It opens first: `GET /health/ready` answers 503 while the node
      loads its deployments and 200 when it serves (design §2.1).
    * `:dashboard` - serves the read-only dashboard (design §10.1) with the
      options of `:admin` (`:token` required, `:port` default 4002, `:ip`
      default loopback) and `:page_size` (50 rows), `:max_page_size` (500) and
      `:poll_ms` (5000, how often the native counters are emitted),
      `:cookie_max_age_s` (86 400, the `Max-Age` of the session cookie) and
      `:secure_cookie` (false; `true` adds `Secure`, for a dashboard served
      over https by a proxy). It needs the optional dependencies listed by `Atanor.Dashboard.dependencies/0` and
      runs once per VM.
    * `:detector` - the failure detector between nodes (design §8.7):
      `:interval_ms` (heartbeats, 1000), `:phi_threshold` (8), `:min_std_ms`
      (200), `:acceptable_pause_ms` (2000), `:window` (100) and `:indirect`,
      a keyword list with `:k` (witnesses asked to probe a suspect peer, 3),
      `:timeout_ms` (how long a ping waits, 1000) and `:round_timeout_ms`
      (when a probe round gives up, 1500); `:reprobe_ms` (1000, between
      probe rounds of a peer whose link is broken), `:reconnect_ms` (1000,
      between connection attempts to a peer that is not connected),
      `:stall_intervals` (3: a gap this long between two messages of the
      detector means this node was stalled), `:seed_spread` (0.25: how far
      apart, as a share of the interval, the two intervals that seed a new
      peer's window are) and `:forget_after_ms` (600 000: a down peer is
      forgotten after this long).
    * `:takeover` - the early takeover of the cells of a node confirmed down
      (design §8.10): `:enabled` (true), `:quorum` (true: only with a strict
      majority of the known nodes), `:settle_ms` (2000, how long that majority must
      have held), `:attempts` (3, reads of the lease when a
      takeover loses a race) and `:timeout_ms` (`nil`, Alambique's
      `call_timeout_ms`).
    * `:hot_cells` - the automatic placement of hot cells (design §8.15); off by
      default. `:enabled` (false), `:interval_ms` (1000, sampling and load message),
      `:sustain_ms` (10 000, how long a cell stays hot before it moves),
      `:write_enter`/`:write_exit` (500/250 writes per second),
      `:read_enter`/`:read_exit` (2000/1000 reads per second),
      `:queue_enter`/`:queue_exit` (50/10 calls waiting on the cell),
      `:cpu_enter`/`:cpu_exit` (70/50, percent: the node gives cells away between
      them; the larger of its schedulers' use and, with `:os_cpu` (true), the
      machine's from `/proc/stat`), `:margin` (20 points: the target's CPU
      must be this far under the source's), `:residence_ms` (300 000, a cell that
      moved stays this long), `:node_cooldown_ms` (30 000, source and target of a
      move take part in no other), `:max_moves` (1, moves in progress in the
      cluster), `:move_timeout_ms` (15 000), `:stale_ms` (5000, a node not heard
      from this long is not a target), `:max_tracked` (100 hot cells per node),
      `:tags` (labels of this node, a list of strings) and `:affinity`
      (`[{namespace, tag}]`: hot cells of the namespace go to a node with the tag),
      `:move` (true; false keeps the loop from moving cells) and `:replicas`
      (false; true turns the Alambique read replicas on for a cell read at
      `:replica_enter` (1000) reads per second in the cluster for `:sustain_ms`,
      and off after `:replica_hold_ms` (60 000) under `:replica_exit` (500), design
      §19.4; it needs `alambique: [replicas: ...]`).
    * `:routing` - retries of a call whose owner moved or was lost (design
      §8.4): `:attempts` (3), `:retry_ms` (50) and `:remote_timeout_ms` (60 000,
      the longest a forwarded call may run), `:owner_check` (true),
      `:owner_check_ms` (1000, how long a read of a cell's lease is trusted
      before a handler starts), `:owner_check_cells` (10 000, also the cells whose
      lease the fence remembers; at the bound a sixteenth of the entries goes, so keep
      it above the cells a node serves within `:owner_check_ms`), `:fence` (true, kill a job or alarm handler at
      the end of this node's lease, design §8.13), `:fence_check_ms` (1 000, how
      often the fence reads the lease; also the timeout of the read),
      `:fence_defer_after_takeover` (true, start no job or alarm handler on a cell
      taken over early until the old lease has ended, design §8.13) and
      `:pinned_limit` (16 deployments pinned for forwarded requests) and
      `:leave_wait_ms` (3 000, how long a call waits for the owner that is
      leaving to hand the cell off; a stop took up to 0.7 s on a loaded
      machine in the tests and 1.4 s in the lab, design §8.11).
    * `:stop` - the drain and the graceful stop (design §8.11): `:jobs_ms` (15 000, wait for
      local job tasks), `:sweeps_ms` (5 000, release operation leases),
      `:connections_ms` (15 000, how
      long open connections get after the listeners close), `:drain_timeout_ms`
      (15 000, one cell hibernating and releasing its lease), `:drain_concurrency` (64,
      cells handed off at once), `:shutdown_ms` (75 000, the whole drain, at least `:drain_timeout_ms`)
      `:exit` (true: a drain asked for through `drain/2`, the admin API or `atanor drain` stops
      the node when it ends) and `:sigterm` (`:drain`: SIGTERM drains this instance with the listeners open,
      then stops the VM; `:stop`: SIGTERM stops the VM at once).
    * `:jobs` - the per-cell job runner (design §15): `:max_attempts` (20),
      `:timeout_ms` (30 000), `:claim_ms` (60 000), `:backoff_ms` (1 000),
      `:max_backoff_ms` (300 000), `:concurrency` (64 per node),
      `:worker_concurrency` (8), `:cell_concurrency` (1),
      `:claim_on_finish` (true, claim a cell's next due jobs when one finishes),
      `:release_claims` (true, release the claims of a node whose cell was taken
      over, design §15.11, and of a node that drains, §15.12), `:batch_size` (20),
      `:wait_ms` (1 000), `:max_payload_bytes` (1 000 000), `:max_pending`
      (10 000 pending and running jobs in a cell), `:max_cell_bytes`
      (67 108 864, the payloads of those jobs), `:max_cron` (100 schedules
      in a cell), `:max_tombstones` (10 000 `:forever` unique jobs in a
      cell), `:retention_ms` (604 800 000), `:dead_retention_ms`
      (2 592 000 000, or `:infinity`) and `:purge_limit` (100).
    * `:sweeps` - managed bulk operations (design §15.6): `:poll_ms` (5 000),
      `:lease_ttl_ms` (30 000), `:renew_ms` (10 000), `:cell_timeout_ms`
      (10 000), `:page_size` (100), `:rate_per_s` (50), `:concurrency` (8),
      `:max_active` (4), `:cell_attempts` (3), `:retry_ms` (1 000) and
      `:retention_ms` (2 592 000 000), `:max_records` (1 000 operation
      records; over it a new operation is refused, 429 on the admin API),
      `:reread_ms` (600 000; how long a finished record is kept before it is
      read again, spread by up to half), and
      the defaults of the canary and the
      error-rate guard (design §15.8): `:canary_size` (10, 0 disables),
      `:canary_gate` (`"auto"` or `"pause"`), `:canary_window_ms` (60 000),
      `:canary_timeout_ms` (300 000), `:guard_window_cells` (50),
      `:guard_error_rate` (0.1, above 0 and at most 1), `:guard_min_cells`
      (10), `:guard_poll_ms` (5 000) and `:guard_attempts` (3). A created
      operation may lower the rate, concurrency and page size, not raise
      them, and may set the canary and guard options and `undo` (design
      §15.9), whose instance default is `:undo` (`false`). The undo report
      and the undo that rewinds the cells (design §15.10) use
      `:undo_concurrency` (2 cells at a time), `:undo_timeout_ms` (120 000 for
      one cell), `:undo_max_cells` (1 000 cells with a position),
      `:undo_stale_ms` (600 000 without a heartbeat before a running record
      reads as `stale`).
    * `:feed` - the change feed tailer of native workers (design §16):
      `:poll_ms` (1 000, between reads), `:page_size` (100 feed objects per
      read), `:retry_ms` (1 000, first wait after a store error),
      `:max_backoff_ms` (30 000, the longest wait) and `:max_backlog` (1 000
      messages in a subscriber's mailbox before it is dropped). The tailer
      starts with the first `Atanor.Env.subscribe/3` and stops when the last
      subscription ends. Alambique's own `:feed` options (`:window_ms`,
      `:retention_ms`, `:shards`, ...) stay under `:alambique`.
    * `:migrate` - how awake cells pick up new migrations (design §4.1):
      `:concurrency` (8), `:page_size` (100, cells listed and migrated per
      page) and `:timeout_ms` (`nil`, Alambique's `call_timeout_ms`).
    * `:deployments` - `mix atanor.*` head edits (design §5): `:max_previous`
      (20 packages kept for rollback) and `:max_attempts` (16
      compare-and-swap attempts). The functions of `Atanor.Deployments` take
      the same options.
    * `:ready` - the first load of the deployments, which a node completes
      before it joins the cluster (design §2.1): `:timeout_ms` (60 000, how
      long the start waits for the store before it fails) and `:retry_ms`
      (1 000, between tries; not above `:timeout_ms`).
    * `:release` - the release this node runs (design §17.1): `:id` (default
      `"atanor-" <> the application version`, which is a development
      convenience; production should use an immutable image digest or commit),
      `:built_at` (`nil`) and `:hash_nifs` (true).
    * `:diagnostics` - crash breadcrumbs and reports (design §17.2):
      `:enabled` (true), `:breadcrumbs` (`:durable`; `:off` or `:all`),
      `:dir` (`data_dir/diagnostics`), `:settle_ms` (1 000, wait before
      reading the previous boot's markers so Alambique's quarantine tracker
      can settle), `:max_files` (10 000), `:max_units`
      (1 000), `:pending_retry_ms` (60 000), `:retention_ms` (2 592 000 000)
      and `:cleanup_ms` (3 600 000). `:durable` covers jobs, alarms, sweep
      driver pages, migrations, deployment activation and WebSocket
      connections; `:all` adds every HTTP/TCP callback and is for incident
      reproduction.
    * `:rehearsal` - migration rehearsal on copies of sampled cells (design
      §17.3): `:sample_size` (10, cells per namespace), `:max_cells` (100),
      `:max_scan` (10 000, ids scanned per namespace), `:page_size` (1 000),
      `:concurrency` (2), `:timeout_ms` (120 000, one cell; below `:stale_ms`),
      `:integrity_check` (`:quick_check` or `:integrity_check`),
      `:strict_schema` (false), `:seed` (`nil`, random and recorded), `:dir`
      (`nil`, `data_dir/rehearsals`), `:stale_ms` (600 000, when a `running`
      record reads as stale) and `:retention_ms` (604 800 000). A request may
      lower `:sample_size`, `:max_cells` and `:timeout_ms`, not raise them.
    * `:calls` - limits of calls a worker makes: `:max_depth` (8 nested worker
      calls), `:max_redirects` (5 outbound HTTP redirects),
      `:fetch_max_bytes` (8 000 000, the largest body an outbound HTTP
      response may have) and `:fetch_timeout_ms` (30 000, the time of a whole
      outbound HTTP fetch, redirects and name lookups included).
    * `:http` - the ingress (design §7.1): `:retry_after_s` (1, the
      `Retry-After` of a 503 for expected unavailability, `held_elsewhere` included; design §8.4);
      `:max_connections` (16 384, the total of open connections, WebSockets
      included) shared by `:acceptors` (10); `:read_timeout_ms` (10 000, how
      long the listener waits for the next bytes of a request, header or body,
      before it closes the connection); `:max_path_segments` (64) and
      `:max_host_labels` (16), beyond which a request is 400; and `:http_2`
      (true; false serves HTTP/1.1 only).
    * `:overview` - `:timeout_ms` (5000) of the admin and dashboard calls to
      the other nodes (design §10).
    * `:metadata` - `:page_size` (1000) of the metadata store listings
      (workers and their heads; design §5).
    * `:sockets` - `:attach_timeout_ms` (5000) of a remote WebSocket attach,
      channel join or leave, and of the presence query; a timeout is 503
      `unavailable`, reason `owner_unreachable` (design §7.3, §8.4); and
      `:max_attachments` (16 cells one socket can be attached to, over it
      `{:error, :too_many_attachments}`).
    * `:wasm` - limits of the host calls of WASM workers (design §4.3):
      `:max_batch_bytes` (67 108 864, the largest total size of the results
      of one `batch`, text and blobs by length and 8 bytes for other values;
      over it the batch is rolled back and the guest gets `failed("batch_too_large: ...")`)
      and `:max_cell_message_bytes` (1 048 576, the largest message
      `send-to-cell` accepts; native workers are not limited).
    * `:channels` - limits of the ephemeral channels (design §7.6):
      `:max_message_bytes` (16 384, the largest message `publish` accepts),
      `:max_subscriptions` (16 channels one socket can be in) and
      `:max_channels` (10 000 channels with a subscriber on one node),
      `:max_channels_per_namespace` (2 000 of them in one namespace, so one
      worker cannot use them all) and
      `:max_queue` (1000: a socket with more messages waiting misses the
      next ones, channel and cell messages alike, and `[:atanor, :channel,
      :dropped]` counts them).
    * `:allow_private_hosts` - host names, IP addresses or CIDR blocks that
      outbound HTTP may reach although they resolve to private, loopback or
      link-local addresses (design §4). Default: none.
    * `:secrets` - `%{"worker" => %{"NAME" => "value"}}`: the values of the
      secrets the workers' manifests grant (design §4). Never in manifests.
    * `:memory` - the memory limit of the node and how much of it the awake cells
      may use (design §4.3): `limit_bytes` (default `nil`: read the cgroup),
      `awake_fraction` (0.5, above 0 and at most 1) and `cgroup_path`
      (`/sys/fs/cgroup/memory.max`, cgroup v2; `max` or a missing file is no
      limit). The result is the default of `alambique: [awake: [max_bytes:]]`;
      the node logs it and its source at start.
    * `:max_body_bytes` - largest request body the ingress reads for
      `handle_request/2` workers, 413 above it (default 1,000,000).
    * `:alambique` - extra options for the Alambique instance, passed through
      unchanged, for example `:lease_ttl_ms`, `:idle_timeout_ms` or
      `restore: [edge_bytes: 65_536]` (Alambique documents their defaults).
      Two are checked at start: `:pipeline_depth` (1 to 16; default 8, Alambique's:
      a cell encodes the next batch while earlier ones upload, and callers are
      answered in order, design §19.5) and `:replicas` (`false`, the default, or a keyword
      list: `[]` turns the read replicas on with Alambique's limits, design §19;
      `replicas: [poll_max_ms: 5_000]`, the longest time between refreshes of an idle
      replica, and `query: [reflink: true]`, copy-on-write clones for cached
      replicas, pass through unchecked).
      A request that reads with `consistency: {:bounded, ms}` is answered from a
      replica only when `:replicas` is on.
      The limits of Alambique are checked too (a known key, a positive integer)
      and keep Alambique's defaults: `sql: [statement_timeout_ms: 10_000,
      script_timeout_ms: 60_000, max_result_rows: 100_000, max_result_bytes: 67_108_864,
      max_concurrent_statements: dirty IO schedulers - 2, at least 1]` (a statement over
      one gives the worker `{:error, :statement_timeout}` or
      `{:error, :result_too_large}`; a read over the concurrent limit gets
      `{:error, :busy}`; `script_timeout_ms` bounds migrations and scripts), `awake: [max_cells: 20_000, max_wakes: 256,
      max_pending: 10_000, cache_kib: 512, max_bytes: nil]` (`cache_kib` is the SQLite
      page cache of each awake cell; `max_bytes` hibernates the least used cells
      before the memory of the awake ones passes it, and is derived from `:memory`
      below unless you give it, `nil` meaning no ceiling; a call that cannot be
      served gets `{:error, :overloaded}` or `{:error, :busy}`, a 503 at the
      ingress), `idle_timeout_ms: 300_000` (a positive integer), `local_cache: [max_bytes: 21_474_836_480, interval_ms:
      60_000]` (or `false`) and `wal: [checkpoint_bytes: 67_108_864]`. A wrong
      number of parameters is `{:error, {:bad_params, message}}`. Design §4.3.
      Two more groups are checked and passed through: `compaction: [hold_bytes:
      33_554_432, hold_object_bytes: 1_048_576, moved_scan_ms: 60_000,
      moved_scan_page: 100]` (memory per instance for the
      files a cell just replicated, so a compaction of an awake cell does not read
      them back, 0 turns it off; the time between scans of the store for the cleanups
      of moved cells, and the markers listed per request) and `feed: [object_batches: 16, linger_ms: 250,
      stop_publish_ms: 5_000]` (Atanor sets the first two unless you do: one
      feed object carries up to 16 batches and a lone batch waits up to 250 ms
      for company; a cell that stops publishes what it holds, for up to
      `stop_publish_ms`, 0 turns that off). Conditions: `linger_ms` at most a
      tenth of `feed: [window_ms:]` (10 000), checked at start when
      `object_batches` is above 1; a reader outside the instance uses the same
      Alambique as the nodes; 1 turns grouping off. Design §4.3.
      The feed also takes `retention_ms: 604_800_000` (7 days; `nil` keeps the
      objects for ever; `feed: false` is refused because Atanor reads the feed).
      It also takes `tables: %{"table" => true | false | [omit: ["column"]] | [only:
      ["column"]]}` and `other_tables: :capture | :skip` (what enters the feed;
      default: everything, so an app with a large column its subscribers do not
      read declares `tables: %{"messages" => [omit: ["body"]]}`, and
      `Atanor.Change.row` then lacks that column, which is not NULL)
      and `max_object_bytes: 268_435_456`. Shapes are checked at start; design §4.3,
      docs/how-to-follow-cell-changes.md.
      `compaction` takes `snapshot_ratio: 2.0`, `snapshot_interval_ms:
      604_800_000`, `snapshot_keep_ms: 259_200_000`, `delete_superseded: true`
      and `max_level: 2`; `restore` takes `edge_bytes: 65_536`,
      `fetch_concurrency: 16` and `prefetch_bytes: 67_108_864`; `lazy_restore`
      takes `min_bytes: 4_194_304` (or is `false`), `concurrency`, `batch_bytes`
      and `miss_pages`. All keep Alambique's defaults and are checked at start.

  The WASM engine settings (`:threads`, `:queue`, `:timeout_ms`,
  `:memory_bytes`, `:stderr_bytes`, `:table_elements`, ...) are in the
  `:atanor, :wasm` application environment; `Atanor.Wasm` documents them and
  their defaults.
  """

  alias Atanor.{Config, Registry}

  @doc "Child spec for `{Atanor, opts}`. Raises `ArgumentError` for invalid options."
  @spec child_spec(keyword) :: Supervisor.child_spec()
  def child_spec(opts) do
    config = Config.build(opts)

    %{
      id: {__MODULE__, config.name},
      start: {Atanor.Supervisor, :start_link, [config]},
      type: :supervisor
    }
  end

  @doc "The port the HTTP ingress listens on."
  @spec port(atom) :: :inet.port_number()
  def port(name \\ __MODULE__) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(Registry.http_listener(name))
    port
  end

  @doc """
  Hands the node's cells back and returns `{:ok, status}` when it is done (design §8.11).

  The node reports `draining` on `/health/ready` and `/health/serving` first, runs its jobs out, then
  hibernates every awake cell and releases its lease, so another node takes each one at its next call.
  The listeners keep serving the cells the node still holds, and a call that needs a cell the node no
  longer holds is a 503 `draining`. `status` is `%{state: :drained, hibernated: n, errors: [{cell, reason}],
  duration_ms: ms}`; a cell in `errors` stays with its lease until it expires. The whole drain ends at
  `stop.shutdown_ms`.

  Option `:exit` (default `stop.exit`): `true` stops the node when the drain ends, with status 0 or 1 when
  `errors` is not empty; `false` leaves it running, drained; a function of one argument receives that status
  instead. The admin API and `atanor drain` use the default.
  """
  @spec drain(atom, keyword) :: {:ok, map}
  def drain(name \\ __MODULE__, opts \\ []), do: Atanor.Drain.run(name, opts)

  @doc """
  The state of the drain: `%{state: :idle | :draining | :drained}`. While it runs it adds `cells_at_start`, `done`,
  `left` and `errors` (absent until the jobs have finished and Alambique's drain begins); once drained, what it did.
  """
  @spec drain_status(atom) :: map
  def drain_status(name \\ __MODULE__), do: Atanor.Drain.status(name)

  @doc "The port the admin API listens on."
  @spec admin_port(atom) :: :inet.port_number()
  def admin_port(name \\ __MODULE__) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(Atanor.Admin.listener(name))
    port
  end
end
