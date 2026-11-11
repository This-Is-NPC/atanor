defmodule Atanor.Env do
  @moduledoc """
  What a worker can use (design §4): the bindings its manifest grants.
  Anything else returns `{:error, {:not_granted, binding}}`, where `binding`
  is `{:cell, namespace}`, `{:secret, name}`, `{:http, host}`, `{:worker,
  name}`, `:alarms` or `:sockets`.

  A worker can read the change feed of a namespace under its `cells` binding
  with `changes/4`, and follow it with `subscribe/3` and `unsubscribe/2`
  (design §16). The feed is native-only: WASM workers have no import for it.

  The env carries the deployment resolved at ingress for the whole request,
  and the ids of the deployments of the workers it can call, resolved with it (`new/2`).
  In a WebSocket callback it also carries the socket process. In the local
  WebSocket callback (`c:Atanor.Worker.handle_ws_local/3`) the cells are not
  granted: every cell function returns `{:error, {:not_granted, {:cell, ns}}}`,
  and only the channel functions (`publish/3`, `channel_members/2`) work.
  """

  alias Atanor.{
    Alarms,
    Auth,
    Cell,
    Change,
    Channels,
    Egress,
    Feed,
    Jobs,
    Manifest,
    Partition,
    Registry,
    Request,
    Response,
    Sockets,
    Workers
  }

  @methods ~w(GET POST PUT PATCH DELETE HEAD)

  @enforce_keys [:instance, :deployment]
  defstruct [:instance, :deployment, :socket, depth: 0, local: false, consistency: :strong, pins: %{}]

  @type consistency :: :strong | {:bounded, pos_integer}

  @type t :: %__MODULE__{
          instance: atom,
          deployment: Atanor.Deployment.t(),
          socket: pid | nil,
          depth: non_neg_integer,
          local: boolean,
          consistency: consistency,
          pins: %{String.t() => String.t()}
        }
  @type not_granted :: {:error, {:not_granted, term}}

  @doc """
  The env of a request served by `deployment`. The id of the active deployment of
  every worker reachable through `workers` bindings is pinned now (memory, no
  store read, only the id and the worker names are copied), so nested calls
  (`call/3`) reach the same versions to the end of the request.
  """
  @spec new(atom, Atanor.Deployment.t()) :: t
  def new(instance, deployment) do
    pins = pin(instance, deployment.manifest.workers, %{Atanor.Deployment.worker(deployment) => deployment.id})
    %__MODULE__{instance: instance, deployment: deployment, pins: pins}
  end

  defp pin(_instance, [], pins), do: pins

  defp pin(instance, names, pins) do
    Enum.reduce(names, pins, fn name, pins ->
      with false <- is_map_key(pins, name),
           {:ok, id, workers} <- Registry.pin(instance, name) do
        pin(instance, workers, Map.put(pins, name, id))
      else
        _ -> pins
      end
    end)
  end

  @doc "The worker's name."
  @spec worker(t) :: String.t()
  def worker(%__MODULE__{deployment: deployment}), do: Atanor.Deployment.worker(deployment)

  @doc """
  The physical cell that holds `partition_key` of the logical cell `{namespace,
  key}`, for a namespace that declares `partitions` (design §4.2). Use the
  address with every cell function: queries, transactions, jobs, alarms,
  sockets and channels. The same partition key always gives the same cell.

  `{:error, {:not_partitioned, namespace}}` when the namespace has no
  partitions; `{:error, :invalid_key}` for a key that is not a valid cell key.
  """
  @spec partition(t, Cell.address(), binary) :: {:ok, Cell.address()} | not_granted | {:error, term}
  def partition(%__MODULE__{} = env, {ns, _} = cell, partition_key) do
    with :ok <- cell_granted(env, ns),
         {:ok, n} <- partition_count(env, ns),
         do: Partition.address(cell, partition_key, n)
  end

  @doc """
  All the physical cells of the logical cell `{namespace, key}`, in partition
  order, to read across partitions (design §4.2). The cells can be on different
  nodes; query them one by one.
  """
  @spec partitions(t, Cell.address()) :: {:ok, [Cell.address()]} | not_granted | {:error, term}
  def partitions(%__MODULE__{} = env, {ns, _} = cell) do
    with :ok <- cell_granted(env, ns), {:ok, n} <- partition_count(env, ns), do: Partition.addresses(cell, n)
  end

  defp partition_count(env, ns) do
    case Registry.partitions(env.instance, ns) do
      nil -> {:error, {:not_partitioned, ns}}
      n -> {:ok, n}
    end
  end

  @doc """
  Runs a read statement on a cell. See `Atanor.Cell.query/5`. Options:

    * `verify_lease: true` for a read that must see every acknowledged write, also
      right after a takeover (design §8.12). It costs one store read per read.
    * `consistency: :strong | {:bounded, ms}`. `:strong`, the default, is answered
      by the owner. `{:bounded, ms}` (a positive integer) accepts an answer that
      misses writes acknowledged less than `ms` milliseconds before the read
      started, and lets a node that does not own the cell answer from a local
      replica (design §19). Without replicas for the cell it is answered by the
      owner, so it is always correct to ask. In a request that the worker's
      `route_key/2` declared bounded, the default is that request's bound.

  `{:error, {:invalid_option, key}}` for an unknown option, a bad value, or
  `{:bounded, _}` together with `verify_lease: true`. In a bounded request
  (`route_key/2` returned `consistency: {:bounded, ms}`) `execute/5`,
  `transaction/4`, the alarm and job functions return `{:error, :read_only}`.
  WASM guests read with `query` (strong) and `query-bounded`.
  """
  @spec query(t, Cell.address(), String.t(), list, keyword) :: {:ok, map} | not_granted | {:error, term}
  def query(env, {ns, _} = address, sql, params \\ [], opts \\ []) do
    with :ok <- cell_granted(env, ns),
         {:ok, opts} <- read_options(env, opts),
         do: Cell.query(env.instance, address, sql, params, opts)
  end

  @read_options [:verify_lease, :consistency, :timeout]

  defp read_options(env, opts) do
    with :ok <- if(Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_option, :opts}}),
         :ok <- unknown_options(Keyword.keys(opts) -- @read_options),
         opts = Keyword.put_new(opts, :consistency, default_consistency(env, opts)),
         :ok <- consistency(opts[:consistency], opts[:verify_lease]) do
      {:ok, opts}
    end
  end

  # A read that asks for the lease check is strong whatever the request's bound.
  defp default_consistency(env, opts), do: if(opts[:verify_lease] == true, do: :strong, else: env.consistency)

  defp unknown_options([]), do: :ok
  defp unknown_options([key | _]), do: {:error, {:invalid_option, key}}

  defp consistency(:strong, _verify), do: :ok
  defp consistency({:bounded, ms}, verify) when is_integer(ms) and ms > 0 and verify != true, do: :ok
  defp consistency(_other, _verify), do: {:error, {:invalid_option, :consistency}}

  @doc """
  Runs a write statement on a cell. See `Atanor.Cell.execute/5`. When the write
  was sent to the owner on another node and the connection failed, the answer
  is `{:error, :outcome_unknown}`: it may have been applied, and it is not
  repeated. If the handler then fails (a 5xx or a crash) Atanor answers 503
  `unknown_outcome`, as for a forwarded call that was lost (design §8.4). Pass
  `idempotent: true` when repeating the statement is harmless; Alambique then
  repeats it. WASM guests have no such option.
  """
  def execute(env, {ns, _} = address, sql, params \\ [], opts \\ []),
    do: with_writable_cell(env, ns, &Cell.execute(&1, address, sql, params, opts))

  @doc """
  Runs a function in one transaction on a cell. See `Atanor.Cell.transaction/4`;
  the options and `{:error, :outcome_unknown}` are those of `execute/5`.
  """
  def transaction(env, {ns, _} = address, fun, opts \\ []),
    do: with_writable_cell(env, ns, &Cell.transaction(&1, address, fun, opts))

  @doc """
  Reads up to `limit` feed objects after `position` (one object can carry
  several row changes) (design §16). `nil` starts at the oldest retained
  change. Returns the changes and the position to continue from; store it and
  pass it back to continue.

  Only cells of the granted `namespace` are returned. Atanor's own
  `_atanor_*` tables are not in the feed. The position is Alambique's opaque,
  instance-wide position: one read can return fewer changes than `limit` after
  filtering (or more when a batch carries several rows), and `next_position`
  can be the same as `position` when nothing new has settled. Delivery is at
  least once; `Atanor.Change.id` is the idempotency key.

  When a cell is rewound the list holds an `Atanor.Change.Rewind` marker after
  the changes it undoes: put your copy of the cell back to the state at
  `to_txid` (design §16.6).
  """
  @spec changes(t, String.t(), Feed.position(), pos_integer) ::
          {:ok, [Change.t() | Change.Rewind.t()], Feed.position()} | not_granted | {:error, term}
  def changes(%__MODULE__{} = env, namespace, position, limit) do
    with :ok <- cell_granted(env, namespace),
         :ok <- valid_limit(limit) do
      Feed.read_changes(env.instance, namespace, position, limit)
    end
  end

  defp valid_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp valid_limit(_), do: {:error, :bad_limit}

  @doc """
  The change feed position at `:now`, for `subscribe/3`'s `from:` or as a
  starting point for `changes/4`. The time is moved back by the instance's
  Alambique `skew_margin_ms`, so a publisher whose clock is behind cannot slip
  a change behind the position. A `:now` subscription can therefore repeat up
  to the margin of earlier changes. Positions are opaque.
  """
  @spec feed_position(t, :now) :: Feed.position()
  def feed_position(%__MODULE__{} = env, :now), do: env.instance |> Feed.now() |> elem(0)

  @doc """
  Subscribes the calling process to the changes of `namespace` (design §16).

  `from:` is `:now` (the default) or a position from `changes/4`, a
  `{:atanor_changes, ...}` message or `feed_position/2`. `:now` moves back by
  the instance's Alambique `skew_margin_ms`, so it can repeat up to that margin
  of earlier changes but does not skip a publisher whose clock is behind. A
  subscriber that starts behind the tailer catches up first; delivery is at
  least once and can repeat changes.

  Messages are `{:atanor_changes, ref, changes, position}`; `changes` can hold
  an `Atanor.Change.Rewind` marker among the `Atanor.Change`s. Store the
  position and pass it back when you subscribe again. A subscriber whose
  mailbox grows past `feed.max_backlog` is dropped with
  `{:atanor_feed_dropped, ref, position}`; resubscribe from that position.
  `unsubscribe/2` removes the subscription.
  """
  @spec subscribe(t, String.t(), keyword) :: {:ok, reference} | not_granted | {:error, term}
  def subscribe(%__MODULE__{} = env, namespace, opts \\ []) when is_binary(namespace) do
    with :ok <- cell_granted(env, namespace),
         {:ok, from} <- subscribe_from(opts) do
      Feed.subscribe(env.instance, namespace, from)
    end
  end

  @doc "Removes a subscription returned by `subscribe/3`; succeeds when it is already gone."
  @spec unsubscribe(t, reference) :: :ok
  def unsubscribe(%__MODULE__{} = env, ref) when is_reference(ref),
    do: Feed.unsubscribe(env.instance, ref)

  defp subscribe_from(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:from] do
      from = Keyword.get(opts, :from, :now)

      if from == :now or is_nil(from) or is_binary(from),
        do: {:ok, from},
        else: {:error, {:invalid_option, :from}}
    else
      _ -> {:error, {:invalid_option, :from}}
    end
  end

  @doc """
  Attaches the socket of this env to a cell, so `send_to_cell/3` reaches it
  (design §7.3). Needs `sockets: true` and the cell's namespace granted.
  `{:error, :not_a_socket}` outside WebSocket callbacks.
  """
  @spec attach(t, Cell.address()) :: :ok | not_granted | {:error, term}
  def attach(%__MODULE__{} = env, {ns, _} = cell) do
    with :ok <- sockets(env, ns),
         :ok <- if(env.socket, do: :ok, else: {:error, :not_a_socket}),
         {:ok, _} <- valid(env, cell),
         do: Sockets.attach(env.instance, env.socket, cell)
  end

  @doc """
  Sends `message` to every socket attached to the cell, on any node. Each one
  gets `{:cell_message, message}` in `handle_ws/3`.
  """
  @spec send_to_cell(t, Cell.address(), term) :: :ok | not_granted | {:error, term}
  def send_to_cell(%__MODULE__{} = env, {ns, _} = cell, message) do
    with :ok <- sockets(env, ns),
         {:ok, _} <- valid(env, cell),
         do: Sockets.send_to(env.instance, cell, message)
  end

  @doc """
  Joins the socket of this env to the ephemeral channel of a cell, so it
  receives what `publish/3` sends to it (design §7.6). Needs `sockets: true`
  and the cell's namespace granted. `id:` (a binary) names the member for
  `channel_members/2`. Joining again replaces the id. `{:error, :not_a_socket}`
  outside WebSocket callbacks; `{:error, :too_many_subscriptions}` and
  `{:error, :too_many_channels}` at the `:channels` limits.
  """
  @spec join_channel(t, Cell.address(), keyword) :: :ok | not_granted | {:error, term}
  def join_channel(%__MODULE__{} = env, {ns, _} = cell, opts \\ []) do
    with :ok <- sockets(env, ns),
         :ok <- if(env.socket, do: :ok, else: {:error, :not_a_socket}),
         {:ok, id} <- channel_id(opts),
         {:ok, _} <- valid(env, cell),
         do: Channels.join(env.instance, env.socket, cell, id)
  end

  defp channel_id(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:id],
         id when is_nil(id) or is_binary(id) <- Keyword.get(opts, :id) do
      {:ok, id}
    else
      _ -> {:error, {:invalid_option, :id}}
    end
  end

  @doc "Removes the socket of this env from the channel of a cell; succeeds when it is not in it."
  @spec leave_channel(t, Cell.address()) :: :ok | not_granted | {:error, term}
  def leave_channel(%__MODULE__{} = env, {ns, _} = cell) do
    with :ok <- sockets(env, ns),
         :ok <- if(env.socket, do: :ok, else: {:error, :not_a_socket}),
         {:ok, _} <- valid(env, cell),
         do: Channels.leave(env.instance, env.socket, cell)
  end

  @doc """
  Sends `frame`, `{:text | :binary, data}`, to every socket in the channel of
  the cell, on any node, as a frame. The message is not written to the cell,
  runs no transaction, does not call the cell's owner and is not kept: a
  socket that is not in the channel at that moment misses it. Messages of one
  caller reach each subscriber in order. Needs `sockets: true` and the cell's
  namespace in `cells`; it works in the local WebSocket callback. The data is
  at most the `:channels` limit `:max_message_bytes` (`{:error, :too_large}`).
  """
  @spec publish(t, Cell.address(), Channels.frame()) :: :ok | not_granted | {:error, term}
  def publish(%__MODULE__{} = env, {ns, _} = cell, {kind, data} = frame)
      when kind in [:text, :binary] and is_binary(data) do
    with :ok <- channel(env, ns),
         {:ok, _} <- valid(env, cell),
         do: Channels.publish(env.instance, cell, frame)
  end

  @doc """
  Who is in the channel of a cell on every node: `%{count: n, ids: ids}`, where
  `ids` are those of the members that joined with an `id:`. Needs `sockets:
  true` and the cell's namespace in `cells`. Presence is read from the nodes
  when asked; it is not stored.
  """
  @spec channel_members(t, Cell.address()) ::
          {:ok, %{count: non_neg_integer, ids: [binary]}} | not_granted | {:error, term}
  def channel_members(%__MODULE__{} = env, {ns, _} = cell) do
    with :ok <- channel(env, ns),
         {:ok, _} <- valid(env, cell),
         do: Channels.members(env.instance, cell)
  end

  @doc """
  Sets the worker's alarm on a cell to fire at `at_ms` (milliseconds since the
  epoch) with `payload`, replacing the one it had on that cell (design §7.4).
  Needs `alarms: true` and the cell's namespace granted.
  """
  @spec set_alarm(t, Cell.address(), integer, binary) :: :ok | not_granted | {:error, term}
  def set_alarm(%__MODULE__{} = env, {ns, _} = cell, at_ms, payload) when is_integer(at_ms) and is_binary(payload) do
    with :ok <- alarms(env, ns), :ok <- writable(env), do: Alarms.set(env, cell, at_ms, payload)
  end

  @doc "Cancels the worker's alarm on a cell. Succeeds when there is none."
  @spec cancel_alarm(t, Cell.address()) :: :ok | not_granted | {:error, term}
  def cancel_alarm(%__MODULE__{} = env, {ns, _} = cell) do
    with :ok <- alarms(env, ns), :ok <- writable(env), do: Alarms.cancel(env, cell)
  end

  @doc """
  Enqueues a job on a cell in its own transaction (design §15). Inside a
  transaction with other cell writes, call `Atanor.Jobs.enqueue/4` with the
  `Alambique.Tx` instead, so the job and the data commit together.
  """
  @spec enqueue(t, Cell.address(), map) ::
          {:ok, String.t()} | {:ok, {:duplicate, String.t()}} | not_granted | {:error, term}
  def enqueue(%__MODULE__{} = env, {ns, _} = cell, spec) do
    with :ok <- jobs(env, ns), :ok <- writable(env), do: Jobs.enqueue(env, cell, spec)
  end

  @doc """
  Registers a recurring job on a cell. The expression is five-field cron in
  UTC (design §15.4).
  """
  @spec cron(t, Cell.address(), map) ::
          {:ok, String.t()} | {:ok, {:duplicate, String.t()}} | not_granted | {:error, term}
  def cron(%__MODULE__{} = env, {ns, _} = cell, spec) do
    with :ok <- jobs(env, ns), :ok <- writable(env) do
      case Cell.transaction(env.instance, cell, fn tx -> Jobs.cron(tx, env, cell, spec) end, idempotent: true) do
        {:ok, result} -> result
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  The value of a secret granted to the worker. `{:error, {:missing_secret,
  name}}` when the operator supplied no value.
  """
  @spec secret(t, String.t()) :: {:ok, String.t()} | not_granted | {:error, {:missing_secret, String.t()}}
  def secret(%__MODULE__{} = env, name) do
    worker = worker(env)

    if name in manifest(env).secrets do
      case Registry.config(env.instance).secrets do
        %{^worker => %{^name => value}} -> {:ok, value}
        _ -> {:error, {:missing_secret, name}}
      end
    else
      {:error, {:not_granted, {:secret, name}}}
    end
  end

  @doc """
  Sends an HTTP request to a host in the worker's `http.allow`. The host is
  resolved first and the request goes to the address that was checked;
  private, loopback and link-local addresses are refused unless the operator's
  `allow_private_hosts` permits them (design §4, `Atanor.Egress`). Redirects
  are followed up to the instance's `:calls` `:max_redirects` times, and each
  hop is checked again. A redirect from https to http is refused
  (`{:error, :insecure_redirect}`), and `authorization`, `cookie` and
  `proxy-authorization` headers are not sent to another origin.

  The whole fetch, with its redirects and name lookups, ends with
  `{:error, :timeout}` after the instance's `:calls` `:fetch_timeout_ms`, or
  after `:timeout_ms` of `opts` when that is shorter. A body over `:calls`
  `:fetch_max_bytes` ends it with `{:error, :response_too_large}`.
  """
  @spec fetch(t, Request.t(), timeout_ms: pos_integer) :: {:ok, Response.t()} | not_granted | {:error, term}
  def fetch(%__MODULE__{} = env, %Request{} = request, opts \\ []) do
    calls = Registry.config(env.instance).calls
    timeout = min(Keyword.get(opts, :timeout_ms, calls.fetch_timeout_ms), calls.fetch_timeout_ms)
    limits = %{deadline: System.monotonic_time(:millisecond) + timeout, max_bytes: calls.fetch_max_bytes}
    hop(env, request, calls.max_redirects, limits)
  end

  @doc """
  Calls another worker the manifest grants, in this node, on the deployment
  that was active when the request began (`new/2`): every call of one request to
  a worker reaches one version, even if another is activated meanwhile, and a
  deployment that is no longer active is rebuilt from its package by id, as for
  a forwarded request (`Atanor.Workers.pinned/3`, design §8.3), and
  `{:error, reason}` when that fails. A worker that was not active at that moment is resolved at the time of the call.

  Both sides must agree (design §3.3): the caller's manifest lists the callee in
  `workers`, and the callee lists the caller in `callable_by` or the operator in
  `callers:`. A worker may always call itself. The callee's route
  rules (`Atanor.Auth`) do not apply, and the callee sees no end user unless
  the caller passes the identity in the request itself. The `x-atanor-claims`
  header is removed from the request, so a caller cannot present claims
  Atanor did not verify, and the callee does not get the caller's WebSocket.
  """
  @spec call(t, String.t(), Request.t()) :: {:ok, Response.t()} | not_granted | {:error, term}
  def call(%__MODULE__{} = env, worker, %Request{} = request) do
    with :ok <- grant(worker in manifest(env).workers, {:worker, worker}),
         :ok <- if(env.depth < Registry.config(env.instance).calls.max_depth, do: :ok, else: {:error, :max_call_depth}),
         {:ok, deployment} <- callee(env, worker),
         :ok <- consents(env, deployment),
         :ok <- if(deployment.request?, do: :ok, else: {:error, {:no_request_handler, worker}}) do
      request = %{request | headers: Auth.strip_claims(request.headers)}
      Workers.invoke(%{env | deployment: deployment, depth: env.depth + 1, socket: nil}, request)
    end
  end

  # The answer for a callee that does not consent is the one for a worker that was not granted.
  defp consents(env, %{manifest: callee}) do
    caller = worker(env)
    allowed = caller == callee.name or caller in callee.callable_by

    allowed =
      allowed or caller in Map.get(Registry.config(env.instance).callers, callee.name, [])

    grant(allowed, {:worker, callee.name})
  end

  defp callee(%__MODULE__{pins: pins} = env, worker) do
    case pins do
      %{^worker => id} -> Workers.pinned(env.instance, worker, id)
      _ -> active(env.instance, worker)
    end
  end

  defp active(instance, worker) do
    case Registry.deployment(instance, worker) do
      {:ok, deployment} -> {:ok, deployment}
      :error -> {:error, {:unknown_worker, worker}}
    end
  end

  defp manifest(%__MODULE__{deployment: %{manifest: manifest}}), do: manifest

  defp grant(true, _), do: :ok
  defp grant(false, binding), do: {:error, {:not_granted, binding}}

  defp sockets(env, ns), do: with(:ok <- grant(manifest(env).sockets, :sockets), do: cell_granted(env, ns))
  defp alarms(env, ns), do: with(:ok <- grant(manifest(env).alarms, :alarms), do: cell_granted(env, ns))
  defp jobs(env, ns), do: with(:ok <- grant(manifest(env).jobs, :jobs), do: cell_granted(env, ns))
  defp cell_granted(%__MODULE__{local: true}, ns), do: {:error, {:not_granted, {:cell, ns}}}
  defp cell_granted(env, ns), do: grant(is_map_key(manifest(env).cells, ns), {:cell, ns})

  # A channel is keyed by a cell but never touches it, so the local callback may use it.
  defp channel(env, ns) do
    with :ok <- grant(manifest(env).sockets, :sockets), do: grant(is_map_key(manifest(env).cells, ns), {:cell, ns})
  end

  # A well-formed address, and in a partitioned namespace the physical key of a partition.
  defp valid(env, cell) do
    with {:ok, id} <- Cell.id(cell), :ok <- Cell.partitioned(env.instance, cell), do: {:ok, id}
  end

  defp with_writable_cell(env, ns, fun) do
    with :ok <- cell_granted(env, ns), :ok <- writable(env), do: fun.(env.instance)
  end

  # A bounded request runs on the ingress node and may only read (design §19.3).
  defp writable(%__MODULE__{consistency: :strong}), do: :ok
  defp writable(%__MODULE__{}), do: {:error, :read_only}

  defp hop(_env, _request, -1, _limits), do: {:error, :too_many_redirects}

  defp hop(env, %Request{scheme: scheme, host: host} = request, redirects, limits) do
    host = String.downcase(host)

    with :ok <- if(scheme in ["http", "https"], do: :ok, else: {:error, {:unsupported_scheme, scheme}}),
         :ok <- grant(Manifest.http_allowed?(manifest(env), scheme, host, request.port), {:http, host}),
         :ok <- if(request.method in @methods, do: :ok, else: {:error, {:unsupported_method, request.method}}),
         {:ok, ip} <- Egress.resolve(host, Registry.config(env.instance).private_hosts, Egress.remaining(limits)),
         {:ok, response} <- Egress.send_request(request, ip, limits) do
      case Egress.redirect(response, request) do
        nil -> {:ok, response}
        {:ok, next} -> hop(env, next, redirects - 1, limits)
        {:error, _} = error -> error
      end
    end
  end
end
