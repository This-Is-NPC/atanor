defmodule Atanor.Dispatch do
  @moduledoc """
  The one path through which work reaches a worker (design §7.2): HTTP
  requests, TCP connections, WebSocket frames, alarms and job attempts.

  `route/2` asks the worker for the cell that work belongs to, validated
  against the manifest's grants. `execute/3` runs one worker callback given
  plain data: the env (instance, deployment, socket), the cell the work is
  bound to and the call; it returns plain data. It runs on the owner of the
  cell (design §8), which is why callers pass the cell and nothing else of
  their own state.

  The callbacks are those of `Atanor.Worker`. They run according to the
  deployment's kind. WASM workers have no routing key and no TCP; their
  HTTP, WebSocket and alarm and job calls run their exported handlers through
  `Atanor.Wasm`, each in a fresh instance, and return what the native
  callbacks return (the WebSocket state is the socket id).
  """

  alias Atanor.{
    Cell,
    Detector,
    Env,
    Fence,
    Registry,
    Request,
    Response,
    Takeover,
    Telemetry,
    Unavailable,
    Wasm,
    Workers
  }

  alias Atanor.Diagnostics.Breadcrumb

  @type call ::
          {:http, Request.t()}
          | {:tcp_init, map}
          | {:tcp_data, binary, term}
          | {:ws_init, Request.t()}
          | {:ws_in, term, term}
          | {:ws_local, term, term}
          | {:ws_close, term}
          | {:alarm, Cell.address(), binary}
          | {:job, Atanor.Jobs.Job.t()}

  @doc """
  Runs an internal call (`{:jobs, at_ms}`) for `cell` on its owner. No worker
  or deployment is involved; the jobs runner resolves each job's worker. Used
  by the alarm scheduler for the reserved `@jobs` row (design §15.3).
  """
  @spec internal(atom, Cell.address(), {:jobs, integer}) :: :ok | {:error, term}
  def internal(instance, cell, call) do
    with {:ok, id} <- Cell.id(cell) do
      internal_owned(instance, cell, id, call, Registry.config(instance).routing.attempts)
    end
  end

  defp internal_owned(instance, cell, id, call, attempts) do
    case Cell.owner(instance, cell) do
      {:ok, owner} when owner == node() ->
        if current?(instance, id),
          do: local_internal(instance, cell, call),
          else: internal_retry(instance, cell, id, call, attempts, :fenced)

      {:ok, owner} ->
        forward_internal(instance, cell, id, call, owner, attempts)

      {:error, {:unavailable, owner, _}} ->
        case Takeover.recover(instance, id, owner) do
          {:ok, _} -> internal_retry(instance, cell, id, call, attempts, :takeover)
          :stale -> internal_retry(instance, cell, id, call, attempts, :stale)
          :no_quorum -> {:error, {:unavailable, :no_quorum}}
          {:error, reason} -> Unavailable.error(instance, reason)
        end

      error ->
        unavailable(instance, error)
    end
  end

  defp internal_retry(instance, _cell, _id, _call, attempts, reason) when attempts <= 1,
    do: Unavailable.error(instance, reason)

  defp internal_retry(instance, cell, id, call, attempts, _reason) do
    Process.sleep(Registry.config(instance).routing.retry_ms)
    internal_owned(instance, cell, id, call, attempts - 1)
  end

  defp forward_internal(instance, cell, id, call, node, attempts) do
    timeout = Registry.config(instance).routing.remote_timeout_ms

    outcome =
      if Detector.blocked?(instance, node) do
        :lost
      else
        try do
          :erpc.call(node, __MODULE__, :remote_internal, [instance, cell, call], timeout)
        catch
          :error, _ -> :lost
          kind, _ -> {:error, {kind, :internal_forward}}
        end
      end

    case outcome do
      {:executed, result} -> result
      :lost -> internal_retry(instance, cell, id, call, attempts, :lost)
      {:moved, _} -> internal_retry(instance, cell, id, call, attempts, :moved)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Runs on the node an internal call was forwarded to.
  def remote_internal(instance, cell, call) do
    with {:ok, id} <- Cell.id(cell),
         :ok <- owns(instance, cell),
         :ok <- if(current?(instance, id), do: :ok, else: {:moved, nil}) do
      {:executed, local_internal(instance, cell, call)}
    end
  end

  defp local_internal(instance, cell, {:jobs, at_ms}), do: Atanor.Jobs.run(instance, cell, at_ms)

  @doc """
  The cell for `input` (a request, or `{:tcp, state}`) and how it may be read,
  `:none` when the worker has no routing key or declines, `{:error, reason}`
  when it crashes or returns a cell it was not granted. Failures are logged.

  The key may end with options: `consistency: {:bounded, ms}` declares a
  request that only reads and accepts data up to `ms` old (design §19.3). A TCP
  connection is bound to its owner for good, so it takes no such option.
  """
  @spec route(Env.t(), term) :: {:ok, Cell.address(), Env.consistency()} | :none | {:error, term}
  def route(%Env{deployment: %{manifest: %{kind: :native}, module: module}} = env, input) do
    if function_exported?(module, :route_key, 2) do
      key = module.route_key(input, env)

      case {input, validate(env, key)} do
        {{:tcp, _}, {:ok, _, {:bounded, _}}} -> bad_route_key(env.deployment, key)
        {_, {:ok, cell, _consistency} = routed} -> placeable(env, cell, routed)
        {_, result} -> result
      end
    else
      :none
    end
  catch
    kind, reason -> crashed(env, kind, reason, __STACKTRACE__)
  end

  def route(%Env{}, _input), do: :none

  # A key from the request that the placement cannot name is the client's mistake, not unavailability.
  defp placeable(env, cell, routed) do
    {:ok, id} = Cell.id(cell)

    case Alambique.Placement.validate_id(Alambique.Config.fetch!(Registry.config(env.instance).alambique), id) do
      :ok -> routed
      {:error, _} -> {:error, :invalid_key}
    end
  end

  @doc """
  Runs `call` for the worker of `env`; `cell` is the address it is bound to,
  or `nil`. Work bound to a cell runs on the node that owns the cell
  (design §8), except a request whose env is bounded (`consistency:` of
  `route/2`), which runs on this node (design §19.3). Errors from the routing itself are `{:unavailable, reason}`,
  which means the call did not run, and `:unknown_outcome`, which means it may
  have run on a node that was lost.
  """
  @spec execute(Env.t(), Cell.address() | nil, call) :: {:ok, term} | {:error, term}
  def execute(%Env{} = env, cell, call) do
    cond do
      cell != nil and env.consistency != :strong ->
        local(env, cell, call, false)

      cell != nil and Node.list() != [] ->
        with {:ok, id} <- Cell.id(cell),
             do: owned(env, cell, id, call, Registry.config(env.instance).routing.attempts, nil)

      # No peers: run here, unless this node lost the cell without being told (design §8.13).
      cell != nil ->
        with {:ok, id} <- Cell.id(cell) do
          case ownership(env.instance, id) do
            :owned -> local(env, cell, call, false)
            {:lost, reason} when reason in [:held_elsewhere, :draining] -> Unavailable.error(env.instance, reason)
            _ -> {:error, {:unavailable, :fenced}}
          end
        end

      true ->
        local(env, cell, call, false)
    end
  end

  @doc """
  Runs a `{:ws_local, frame, state}` call here, on the node of the socket, without
  routing it to the owner of `cell`. The env cannot reach cells (`Env.local`); the
  call is the one a worker uses to publish to a channel (design §7.6).
  """
  @spec execute_local(Env.t(), Cell.address() | nil, call) :: {:ok, :pass | :drop} | {:error, term}
  def execute_local(%Env{} = env, cell, {:ws_local, _, _} = call), do: local(%{env | local: true}, cell, call, false)

  # Cluster routing. The first attempt takes the owner from Alambique's hint;
  # the node it names checks that it still owns the cell before it runs
  # anything (`remote/9`), so a stale hint costs one retry, not a wrong run. A
  # retry asks the cell's owner, which also corrects the hint. An owner that
  # the detector confirmed down loses the cell to this node (`Takeover`, §8.10).
  defp owned(env, cell, id, call, attempts, until) do
    case owner(env, cell, id, attempts == Registry.config(env.instance).routing.attempts) do
      {:ok, node} when node == node() ->
        if current?(env.instance, id),
          do: env |> local(cell, call, false) |> draining(env, cell, id, call, attempts, until),
          else: retry(env, cell, id, call, attempts, until, :fenced)

      {:ok, node} ->
        forward(env, cell, id, call, node, attempts, until)

      {:error, {:unavailable, owner, _}} ->
        case Takeover.recover(env.instance, id, owner) do
          {:ok, node} when node == node() -> local(env, cell, call, false)
          {:ok, _} -> retry(env, cell, id, call, attempts, until, :taken_elsewhere)
          :stale -> retry(env, cell, id, call, attempts, until, :stale)
          :no_quorum -> {:error, {:unavailable, :no_quorum}}
          {:error, reason} -> Unavailable.error(env.instance, reason)
        end

      # The cell's preferred node left the members after this node chose it, and this node's view still
      # has it: the call did not run, and the view catches up while it waits (design §8.11).
      {:error, :draining} ->
        wait(env.instance, true, attempts, until, fn a, u -> retry(env, cell, id, call, a, u, :draining) end)

      error ->
        unavailable(env.instance, error)
    end
  end

  defp unavailable(instance, {:error, reason}), do: Unavailable.error(instance, reason)

  # `Alambique.owner/3` with the hint drops a hint to a node that is gone, which a
  # touch would otherwise try to reach (a connection attempt to a lost host can
  # take seconds). A retry then asks the owner itself, which corrects a stale hint.
  defp owner(env, cell, id, first?) do
    case Alambique.owner(Registry.config(env.instance).alambique, id, hint: true) do
      {:ok, _} = hinted when first? -> hinted
      {:ok, _} -> Cell.owner(env.instance, cell)
      :none -> Cell.owner(env.instance, cell)
      error -> error
    end
  end

  defp forward(env, cell, id, call, node, attempts, until) do
    ref = make_ref()
    started = System.monotonic_time()
    args = [env.instance, Env.worker(env), env.deployment.id, env.socket, env.depth, cell, call, self(), ref]

    # The link is made here, so that a failure of the call itself always counts as possibly started: a call
    # that connects by itself can start the handler and lose the link before the caller hears of it.
    outcome =
      cond do
        blocked?(env.instance, node, call) ->
          {:lost, :unreachable, false}

        node not in Node.list() and not Node.connect(node) ->
          {:lost, :noconnection, false}

        true ->
          try do
            :erpc.call(node, __MODULE__, :remote, args, Registry.config(env.instance).routing.remote_timeout_ms)
          catch
            # Sent over a connection that later failed: the node may still have received it.
            :error, {:erpc, reason} -> {:lost, reason, true}
            kind, reason -> {:lost, {kind, reason}, true}
          end
      end

    flush(ref)
    status = forward_status(outcome)

    :telemetry.execute([:atanor, :forward], %{duration: System.monotonic_time() - started}, %{
      worker: Env.worker(env),
      deployment: env.deployment.id,
      cell: cell,
      target: node,
      result: status
    })

    case outcome do
      {:executed, result} ->
        draining(result, env, cell, id, call, attempts, until)

      {:rejected, _reason} ->
        {:error, {:unavailable, :deployment_unavailable}}

      {:moved, _} ->
        handoff(env, node, attempts, until, fn a, u -> retry(env, cell, id, call, a, u, {:moved, node}) end)

      # The call never reached the node (or it never started).
      {:lost, reason, false} ->
        handoff(env, node, attempts, until, fn a, u -> retry(env, cell, id, call, a, u, {:lost, node, reason}) end)

      # It started and the node was lost or too slow: the effect is unknown.
      {:lost, _reason, true} ->
        if idempotent?(call),
          do: handoff(env, node, attempts, until, fn a, u -> retry(env, cell, id, call, a, u, :unknown) end),
          else: {:error, :unknown_outcome}
    end
  end

  # A node that is leaving still runs its cells until they are handed off: only a call that a
  # repeat cannot hurt goes to it, since the node may stop while the call runs (design §8.11).
  defp blocked?(instance, node, call),
    do: Detector.blocked?(instance, node) and not (idempotent?(call) and Detector.left?(instance, node))

  # A cell call refused with `owner_down` or `draining` did not run (design §8.4). While a node leaves, that is a
  # node that hibernated the cell and refused to wake it: the call waits for the handoff like the others.
  defp draining({:error, {:unavailable, reason}} = refused, env, cell, id, call, attempts, until)
       when reason in [:owner_down, :draining] do
    if Detector.any_left?(env.instance),
      do: wait(env.instance, true, attempts, until, fn a, u -> retry(env, cell, id, call, a, u, reason) end),
      else: refused
  end

  defp draining(result, _env, _cell, _id, _call, _attempts, _until), do: result

  defp handoff(env, node, attempts, until, retry),
    do: wait(env.instance, Detector.left?(env.instance, node), attempts, until, retry)

  # While an owner leaves, a call retries until `until`, `routing.leave_wait_ms` after the first
  # such failure, however many tries that takes; after it the usual count applies, now spent.
  @doc false
  # Shared with `Atanor.Cell`, for the cell calls of a handler.
  def wait(_instance, false, attempts, until, retry), do: retry.(attempts, until)

  def wait(instance, true, attempts, until, retry) do
    now = System.monotonic_time(:millisecond)
    until = until || now + Registry.config(instance).routing.leave_wait_ms
    retry.(if(now < until, do: max(attempts, 2), else: 1), until)
  end

  defp forward_status({:executed, _}), do: :ok
  defp forward_status({:rejected, _}), do: :rejected
  defp forward_status({:moved, _}), do: :moved
  defp forward_status({:lost, _, started?}), do: if(started?, do: :unknown_outcome, else: :lost)

  defp retry(env, _cell, _id, _call, attempts, _until, reason) when attempts <= 1,
    do: Unavailable.error(env.instance, reason)

  defp retry(env, cell, id, call, attempts, until, _reason) do
    Process.sleep(Registry.config(env.instance).routing.retry_ms)
    owned(env, cell, id, call, attempts - 1, until)
  end

  # A repeated call has the same effect as one: reads, and alarms, which are
  # delivered at least once (design §7.4).
  defp idempotent?({:http, %Request{method: method}}), do: method in ["GET", "HEAD", "OPTIONS"]
  defp idempotent?({:alarm, _, _}), do: true
  defp idempotent?(_), do: false

  # The start message is part of the forwarding protocol; the caller no longer needs it.
  defp flush(ref) do
    receive do
      {:atanor_started, ^ref} -> :ok
    after
      0 -> :ok
    end
  end

  @doc false
  # Runs on the node a call was forwarded to. Returns `{:moved, node | nil}`
  # when this node does not own the cell, `{:rejected, reason}` when it cannot
  # run the deployment, and `{:executed, result}`; only the last means the call ran.
  def remote(instance, worker, id, socket, depth, cell, call, from, ref) do
    with {:ok, deployment} <- admit(instance, worker, id, cell) do
      send(from, {:atanor_started, ref})
      env = %{Env.new(instance, deployment) | socket: socket, depth: depth}
      handed_off(instance, call, local(env, cell, call, true))
    end
  end

  # Nothing has run yet. `Alambique.owner/3` still raises `ArgumentError` on a stopped instance
  # (`Router.owner/3` uses `Config.fetch!/1`; only `Router.remote/5` answers `:draining`);
  # the node then answers like one that does not own the cell, so the caller routes again.
  defp admit(instance, worker, id, cell) do
    with :ok <- owns(instance, cell),
         :ok <- if(current?(instance, elem(Cell.id(cell), 1)), do: :ok, else: {:moved, nil}) do
      pinned(instance, worker, id)
    end
  rescue
    ArgumentError -> {:moved, nil}
  end

  # A node that stops hibernates its cells under the handlers that still run: a failure then
  # says nothing about the cell, and the caller routes an idempotent call again.
  defp handed_off(instance, call, {:error, _} = failure) do
    if Registry.state(instance) in [:draining, :stopping] and idempotent?(call),
      do: {:moved, nil},
      else: {:executed, failure}
  end

  defp handed_off(_instance, _call, result), do: {:executed, result}

  # Before a handler starts for a cell this node owns, the lease is read from the store unless it was read
  # within `routing.owner_check_ms`: a node that was not told it lost the cell (it was frozen, or cut off from
  # its peers) stops starting handlers for it within that time (design §8.13). A lease that cannot be read
  # does not stop the cell, as in Alambique.
  defp current?(instance, id), do: ownership(instance, id) == :owned

  # `:lost` is a definite answer: the lease or the router says another node serves the cell. `:unknown`
  # is any other failure of the read (a timeout, an overloaded cell); it stops a new handler but not one
  # that is running. `{:lost, reason}` is a lost cell that is `:held_elsewhere` (a node outside the cluster holds its lease) or `:draining` (this node hands its cells off).
  defp ownership(instance, id) do
    config = Registry.config(instance)
    routing = config.routing

    cond do
      not routing.owner_check ->
        :owned

      Registry.verified?(instance, id, routing.owner_check_ms) ->
        Fence.refresh_ahead(instance, config, id)
        :owned

      true ->
        if config.hot_cells.enabled, do: Atanor.HotCells.hold(instance, id, config.hot_cells.move_timeout_ms)

        case Alambique.query(config.alambique, id, "SELECT 1", [], verify_lease: true) do
          {:ok, _} ->
            if Alambique.owner(config.alambique, id) == {:ok, node()} do
              Registry.put_verified(instance, id, routing.owner_check_cells)
              :owned
            else
              :lost
            end

          {:error, {:lease_unreadable, _}} ->
            :owned

          # The router of this node refuses to wake the cell: it hands its cells off.
          {:error, :draining} ->
            {:lost, :draining}

          {:error, reason} when reason in [:fenced, :lease_lost, :lease_expired] ->
            :lost

          # The lease names another node that this one cannot reach.
          {:error, {:unavailable, owner, _expires}} ->
            case Takeover.unreachable(instance, owner) do
              :held_elsewhere -> {:lost, :held_elsewhere}
              _ -> :lost
            end

          {:error, _} ->
            :unknown
        end
    end
  end

  defp owns(instance, cell) do
    alambique = Registry.config(instance).alambique
    {:ok, id} = Cell.id(cell)

    case Alambique.owner(alambique, id) do
      {:ok, node} when node == node() -> :ok
      {:ok, node} -> {:moved, node}
      _ -> {:moved, nil}
    end
  end

  defp pinned(instance, worker, id) do
    case Workers.pinned(instance, worker, id) do
      {:ok, deployment} -> {:ok, deployment}
      {:error, reason} -> {:rejected, {:deployment_unavailable, reason}}
    end
  end

  defp local(env, cell, call, forwarded?) do
    fun = fn -> Telemetry.call(env, cell, elem(call, 0), forwarded?, fn -> guarded(env, call) end) end

    case call do
      {:job, job} ->
        Fence.run(env, :job, cell, fn ->
          Breadcrumb.wrap(
            env.instance,
            %{
              kind: "job",
              worker: job.worker,
              deployment: env.deployment.id,
              cell: {:cell, cell},
              job_id: job.id,
              operation_id: job.operation_id,
              attempt: job.attempt
            },
            fun
          )
        end)

      {:alarm, _, _} ->
        Fence.run(env, :alarm, cell, fn ->
          Breadcrumb.wrap(
            env.instance,
            %{kind: "alarm", worker: Env.worker(env), deployment: env.deployment.id, cell: {:cell, cell}},
            fun
          )
        end)

      call when elem(call, 0) in [:ws_init, :ws_in, :ws_local, :ws_close] ->
        fun.()

      _ ->
        Breadcrumb.callback(
          env.instance,
          %{
            kind: Atom.to_string(elem(call, 0)),
            worker: Env.worker(env),
            deployment: env.deployment.id,
            cell: {:cell, cell}
          },
          fun
        )
    end
  end

  # A cell write that may have been applied (Alambique's `:outcome_unknown`) makes a
  # failed call `:unknown_outcome`; an availability reason makes it the matching
  # 503 (design §8.4). A worker that handled the error and answered below 500 is
  # left alone. Unknown outcome wins: it is the stronger statement.
  defp guarded(env, call) do
    Cell.clear_unknown()
    Cell.clear_unavailable()

    # Its cell calls wait for an owner that leaves (design §8.11).
    handler = Cell.begin_handler()

    result =
      try do
        run(env, call)
      catch
        kind, reason -> crashed(env, kind, reason, __STACKTRACE__)
      after
        Cell.end_handler(handler)
      end

    classify(result)
  end

  defp classify(result) do
    cond do
      not failed?(result) ->
        result

      Cell.unknown_outcome?() ->
        {:error, :unknown_outcome}

      reason = Cell.unavailable_reason() ->
        case reason do
          :overloaded -> {:error, :overloaded}
          {:foreign_store, _} -> {:error, reason}
          _ -> {:error, {:unavailable, reason}}
        end

      true ->
        result
    end
  end

  defp failed?({:ok, %{status: status}}) when is_integer(status), do: status >= 500
  defp failed?({:error, _}), do: true
  defp failed?(_), do: false

  defp run(%Env{deployment: %{manifest: %{kind: :native}}} = env, call), do: native(env, call)
  defp run(env, {:http, request}), do: Workers.invoke(env, request)
  defp run(env, call), do: Wasm.execute(env, call)

  defp native(env, {:http, request}), do: Workers.invoke(env, request)
  defp native(env, {:tcp_init, info}), do: callback(env, :tcp_init, [info, env], {:ok, nil})
  defp native(env, {:tcp_data, data, state}), do: callback(env, :handle_tcp, [data, state, env])
  defp native(env, {:ws_init, request}), do: callback(env, :ws_init, [request, env], {:ok, nil})
  defp native(env, {:ws_in, message, state}), do: callback(env, :handle_ws, [message, state, env])
  defp native(env, {:ws_local, message, state}), do: callback(env, :handle_ws_local, [message, state, env])
  defp native(_env, {:ws_close, _state}), do: {:ok, :ok}
  defp native(env, {:alarm, cell, payload}), do: callback(env, :handle_alarm, [cell, payload, env])
  defp native(env, {:job, job}), do: callback(env, :handle_job, [job, env])

  defp callback(%Env{deployment: %{module: module}} = env, name, args, default \\ :required) do
    if default != :required and not function_exported?(module, name, length(args)) do
      {:ok, default}
    else
      result = apply(module, name, args)

      if valid?(name, result) do
        {:ok, result}
      else
        Workers.log(env.deployment, "returned an invalid #{name} result", inspect(result, limit: 20))
        {:error, :bad_return}
      end
    end
  end

  defp valid?(:tcp_init, {:ok, _}), do: true
  defp valid?(:tcp_init, {:reply, bytes, _}), do: iodata?(bytes)
  defp valid?(:tcp_init, {:close, bytes}), do: iodata?(bytes)
  defp valid?(:handle_tcp, {:continue, _}), do: true
  defp valid?(:handle_tcp, {:reply, bytes, _}), do: iodata?(bytes)
  defp valid?(:handle_tcp, {:close, bytes}), do: iodata?(bytes)
  defp valid?(:handle_tcp, {:starttls, bytes, _}), do: iodata?(bytes)
  defp valid?(:ws_init, {:ok, _}), do: true
  defp valid?(:ws_init, {:reject, response}), do: Response.valid?(response)
  defp valid?(:handle_ws, {:ok, _}), do: true
  defp valid?(:handle_ws, {:stop, _}), do: true
  defp valid?(:handle_ws, {:reply, frames, _}), do: is_list(frames) and Enum.all?(frames, &frame?/1)
  defp valid?(:handle_ws_local, verdict), do: verdict in [:pass, :drop]
  defp valid?(:handle_alarm, :ok), do: true
  defp valid?(:handle_alarm, {:error, _}), do: true
  defp valid?(:handle_job, :ok), do: true
  defp valid?(:handle_job, {:error, _}), do: true
  defp valid?(_, _), do: false

  defp frame?({type, data}) when type in [:text, :binary] and is_binary(data), do: true
  defp frame?(_), do: false

  defp iodata?(bytes) when is_binary(bytes), do: true

  defp iodata?(bytes) when is_list(bytes) do
    _ = :erlang.iolist_size(bytes)
    true
  rescue
    ArgumentError -> false
  end

  defp iodata?(_), do: false

  defp validate(_env, :none), do: :none

  # `{:cell, ns, key, partition_key}` names the partition of a partitioned namespace (design §4.2); a
  # last element that is a keyword list holds the options (`consistency:`), also after a partition key.
  defp validate(%Env{} = env, {:cell, ns, key, partition_key, opts} = result) when is_binary(partition_key) do
    with {:ok, consistency} <- consistency(opts),
         {:ok, cell} <- Env.partition(env, {ns, key}, partition_key) do
      {:ok, cell, consistency}
    else
      _ -> bad_route_key(env.deployment, result)
    end
  end

  defp validate(%Env{} = env, {:cell, ns, key, partition_key} = result) when is_binary(partition_key) do
    case Env.partition(env, {ns, key}, partition_key) do
      {:ok, cell} -> {:ok, cell, :strong}
      {:error, _} -> bad_route_key(env.deployment, result)
    end
  end

  defp validate(%Env{deployment: deployment} = env, {:cell, ns, key, opts} = result) when is_list(opts) do
    with {:ok, consistency} <- consistency(opts),
         {:ok, cell} <- plain(env, ns, key) do
      {:ok, cell, consistency}
    else
      _ -> bad_route_key(deployment, result)
    end
  end

  defp validate(%Env{deployment: deployment} = env, {:cell, ns, key} = result) do
    case plain(env, ns, key) do
      {:ok, cell} -> {:ok, cell, :strong}
      :error -> bad_route_key(deployment, result)
    end
  end

  defp validate(%Env{deployment: deployment}, other) do
    Workers.log(deployment, "returned an invalid routing key", inspect(other, limit: 20))
    {:error, {:bad_route_key, other}}
  end

  # A cell of a namespace the worker is granted, not partitioned.
  defp plain(%Env{deployment: deployment} = env, ns, key) do
    with true <- is_map_key(deployment.manifest.cells, ns),
         {:ok, _id} <- Cell.id({ns, key}),
         :ok <- Cell.partitioned(env.instance, {ns, key}) do
      {:ok, {ns, key}}
    else
      _ -> :error
    end
  end

  defp consistency(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:consistency] do
      case Keyword.get(opts, :consistency, :strong) do
        :strong -> {:ok, :strong}
        {:bounded, ms} = bounded when is_integer(ms) and ms > 0 -> {:ok, bounded}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp bad_route_key(deployment, result) do
    Workers.log(deployment, "returned a routing key it may not use", inspect(result))
    {:error, {:bad_route_key, result}}
  end

  defp crashed(env, kind, reason, stacktrace) do
    Workers.log(env.deployment, "crashed", Workers.format_crash(kind, reason, stacktrace))
    {:error, :crashed}
  end
end
