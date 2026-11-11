defmodule Atanor.Config do
  @moduledoc false

  @tcp %{idle_timeout_ms: 60_000, max_chunk_bytes: 65_536, max_connections: 16_384, acceptors: 10}
  @websocket %{idle_timeout_ms: 60_000, max_frame_bytes: 1_000_000, max_frames_per_s: 100, frame_burst: 200}
  @alarms %{
    tick_ms: 1_000,
    timeout_ms: 30_000,
    max_attempts: 5,
    page_size: 1_000,
    concurrency: 16,
    backoff_ms: 1_000,
    max_backoff_ms: 60_000,
    shards: 64
  }
  @jobs %{
    max_attempts: 20,
    timeout_ms: 30_000,
    claim_ms: 60_000,
    backoff_ms: 1_000,
    max_backoff_ms: 300_000,
    concurrency: 64,
    worker_concurrency: 8,
    cell_concurrency: 1,
    claim_on_finish: true,
    release_claims: true,
    batch_size: 20,
    wait_ms: 1_000,
    max_payload_bytes: 1_000_000,
    max_pending: 10_000,
    max_cell_bytes: 67_108_864,
    max_cron: 100,
    max_tombstones: 10_000,
    retention_ms: 604_800_000,
    dead_retention_ms: 2_592_000_000,
    purge_limit: 100
  }
  @sweeps %{
    poll_ms: 5_000,
    lease_ttl_ms: 30_000,
    renew_ms: 10_000,
    cell_timeout_ms: 10_000,
    page_size: 100,
    rate_per_s: 50,
    concurrency: 8,
    max_active: 4,
    cell_attempts: 3,
    control_attempts: 10,
    retry_ms: 1_000,
    retention_ms: 2_592_000_000,
    max_records: 1_000,
    reread_ms: 600_000,
    undo: false,
    undo_concurrency: 2,
    undo_max_cells: 1_000,
    undo_timeout_ms: 120_000,
    undo_stale_ms: 600_000
  }
  @sweeps_guards %{
    canary_size: 10,
    canary_gate: "auto",
    canary_window_ms: 60_000,
    canary_timeout_ms: 300_000,
    guard_window_cells: 50,
    guard_error_rate: 0.1,
    guard_min_cells: 10,
    guard_poll_ms: 5_000,
    guard_attempts: 3
  }

  # The node's memory limit and the part of it the awake cells may use (`Atanor.Memory`, design §4.3).
  @memory %{limit_bytes: nil, awake_fraction: 0.5, cgroup_path: "/sys/fs/cgroup/memory.max"}

  # The prefix of Atanor's own tables in a cell (`Atanor.Jobs.Schema`).
  @internal_prefix "_atanor_"

  @feed %{poll_ms: 1_000, page_size: 100, retry_ms: 1_000, max_backoff_ms: 30_000, max_backlog: 1_000}
  @deployments %{max_previous: 20, max_attempts: 16}
  # Largest `atanor.json` and WASM component a package may hold (design §5.1).
  @package Atanor.Package.limits()
  # The first load of the deployments, before the node joins the cluster (design §2.1).
  @ready %{timeout_ms: 60_000, retry_ms: 1_000}
  # Outbound HTTP (design §4.1): the body and the time of a whole fetch, redirects included.
  @calls %{max_depth: 8, max_redirects: 5, fetch_max_bytes: 8_000_000, fetch_timeout_ms: 30_000}
  # The ingress (design §7.1). `max_connections` is the total of the listener, `read_timeout_ms` the wait for
  # the next bytes of the request (header or body), and the last two bound the work of matching a route.
  @http %{
    retry_after_s: 1,
    max_connections: 16_384,
    acceptors: 10,
    read_timeout_ms: 10_000,
    max_path_segments: 64,
    max_host_labels: 16,
    http_2: true
  }
  # The limit of failed token attempts per client address of the admin and the dashboard listeners.
  @throttle %{max_failures: 10, failure_window_ms: 60_000, tracked_addresses: 10_000}
  # The connection settings of the admin listener.
  @admin_net %{
    max_connections: 128,
    acceptors: 4,
    read_timeout_ms: 10_000,
    http_2: true,
    unknown_token_ms: 2_000,
    unknown_tokens: 1_000
  }
  # Fetches of OIDC discovery documents and JWKS for the `:auth` routes (design §7.5).
  @oidc %{
    min_refresh_ms: 60_000,
    error_backoff_ms: 5_000,
    jwks_max_age_ms: 3_600_000,
    jwks_max_stale_ms: 86_400_000,
    discovery_ttl_ms: 3_600_000,
    connect_timeout_ms: 2_000,
    receive_timeout_ms: 5_000,
    max_response_bytes: 1_000_000,
    allow_http: false
  }
  @overview %{timeout_ms: 5_000}
  @metadata %{page_size: 1_000}
  @sockets %{attach_timeout_ms: 5_000, max_attachments: 16}
  @wasm %{max_batch_bytes: 67_108_864, max_cell_message_bytes: 1_048_576}
  @channels %{
    max_message_bytes: 16_384,
    max_subscriptions: 16,
    max_channels: 10_000,
    max_channels_per_namespace: 2_000,
    max_queue: 1_000
  }
  @clock {Alambique.Clock.System, nil}
  @detector %{
    interval_ms: 1_000,
    phi_threshold: 8.0,
    min_std_ms: 200,
    acceptable_pause_ms: 2_000,
    window: 100,
    indirect_k: 3,
    indirect_timeout_ms: 1_000,
    indirect_round_timeout_ms: 1_500,
    reprobe_ms: 1_000,
    reconnect_ms: 1_000,
    stall_intervals: 3,
    seed_spread: 0.25,
    forget_after_ms: 600_000
  }

  # Per-cell takeover of a node confirmed down (design §8.10). nil: Alambique's `call_timeout_ms`.
  # `no_quorum_event_interval_ms`: at most one `:no_quorum` take_over event per interval (design §8.10).
  @takeover %{
    enabled: true,
    quorum: true,
    settle_ms: 2_000,
    attempts: 3,
    timeout_ms: nil,
    no_quorum_event_interval_ms: 10_000
  }
  # Automatic placement of hot cells (design §8.15). Rates are calls per second, `queue` is calls waiting on
  # the cell, `cpu` and `margin` are percent of the node's schedulers. `tags` label this node and `affinity`
  # is `[{namespace, tag}]`: hot cells of the namespace go to a node with the tag. `move: false` keeps the
  # loop from moving cells. `replicas: true` turns on the read replicas of Alambique for a cell read at
  # `replica_enter` reads per second in the cluster (off below `replica_exit`, and not before `replica_hold_ms`);
  # it needs `alambique: [replicas: ...]`.
  @hot_cells %{
    enabled: false,
    interval_ms: 1_000,
    sustain_ms: 10_000,
    write_enter: 500,
    write_exit: 250,
    read_enter: 2_000,
    read_exit: 1_000,
    queue_enter: 50,
    queue_exit: 10,
    cpu_enter: 70,
    cpu_exit: 50,
    os_cpu: true,
    margin: 20,
    residence_ms: 300_000,
    node_cooldown_ms: 30_000,
    max_moves: 1,
    move_timeout_ms: 15_000,
    stale_ms: 5_000,
    max_tracked: 100,
    move: true,
    replicas: false,
    replica_enter: 1_000,
    replica_exit: 500,
    replica_hold_ms: 60_000,
    tags: [],
    affinity: []
  }
  # Retries of a call whose owner moved or was lost, the longest a forwarded call may run, how long a call
  # waits for a leaving owner to hand off (design §8.11), and how a node keeps from starting handlers for a
  # cell it lost (design §8.13).
  @routing %{
    attempts: 3,
    retry_ms: 50,
    remote_timeout_ms: 60_000,
    owner_check: true,
    owner_check_ms: 1_000,
    owner_check_cells: 10_000,
    fence: true,
    fence_check_ms: 1_000,
    fence_defer_after_takeover: true,
    pinned_limit: 16,
    leave_wait_ms: 3_000
  }
  # Graceful stop and drain (design §8.11). `drain_timeout_ms` bounds one cell and `drain_concurrency` the cells
  # handed off at once (Alambique's own defaults); `shutdown_ms` bounds the whole drain. `exit` stops the node
  # when a drain started by `Atanor.drain/2`, the admin API or the CLI ends.
  @stop %{
    drain_timeout_ms: 15_000,
    drain_concurrency: 64,
    exit: true,
    sigterm: :drain,
    shutdown_ms: 75_000,
    connections_ms: 15_000,
    jobs_ms: 15_000,
    sweeps_ms: 5_000,
    tasks_ms: 5_000
  }

  # Migration of awake cells when a worker brings new migrations (design §4.1). nil: Alambique's `call_timeout_ms`.
  @migrate %{concurrency: 8, page_size: 100, timeout_ms: nil}

  # The release this node runs (design §17.1). The id is operator-supplied; the
  # default is a development convenience, not a build identity.
  @release %{
    id: nil,
    built_at: nil,
    hash_nifs: true
  }

  # Migration rehearsal (design §17.3). `dir: nil` is `data_dir/rehearsals`; `seed: nil` is random per run.
  @rehearsal %{
    sample_size: 10,
    max_cells: 100,
    max_scan: 10_000,
    page_size: 1_000,
    concurrency: 2,
    timeout_ms: 120_000,
    integrity_check: :quick_check,
    strict_schema: false,
    seed: nil,
    dir: nil,
    stale_ms: 600_000,
    retention_ms: 604_800_000
  }

  # Crash breadcrumbs and reports (design §17.2).
  @diagnostics %{
    enabled: true,
    breadcrumbs: :durable,
    dir: nil,
    settle_ms: 1_000,
    max_files: 10_000,
    max_units: 1_000,
    pending_retry_ms: 60_000,
    retention_ms: 2_592_000_000,
    cleanup_ms: 3_600_000
  }

  @min_public_token_bytes 32
  @admin_port 4001
  @dashboard_port 4002

  # Secrets and the admin and dashboard tokens are left out of inspect output and crash reports.
  # Grouped feed objects, unless the operator sets them (Alambique `3dc2686`). The window is
  # Alambique's default `feed: [window_ms:]`.
  @feed_groups [object_batches: 16, linger_ms: 250]
  @alambique_window_ms 10_000
  @linger_ratio 10

  @derive {Inspect, except: [:secrets, :admin, :dashboard, :alambique_opts]}
  @enforce_keys [:name, :alambique, :data_dir, :meta_store, :prefix, :port, :ip, :max_body_bytes]
  @type t :: %__MODULE__{}
  defstruct [
    :name,
    :alambique,
    :data_dir,
    :meta_store,
    :prefix,
    :port,
    :ip,
    :max_body_bytes,
    :hosts,
    :namespaces,
    :http_allow,
    :modules,
    :admin,
    :dashboard,
    callers: %{},
    package: @package,
    auth: %{},
    oidc: @oidc,
    detector: @detector,
    takeover: @takeover,
    hot_cells: @hot_cells,
    routing: @routing,
    stop: @stop,
    migrate: @migrate,
    deployments: @deployments,
    ready: @ready,
    calls: @calls,
    http: @http,
    overview: @overview,
    metadata: @metadata,
    sockets: @sockets,
    wasm: @wasm,
    channels: @channels,
    secrets: %{},
    listeners: %{},
    private_hosts: [],
    tcp: @tcp,
    websocket: @websocket,
    alarms: Map.put(@alarms, :clock, @clock),
    jobs: @jobs,
    sweeps: @sweeps,
    feed: @feed,
    release: @release,
    diagnostics: @diagnostics,
    rehearsal: @rehearsal,
    poll_interval_ms: 5_000,
    memory: Map.put(@memory, :awake_source, :none),
    alambique_opts: []
  ]

  @keys [
    :name,
    :data_dir,
    :store,
    :placement,
    :meta_store,
    :prefix,
    :port,
    :ip,
    :secrets,
    :hosts,
    :namespaces,
    :callers,
    :http_allow,
    :modules,
    :package,
    :auth,
    :oidc,
    :listeners,
    :allow_private_hosts,
    :tcp,
    :websocket,
    :alarms,
    :jobs,
    :sweeps,
    :feed,
    :release,
    :diagnostics,
    :rehearsal,
    :admin,
    :dashboard,
    :detector,
    :takeover,
    :hot_cells,
    :routing,
    :stop,
    :migrate,
    :deployments,
    :ready,
    :calls,
    :http,
    :overview,
    :metadata,
    :sockets,
    :wasm,
    :channels,
    :poll_interval_ms,
    :max_body_bytes,
    :memory,
    :alambique
  ]
  @prefix ~r/\A[a-z0-9_-]+(\/[a-z0-9_-]+)*\z/

  # The options of the `alambique:` groups that Atanor checks at start, with the kind of value each takes
  # (`limit?/2`). The other options of `feed:` are checked by Alambique; any other key of these groups is refused.
  @alambique_limits [
    sql: [
      statement_timeout_ms: :positive,
      script_timeout_ms: :positive,
      max_result_rows: :positive,
      max_result_bytes: :positive,
      max_concurrent_statements: :positive
    ],
    awake: [
      max_cells: :positive,
      max_wakes: :positive,
      max_pending: :positive,
      cache_kib: :positive,
      max_bytes: :positive_or_nil
    ],
    wal: [checkpoint_bytes: :positive],
    local_cache: [max_bytes: :positive, interval_ms: :positive],
    restore: [edge_bytes: :positive, fetch_concurrency: :positive, prefetch_bytes: :positive],
    lazy_restore: [min_bytes: :non_negative, concurrency: :positive, batch_bytes: :positive, miss_pages: :positive],
    compaction: [
      hold_bytes: :non_negative,
      hold_object_bytes: :non_negative,
      snapshot_ratio: :ratio,
      snapshot_keep_ms: :non_negative,
      snapshot_interval_ms: :positive,
      delete_superseded: :boolean,
      max_level: :positive,
      moved_scan_ms: :positive,
      moved_scan_page: :positive
    ]
  ]

  @alambique_feed_limits [
    object_batches: :positive,
    linger_ms: :non_negative,
    stop_publish_ms: :non_negative,
    retention_ms: :positive_or_nil,
    tables: :tables,
    other_tables: :other_tables,
    max_object_bytes: :positive
  ]

  # Groups that `false` turns off.
  @alambique_switchable [:local_cache, :lazy_restore]

  # The clock and the skew margin of the leases are those of the Alambique instance.
  @alambique_clock {Alambique.Clock.System, nil}
  @alambique_skew_margin_ms 2_000

  @doc "The clock the cells' leases use: `{module, config}`."
  @spec lease_clock(t) :: {module, term}
  def lease_clock(%__MODULE__{alambique_opts: opts}), do: Keyword.get(opts, :clock, @alambique_clock)

  @doc "The time on the clock the cells' leases use, in milliseconds."
  @spec now_ms(t) :: integer
  def now_ms(%__MODULE__{} = config) do
    {clock, clock_config} = lease_clock(config)
    clock.now_ms(clock_config)
  end

  @doc "The clock skew the cells' leases tolerate, in milliseconds."
  @spec skew_margin_ms(t) :: pos_integer
  def skew_margin_ms(%__MODULE__{alambique_opts: opts}),
    do: Keyword.get(opts, :skew_margin_ms, @alambique_skew_margin_ms)

  @doc "Validates the options of `{Atanor, opts}` and builds the config."
  def build(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "options must be a keyword list")

    case Keyword.keys(opts) -- @keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options: #{inspect(unknown)}"
    end

    name = Keyword.get(opts, :name, Atanor)
    prefix = Keyword.get(opts, :prefix, "atanor")
    port = Keyword.get(opts, :port, 4000)

    check!(is_atom(name) and not is_nil(name), ":name must be an atom")
    check!(is_binary(opts[:data_dir]) and opts[:data_dir] != "", ":data_dir is required")
    check!(is_binary(prefix) and Regex.match?(@prefix, prefix), ":prefix must match #{inspect(@prefix.source)}")
    check!(is_integer(port) and port in 0..65_535, ":port must be an integer from 0 to 65535")
    check!(is_tuple(Keyword.get(opts, :ip, {127, 0, 0, 1})), ":ip must be an address tuple")
    check!(Keyword.keyword?(Keyword.get(opts, :alambique, [])), ":alambique must be a keyword list")
    check!(not Keyword.has_key?(Keyword.get(opts, :alambique, []), :join), ":alambique :join is set by Atanor")
    alambique_opts!(Keyword.get(opts, :alambique, []))
    memory = memory!(opts[:memory])
    {alambique, awake_source} = awake_budget(Keyword.get(opts, :alambique, []), memory)
    user_feed = Keyword.get(Keyword.get(opts, :alambique, []), :feed, [])

    check!(
      not Keyword.has_key?(user_feed, :internal_prefixes),
      ":alambique :feed :internal_prefixes is set by Atanor"
    )

    {placement, meta_store} = storage!(opts, prefix)
    tcp = tcp!(opts[:tcp])
    listeners = listeners!(Keyword.get(opts, :listeners, %{}), Keyword.get(opts, :ip, {127, 0, 0, 1}), tcp)
    max_body_bytes = Keyword.get(opts, :max_body_bytes, 1_000_000)
    check!(is_integer(max_body_bytes) and max_body_bytes > 0, ":max_body_bytes must be a positive integer")
    cells = Module.concat(name, Cells)
    oidc = oidc!(opts[:oidc])

    %__MODULE__{
      name: name,
      alambique: cells,
      data_dir: opts[:data_dir],
      meta_store: meta_store,
      prefix: prefix,
      port: port,
      ip: Keyword.get(opts, :ip, {127, 0, 0, 1}),
      max_body_bytes: max_body_bytes,
      secrets: secrets!(Keyword.get(opts, :secrets, %{})),
      hosts: hosts!(opts[:hosts]),
      namespaces:
        grants!(
          opts[:namespaces],
          :namespaces,
          &(Atanor.Cell.validate_namespace(&1) == :ok),
          &Atanor.Manifest.worker_name?/1
        ),
      callers:
        grants!(opts[:callers], :callers, &Atanor.Manifest.worker_name?/1, &Atanor.Manifest.worker_name?/1) || %{},
      http_allow:
        grants!(opts[:http_allow], :http_allow, &Atanor.Manifest.worker_name?/1, &Atanor.Manifest.host_pattern?/1),
      modules: grants!(opts[:modules], :modules, &Atanor.Manifest.worker_name?/1, &Atanor.Manifest.module_name?/1),
      package: limits!(opts[:package], @package, :package),
      oidc: oidc,
      auth: Atanor.Auth.rules!(opts[:auth], oidc),
      listeners: listeners,
      private_hosts: private_hosts!(Keyword.get(opts, :allow_private_hosts, [])),
      tcp: tcp,
      websocket: limits!(opts[:websocket], @websocket, :websocket),
      alarms: alarms!(opts[:alarms]),
      jobs: jobs!(opts[:jobs]),
      sweeps: sweeps!(opts[:sweeps]),
      feed: feed!(opts[:feed]),
      release: release!(opts[:release]),
      diagnostics: diagnostics!(opts[:diagnostics], opts[:data_dir]),
      rehearsal: rehearsal!(opts[:rehearsal]),
      admin: admin!(opts[:admin]),
      dashboard: dashboard!(opts[:dashboard]),
      detector: detector!(opts[:detector]),
      takeover: settings!(opts[:takeover], @takeover, :takeover),
      hot_cells: hot_cells!(opts[:hot_cells], Keyword.get(opts, :alambique, [])),
      routing: settings!(opts[:routing], @routing, :routing),
      stop: stop!(opts[:stop]),
      migrate: settings!(opts[:migrate], @migrate, :migrate),
      deployments: limits!(opts[:deployments], @deployments, :deployments),
      ready: ready!(opts[:ready]),
      calls: limits!(opts[:calls], @calls, :calls),
      http: http!(opts[:http]),
      overview: limits!(opts[:overview], @overview, :overview),
      metadata: limits!(opts[:metadata], @metadata, :metadata),
      sockets: limits!(opts[:sockets], @sockets, :sockets),
      wasm: limits!(opts[:wasm], @wasm, :wasm),
      channels: limits!(opts[:channels], @channels, :channels),
      poll_interval_ms: poll_interval!(Keyword.get(opts, :poll_interval_ms, 5_000)),
      memory: Map.put(memory, :awake_source, awake_source),
      alambique_opts:
        Keyword.merge(
          alambique,
          [
            name: cells,
            data_dir: opts[:data_dir],
            migrations: Atanor.Migrations.callback(name),
            join: false,
            # Jobs, alarms, cron and undo positions stay out of the change feed. Every node must use
            # the same prefixes, so they are fixed here.
            feed: @feed_groups |> Keyword.merge(user_feed) |> Keyword.put(:internal_prefixes, [@internal_prefix])
          ] ++ placement
        )
    }
  end

  defp memory!(nil), do: @memory

  defp memory!(opts) do
    check!(Keyword.keyword?(opts), ":memory must be a keyword list")
    check!(Keyword.keys(opts) -- Map.keys(@memory) == [], ":memory has only #{inspect(Map.keys(@memory))}")
    memory = Map.merge(@memory, Map.new(opts))

    check!(
      is_nil(memory.limit_bytes) or positive_integer?(memory.limit_bytes),
      ":memory :limit_bytes must be nil or a positive integer"
    )

    check!(
      is_number(memory.awake_fraction) and memory.awake_fraction > 0 and memory.awake_fraction <= 1,
      ":memory :awake_fraction must be a number above 0 and at most 1"
    )

    check!(is_binary(memory.cgroup_path), ":memory :cgroup_path must be a string")
    memory
  end

  # `awake: [max_bytes:]` is the operator's when given (nil: no ceiling); else it follows the memory limit.
  defp awake_budget(alambique, memory) do
    awake = Keyword.get(alambique, :awake, [])

    case Atanor.Memory.awake_max_bytes(memory, Keyword.fetch(awake, :max_bytes)) do
      {max_bytes, source} when source in [:limit_bytes, :cgroup] ->
        {Keyword.put(alambique, :awake, Keyword.put(awake, :max_bytes, max_bytes)), source}

      {_, source} ->
        {alambique, source}
    end
  end

  defp storage!(opts, prefix) do
    case {opts[:store], opts[:placement]} do
      {nil, nil} ->
        raise ArgumentError, "give :store or :placement"

      {store, nil} ->
        check!(match?({m, _} when is_atom(m), store), ":store must be {module, config}")
        check!(is_nil(opts[:meta_store]), ":meta_store is only for :placement")
        store = Alambique.Store.conceal(store)
        {[store: store, prefix: prefix <> "/cells"], store}

      {nil, placement} ->
        check!(match?({m, _} when is_atom(m), placement), ":placement must be {module, opts}")

        check!(
          match?({m, _} when is_atom(m), opts[:meta_store]),
          ":placement needs :meta_store as {module, config}"
        )

        {[placement: placement], Alambique.Store.conceal(opts[:meta_store])}

      {_, _} ->
        raise ArgumentError, "give :store or :placement, not both"
    end
  end

  defp secrets!(secrets) do
    valid? =
      is_map(secrets) and
        Enum.all?(secrets, fn {worker, values} ->
          is_binary(worker) and is_map(values) and
            Enum.all?(values, &match?({k, v} when is_binary(k) and is_binary(v), &1))
        end)

    check!(valid?, ":secrets must be a map from worker name to a map of secret name to value (strings)")
    secrets
  end

  defp hosts!(nil), do: nil

  defp hosts!(hosts) do
    valid? =
      is_map(hosts) and
        Enum.all?(hosts, fn {worker, patterns} ->
          is_binary(worker) and is_list(patterns) and Enum.all?(patterns, &Atanor.Manifest.host_pattern?/1)
        end)

    check!(valid?, ":hosts must map worker names to lists of host patterns (\"host\" or \"*.domain\")")
    hosts
  end

  # An operator map from a name to the list of values it may use; absent means no map.
  defp grants!(nil, _option, _key?, _value?), do: nil

  defp grants!(map, option, key?, value?) do
    valid? =
      is_map(map) and
        Enum.all?(map, fn {key, values} -> key?.(key) and is_list(values) and Enum.all?(values, value?) end)

    check!(valid?, ":#{option} must map names to lists of valid entries")
    map
  end

  defp listeners!(listeners, ip, tcp) do
    check!(is_map(listeners), ":listeners must be a map from listener names to ports or keyword lists")

    Map.new(listeners, fn {name, entry} ->
      check!(is_binary(name) and name =~ ~r/\A[a-z0-9_-]+\z/, ":listeners names must match [a-z0-9_-]+")
      {name, Atanor.TCP.Listener.build!(name, entry, ip, tcp)}
    end)
  end

  # Keyword overrides of positive-integer defaults.
  defp limits!(nil, defaults, _option), do: defaults

  defp limits!(opts, defaults, option) do
    valid? =
      Keyword.keyword?(opts) and
        Enum.all?(opts, fn {key, value} -> is_map_key(defaults, key) and is_integer(value) and value > 0 end)

    check!(valid?, ":#{option} must be a keyword list with positive integers for #{inspect(Map.keys(defaults))}")
    Map.merge(defaults, Map.new(opts))
  end

  defp oidc!(opts) do
    oidc = settings!(opts, @oidc, :oidc)
    check!(oidc.error_backoff_ms <= oidc.min_refresh_ms, ":oidc :error_backoff_ms must not exceed :min_refresh_ms")
    oidc
  end

  defp ready!(opts) do
    ready = limits!(opts, @ready, :ready)
    check!(ready.retry_ms <= ready.timeout_ms, ":ready :retry_ms must not exceed :timeout_ms")
    ready
  end

  defp tcp!(opts) do
    tcp = limits!(opts, @tcp, :tcp)
    check!(tcp.acceptors <= tcp.max_connections, ":tcp :acceptors must not exceed :max_connections")
    tcp
  end

  defp stop!(opts) do
    stop = settings!(opts, @stop, :stop)
    check!(stop.sigterm in [:drain, :stop], ":stop :sigterm must be :drain or :stop")
    check!(stop.drain_timeout_ms <= stop.shutdown_ms, ":stop :drain_timeout_ms must not exceed :shutdown_ms")
    stop
  end

  defp http!(opts) do
    http = settings!(opts, @http, :http)
    check!(http.acceptors <= http.max_connections, ":http :acceptors must not exceed :max_connections")
    http
  end

  defp jobs!(nil), do: @jobs

  defp jobs!(opts) do
    {dead, opts} = if Keyword.keyword?(opts), do: Keyword.pop(opts, :dead_retention_ms), else: {nil, opts}
    jobs = settings!(opts, @jobs, :jobs)

    dead =
      case dead do
        nil -> @jobs.dead_retention_ms
        :infinity -> :infinity
        value when is_integer(value) and value > 0 -> value
        _ -> raise ArgumentError, ":jobs :dead_retention_ms must be a positive integer or :infinity"
      end

    check!(jobs.claim_ms > jobs.timeout_ms, ":jobs :claim_ms must be greater than :timeout_ms")
    check!(jobs.backoff_ms <= jobs.max_backoff_ms, ":jobs :backoff_ms must not exceed :max_backoff_ms")
    check!(jobs.worker_concurrency <= jobs.concurrency, ":jobs :worker_concurrency must not exceed :concurrency")

    check!(
      jobs.cell_concurrency <= jobs.worker_concurrency,
      ":jobs :cell_concurrency must not exceed :worker_concurrency"
    )

    Map.put(jobs, :dead_retention_ms, dead)
  end

  defp sweeps!(nil), do: Map.merge(@sweeps, @sweeps_guards)

  defp sweeps!(opts) do
    {guards, opts} = if Keyword.keyword?(opts), do: Keyword.split(opts, Map.keys(@sweeps_guards)), else: {[], opts}
    guards = Map.merge(@sweeps_guards, Map.new(guards))

    case Atanor.Sweeps.check_options(guards) do
      :ok -> :ok
      {:error, message} -> check!(false, ":sweeps #{message}")
    end

    sweeps = opts |> settings!(@sweeps, :sweeps) |> Map.merge(guards)
    check!(sweeps.renew_ms < sweeps.lease_ttl_ms, ":sweeps :renew_ms must be less than :lease_ttl_ms")
    check!(sweeps.cell_timeout_ms < sweeps.lease_ttl_ms, ":sweeps :cell_timeout_ms must be less than :lease_ttl_ms")
    sweeps
  end

  defp feed!(nil), do: @feed

  defp feed!(opts) do
    feed = settings!(opts, @feed, :feed)
    check!(feed.retry_ms <= feed.max_backoff_ms, ":feed :retry_ms must not exceed :max_backoff_ms")
    feed
  end

  defp release!(nil), do: %{@release | id: Atanor.Release.default_id()}

  defp release!(opts) do
    check!(
      Keyword.keyword?(opts) and Keyword.keys(opts) -- Map.keys(@release) == [],
      ":release must be a keyword list with #{inspect(Map.keys(@release))}"
    )

    release = Map.merge(@release, Map.new(opts))
    id = release.id || Atanor.Release.default_id()

    check!(
      is_binary(id) and id != "" and byte_size(id) <= 128 and String.valid?(id) and
        not String.contains?(id, ["\n", "\r", <<0>>]),
      ":release :id must be a non-empty string of at most 128 printable bytes"
    )

    check!(
      is_nil(release.built_at) or (is_binary(release.built_at) and release.built_at != ""),
      ":release :built_at must be a non-empty string (ISO 8601) or nil"
    )

    check!(is_boolean(release.hash_nifs), ":release :hash_nifs must be a boolean")

    %{release | id: id}
  end

  defp diagnostics!(nil, data_dir), do: %{@diagnostics | dir: Path.join(data_dir, "diagnostics")}

  defp diagnostics!(opts, data_dir) do
    check!(
      Keyword.keyword?(opts) and Keyword.keys(opts) -- Map.keys(@diagnostics) == [],
      ":diagnostics must be a keyword list with #{inspect(Map.keys(@diagnostics))}"
    )

    diagnostics = Map.merge(@diagnostics, Map.new(opts))
    check!(is_boolean(diagnostics.enabled), ":diagnostics :enabled must be a boolean")

    check!(
      diagnostics.breadcrumbs in [:off, :durable, :all],
      ":diagnostics :breadcrumbs must be :off, :durable or :all"
    )

    dir = diagnostics.dir || Path.join(data_dir, "diagnostics")
    check!(is_binary(dir) and dir != "", ":diagnostics :dir must be a non-empty path or nil")

    for key <- [:max_files, :max_units, :pending_retry_ms, :retention_ms, :cleanup_ms] do
      check!(positive_integer?(diagnostics[key]), ":diagnostics #{inspect(key)} must be a positive integer")
    end

    check!(
      is_integer(diagnostics.settle_ms) and diagnostics.settle_ms >= 0,
      ":diagnostics :settle_ms must be a non-negative integer"
    )

    %{diagnostics | dir: dir}
  end

  defp rehearsal!(nil), do: @rehearsal

  defp rehearsal!(opts) do
    check!(
      Keyword.keyword?(opts) and Keyword.keys(opts) -- Map.keys(@rehearsal) == [],
      ":rehearsal must be a keyword list with #{inspect(Map.keys(@rehearsal))}"
    )

    rehearsal = Map.merge(@rehearsal, Map.new(opts))

    for key <- [:sample_size, :max_cells, :max_scan, :page_size, :concurrency, :timeout_ms, :stale_ms, :retention_ms] do
      check!(positive_integer?(rehearsal[key]), ":rehearsal #{inspect(key)} must be a positive integer")
    end

    check!(
      rehearsal.integrity_check in [:quick_check, :integrity_check],
      ":rehearsal :integrity_check must be :quick_check or :integrity_check"
    )

    check!(is_boolean(rehearsal.strict_schema), ":rehearsal :strict_schema must be a boolean")
    check!(is_nil(rehearsal.seed) or is_integer(rehearsal.seed), ":rehearsal :seed must be an integer or nil")

    check!(
      is_nil(rehearsal.dir) or (is_binary(rehearsal.dir) and rehearsal.dir != ""),
      ":rehearsal :dir must be a non-empty path or nil"
    )

    check!(rehearsal.sample_size <= rehearsal.max_cells, ":rehearsal :sample_size must not exceed :max_cells")
    check!(rehearsal.timeout_ms < rehearsal.stale_ms, ":rehearsal :timeout_ms must be less than :stale_ms")
    rehearsal
  end

  defp settings!(nil, defaults, _option), do: defaults

  defp settings!(opts, defaults, option) do
    valid? =
      Keyword.keyword?(opts) and
        Enum.all?(opts, fn {key, value} -> is_map_key(defaults, key) and setting?(defaults[key], value) end)

    check!(
      valid?,
      ":#{option} must be a keyword list for #{inspect(Map.keys(defaults))}: booleans or positive integers"
    )

    Map.merge(defaults, Map.new(opts))
  end

  # The options of the Alambique instance that Atanor relies on are checked at start, so a mistake is not
  # found by the first cell.
  defp alambique_opts!(opts) do
    check!(
      positive_integer?(Keyword.get(opts, :idle_timeout_ms, 1)),
      ":alambique :idle_timeout_ms must be a positive integer"
    )

    depth = Keyword.get(opts, :pipeline_depth, 8)
    check!(is_integer(depth) and depth in 1..16, ":alambique :pipeline_depth must be an integer from 1 to 16")

    check!(
      Keyword.get(opts, :replicas, false) == false or Keyword.keyword?(opts[:replicas]),
      ":alambique :replicas must be false or a keyword list"
    )

    for {name, kinds} <- @alambique_limits do
      case Keyword.get(opts, name, []) do
        false when name in @alambique_switchable -> :ok
        group -> alambique_group!(name, group, kinds)
      end
    end

    # Atanor reads the change feed (tailer, subscriptions, rewind markers), so it cannot be turned off.
    # Zero turns holding off; `linger_ms: 0` never waits and `stop_publish_ms: 0` publishes nothing at a stop.
    # `retention_ms: nil` keeps the feed objects for ever; unset, Alambique's seven days apply.
    feed = Keyword.get(opts, :feed, [])
    check!(feed != false, ":alambique :feed cannot be false: Atanor reads the change feed (design §16)")
    check!(Keyword.keyword?(feed), ":alambique :feed must be a keyword list")
    alambique_group!(:feed, Keyword.take(feed, Keyword.keys(@alambique_feed_limits)), @alambique_feed_limits)
    feed_linger!(Keyword.merge(@feed_groups, feed))
  end

  # A lingering sender holds batches the feed's window has not seen yet, so `linger_ms` must stay well below
  # `window_ms`: at most a tenth of it (250 against its 10 000 is a
  # fortieth). Without grouping, nothing lingers.
  defp feed_linger!(feed) do
    window = Keyword.get(feed, :window_ms, @alambique_window_ms)

    check!(
      feed[:object_batches] == 1 or not is_integer(window) or feed[:linger_ms] * @linger_ratio <= window,
      ":alambique :feed :linger_ms (#{feed[:linger_ms]}) must be at most 1/#{@linger_ratio} of :window_ms (#{window}); " <>
        "lower :linger_ms, raise :window_ms, or set :object_batches to 1"
    )
  end

  defp alambique_group!(name, opts, kinds) do
    check!(Keyword.keyword?(opts), ":alambique #{inspect(name)} must be a keyword list")

    for {key, value} <- opts do
      check!(
        Keyword.has_key?(kinds, key),
        ":alambique #{inspect(name)} has no option #{inspect(key)} (known: #{inspect(Keyword.keys(kinds))})"
      )

      check!(limit?(kinds[key], value), ":alambique #{inspect(name)} #{inspect(key)} must be #{must(kinds[key])}")
    end
  end

  defp limit?(:positive, value), do: is_integer(value) and value >= 1
  defp limit?(:non_negative, value), do: is_integer(value) and value >= 0
  defp limit?(:positive_or_nil, value), do: is_nil(value) or limit?(:positive, value)
  defp limit?(:ratio, value), do: is_number(value) and value > 0
  defp limit?(:boolean, value), do: is_boolean(value)
  defp limit?(:other_tables, value), do: value in [:capture, :skip]

  # The rules of Alambique's own check: names are non-empty valid strings, a selection is a boolean or a list
  # of exactly one `omit:` or `only:` with a list of column names.
  defp limit?(:tables, tables) when is_map(tables),
    do: Enum.all?(tables, fn {name, spec} -> name?(name) and selection?(spec) end)

  defp limit?(:tables, _), do: false

  defp selection?(spec) when is_boolean(spec), do: true
  defp selection?([{kind, columns}]) when kind in [:omit, :only], do: is_list(columns) and Enum.all?(columns, &name?/1)
  defp selection?(_), do: false

  defp name?(name), do: is_binary(name) and name != "" and String.valid?(name)

  defp must(:positive), do: "a positive integer"
  defp must(:non_negative), do: "a non-negative integer"
  defp must(:positive_or_nil), do: "nil or a positive integer"
  defp must(:ratio), do: "a number above 0"
  defp must(:boolean), do: "true or false"
  defp must(:other_tables), do: ":capture or :skip"

  defp must(:tables),
    do:
      "a map of non-empty table name to true, false, [omit: columns] or [only: columns] (columns are non-empty strings)"

  defp hot_cells!(nil, _alambique), do: @hot_cells

  defp hot_cells!(opts, alambique) do
    check!(Keyword.keyword?(opts), ":hot_cells must be a keyword list")
    {tags, opts} = Keyword.pop(opts, :tags, [])
    {affinity, opts} = Keyword.pop(opts, :affinity, [])

    check!(
      is_list(tags) and Enum.all?(tags, &(is_binary(&1) and &1 != "")),
      ":hot_cells :tags must be a list of strings"
    )

    rule? = fn
      {ns, tag} when is_binary(ns) and is_binary(tag) and tag != "" -> Atanor.Cell.validate_namespace(ns) == :ok
      _ -> false
    end

    check!(is_list(affinity) and Enum.all?(affinity, rule?), ":hot_cells :affinity must be a list of {namespace, tag}")
    hot = settings!(opts, Map.drop(@hot_cells, [:tags, :affinity]), :hot_cells)

    for {exit, enter} <- [
          write_exit: :write_enter,
          read_exit: :read_enter,
          queue_exit: :queue_enter,
          cpu_exit: :cpu_enter,
          replica_exit: :replica_enter
        ] do
      check!(hot[exit] < hot[enter], ":hot_cells :#{exit} must be below :#{enter}")
    end

    check!(hot.cpu_enter <= 100 and hot.margin <= 100, ":hot_cells :cpu_enter and :margin are percentages")

    check!(
      not hot.replicas or Keyword.get(alambique, :replicas, false) != false,
      ":hot_cells :replicas needs the Alambique replicas: give alambique: [replicas: []]"
    )

    Map.merge(hot, %{tags: tags, affinity: affinity})
  end

  defp setting?(default, value) when is_boolean(default), do: is_boolean(value)
  defp setting?(default, value) when is_atom(default) and not is_nil(default), do: is_atom(value)
  defp setting?(nil, value), do: is_nil(value) or positive_integer?(value)
  defp setting?(_default, value), do: positive_integer?(value)

  defp alarms!(nil), do: Map.put(@alarms, :clock, @clock)

  defp alarms!(opts) do
    {clock, opts} = if Keyword.keyword?(opts), do: Keyword.pop(opts, :clock, @clock), else: {nil, opts}
    check!(match?({m, _} when is_atom(m), clock), ":alarms :clock must be {module, config}")
    limits!(opts, @alarms, :alarms) |> Map.put(:clock, clock)
  end

  defp detector!(nil), do: @detector

  defp detector!(opts) do
    {indirect, opts} = if Keyword.keyword?(opts), do: Keyword.pop(opts, :indirect, []), else: {nil, opts}

    valid? =
      Keyword.keyword?(opts) and Keyword.keyword?(indirect) and
        Keyword.keys(indirect) -- [:k, :timeout_ms, :round_timeout_ms] == []

    check!(valid?, ":detector must be a keyword list; :indirect takes :k, :timeout_ms and :round_timeout_ms")

    detector =
      Map.merge(@detector, Map.new(opts))
      |> Map.put(:indirect_k, Keyword.get(indirect, :k, @detector.indirect_k))
      |> Map.put(:indirect_timeout_ms, Keyword.get(indirect, :timeout_ms, @detector.indirect_timeout_ms))
      |> Map.put(
        :indirect_round_timeout_ms,
        Keyword.get(indirect, :round_timeout_ms, @detector.indirect_round_timeout_ms)
      )

    check!(Map.keys(detector) -- Map.keys(@detector) == [], ":detector options are #{inspect(Map.keys(@detector))}")

    for key <- [
          :interval_ms,
          :min_std_ms,
          :window,
          :indirect_timeout_ms,
          :indirect_round_timeout_ms,
          :reprobe_ms,
          :reconnect_ms,
          :stall_intervals,
          :forget_after_ms
        ],
        do: check!(positive_integer?(detector[key]), ":detector #{key} must be a positive integer")

    check!(
      is_integer(detector.acceptable_pause_ms) and detector.acceptable_pause_ms >= 0,
      ":detector acceptable_pause_ms must be a non-negative integer"
    )

    check!(
      is_integer(detector.indirect_k) and detector.indirect_k >= 0,
      ":detector indirect k must be a non-negative integer"
    )

    check!(
      is_number(detector.seed_spread) and detector.seed_spread >= 0 and detector.seed_spread < 1,
      ":detector seed_spread must be a number from 0 to below 1"
    )

    check!(
      is_number(detector.phi_threshold) and detector.phi_threshold > 0,
      ":detector phi_threshold must be a positive number"
    )

    %{detector | phi_threshold: detector.phi_threshold * 1.0}
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  # The admin API and the dashboard: a token-protected listener on its own port.
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false

  defp listener!(opts, option, default_port, extra) do
    allowed = [:token, :port, :ip] ++ extra
    valid? = Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == []
    check!(valid?, ":#{option} must be a keyword list with #{Enum.map_join(allowed, ", ", &inspect/1)}")
    token = opts[:token]
    port = Keyword.get(opts, :port, default_port)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    check!(is_binary(token) and token != "", ":#{option} needs a :token (a non-empty string)")
    check!(is_integer(port) and port in 0..65_535, ":#{option} :port must be an integer from 0 to 65535")
    check!(is_tuple(ip), ":#{option} :ip must be an address tuple")

    check!(
      byte_size(token) >= @min_public_token_bytes or loopback?(ip),
      ":#{option} :token must be at least #{@min_public_token_bytes} bytes unless :ip is a loopback address"
    )

    %{token: token, port: port, ip: ip}
  end

  defp throttle!(opts, option), do: settings!(Keyword.take(opts, Map.keys(@throttle)), @throttle, option)

  defp admin!(nil), do: nil

  defp admin!(opts) do
    net_keys = Map.keys(@admin_net)
    throttle_keys = Map.keys(@throttle)

    admin =
      listener!(
        opts,
        :admin,
        @admin_port,
        [:default_limit, :max_limit, :max_package_bytes, :max_scopes] ++ net_keys ++ throttle_keys
      )

    net = settings!(Keyword.take(opts, net_keys), @admin_net, :admin)
    check!(net.acceptors <= net.max_connections, ":admin :acceptors must not exceed :max_connections")
    default_limit = Keyword.get(opts, :default_limit, 100)
    max_limit = Keyword.get(opts, :max_limit, 1_000)
    max_package_bytes = Keyword.get(opts, :max_package_bytes, 67_108_864)
    max_scopes = Keyword.get(opts, :max_scopes, 64)
    check!(positive_integer?(max_package_bytes), ":admin :max_package_bytes must be a positive integer")
    check!(positive_integer?(max_scopes), ":admin :max_scopes must be a positive integer")
    check!(positive_integer?(default_limit), ":admin :default_limit must be a positive integer")
    check!(positive_integer?(max_limit), ":admin :max_limit must be a positive integer")
    check!(default_limit <= max_limit, ":admin :default_limit must not exceed :max_limit")

    Map.merge(admin, net)
    |> Map.merge(throttle!(opts, :admin))
    |> Map.merge(%{
      default_limit: default_limit,
      max_limit: max_limit,
      max_package_bytes: max_package_bytes,
      max_scopes: max_scopes
    })
  end

  defp dashboard!(nil), do: nil

  defp dashboard!(opts) do
    dashboard =
      listener!(
        opts,
        :dashboard,
        @dashboard_port,
        [
          :page_size,
          :max_page_size,
          :poll_ms,
          :cookie_max_age_s,
          :secure_cookie
        ] ++ Map.keys(@throttle)
      )

    page_size = Keyword.get(opts, :page_size, 50)
    max_page_size = Keyword.get(opts, :max_page_size, 500)
    poll_ms = Keyword.get(opts, :poll_ms, 5_000)
    cookie_max_age_s = Keyword.get(opts, :cookie_max_age_s, 86_400)
    secure_cookie = Keyword.get(opts, :secure_cookie, false)
    check!(positive_integer?(page_size), ":dashboard :page_size must be a positive integer")
    check!(positive_integer?(max_page_size), ":dashboard :max_page_size must be a positive integer")
    check!(page_size <= max_page_size, ":dashboard :page_size must not exceed :max_page_size")
    check!(positive_integer?(poll_ms), ":dashboard :poll_ms must be a positive integer")
    check!(positive_integer?(cookie_max_age_s), ":dashboard :cookie_max_age_s must be a positive integer")
    check!(is_boolean(secure_cookie), ":dashboard :secure_cookie must be true or false")

    check!(
      Atanor.Dashboard.available?(),
      ":dashboard needs these dependencies in your project (then `mix deps.compile atanor --force`): " <>
        Atanor.Dashboard.dependencies()
    )

    Map.merge(dashboard, throttle!(opts, :dashboard))
    |> Map.merge(%{
      page_size: page_size,
      max_page_size: max_page_size,
      poll_ms: poll_ms,
      cookie_max_age_s: cookie_max_age_s,
      secure_cookie: secure_cookie
    })
  end

  defp private_hosts!(entries) do
    check!(is_list(entries), ":allow_private_hosts must be a list of host names, IP addresses or CIDR blocks")

    Enum.map(entries, fn entry ->
      case Atanor.Egress.parse_entry(entry) do
        {:ok, parsed} -> parsed
        :error -> raise ArgumentError, ":allow_private_hosts: invalid entry #{inspect(entry)}"
      end
    end)
  end

  defp poll_interval!(ms) do
    check!(is_integer(ms) and ms > 0, ":poll_interval_ms must be a positive integer")
    ms
  end

  defp check!(true, _), do: :ok
  defp check!(false, message), do: raise(ArgumentError, message)
end
