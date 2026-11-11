defmodule Atanor.Wasm do
  @moduledoc """
  WASM workers (design §3.2, §14): components implementing
  `wasi:http/incoming-handler`, run by Wasmtime inside `native/atanor_wasm`.
  A component also exports `atanor:worker/alarm-handler` when its manifest
  grants alarms, `atanor:worker/socket-handler` to serve WebSockets, and
  `atanor:worker/job-handler` for jobs.

  `build/2` compiles a manifest's component (cached by hash), checks that its
  imports are granted by the manifest and that it exports the handlers the
  grants need, and returns the deployment. `invoke/3` runs one request, and
  `execute/2` one alarm, job or WebSocket call, each in a fresh instance under
  the limits of the manifest and the node settings.

  ## Node settings

  Application environment `:atanor, :wasm`, read when the first instance
  starts and fixed for the VM:

    * `:threads` - guests that run at once (default: the logical processors).
      A guest that waits (sleeps, polls, waits for a host call, an outbound
      response or a worker it called) does not count.
    * `:max_calls` - calls in flight that are not waiting: the threads of the
      pool (default: 4 per thread, at least `:threads`).
    * `:max_waiting` - guests that wait without holding a call slot or a pool
      thread, so they do not count against `:max_calls` or `:worker_calls`
      (default: 2 per thread). Each has a thread and an instance slot of its
      own; a guest that waits above this number keeps its slot, as it would
      without the setting.
    * `:max_nested_calls` - calls that guests make to other workers, in flight
      at once. They run on threads of their own, so they never wait for a pool
      thread behind their callers (default: 1 per thread).
    * `:worker_calls` - calls of one deployment in flight at once, queued
      included, waiting guests excepted; one more is refused with
      `{:error, :overloaded}`, so a busy worker cannot take every thread (default: three quarters of
      `:max_calls`, at least 1).
    * `:queue` - calls that may wait for a pool thread (default: 4 per thread).
      A full queue refuses the call with `{:error, :overloaded}`.
    * `:queue_wait_ms` - longest wait in the queue and for the right to run
      (default 1000).
    * `:tick_ms` - epoch tick, the resolution of the time limits (default 10).
    * `:cpu` - `:epoch` or `:fuel`, how CPU is limited (default `:epoch`).
    * `:pooling` - `true` to reuse pre-mapped instance slots (Wasmtime's pooling
      allocator) instead of mapping memory for every call (default `true`). The
      pool holds, per thread, one store of at most 8 instances, 8 memories and
      16 tables; each memory slot reserves address space up to `:max_memory_bytes`
      (at most 4 GiB) and each table slot `:table_elements`. A component that
      asks for more than a slot fails to instantiate; set `false` to map on
      demand. The memory and CPU limits are the same in both modes.
    * `:cpu_ms` - CPU time per request in epoch mode (default 5000).
    * `:fuel` - fuel per request in fuel mode, unless the manifest's
      `limits.fuel` gives it (default 1,000,000,000).
    * `:max_response_bytes` - largest response body (default 8,000,000).
    * `:timeout_ms` - wall-clock limit of a call when the manifest does not
      set `limits.timeout_ms` (default 30,000).
    * `:memory_bytes` - memory cap of a call, all memories together, when the
      manifest does not set `limits.memory_bytes` (default 64 MiB).
    * `:max_timeout_ms`, `:max_memory_bytes` and `:max_fuel` - ceilings for
      the manifest's `limits.timeout_ms`, `limits.memory_bytes` and
      `limits.fuel`; a larger value is lowered to the ceiling (defaults
      120,000, 512 MiB and 10,000,000,000).
    * `:max_resources` - host resources (field sets, streams, pollables) a
      call may hold at once (default 4,096).
    * `:max_field_bytes` - memory of one `wasi:http` field set, the headers of
      a request or response (default 16,384).
    * `:grace_ms` - time to let the native side report a limit before the
      caller gives up (default 2,000).
    * `:stderr_bytes` - bytes of a guest's stderr kept for the log (default
      4,096).
    * `:table_elements` - largest table a guest may grow to (default 100,000).
    * `:compile_timeout_ms` - longest a deployment waits for a component to
      compile (default 60,000). The compile itself cannot be interrupted: it
      ends on the compile pool and its result is cached.
    * `:compile_threads` - components compiled at once, on threads of their
      own that are not BEAM schedulers (default 2).
    * `:compile_queue` - compiles that may wait for a thread; a deployment
      that finds the queue full fails at once (default 16).
    * `:host_reply_dirty_bytes` - size from which the reply to a host call is
      copied into the native side on a dirty scheduler instead of a normal one
      (default 262,144; a binary's `byte_size`, another term's external size).

  A manifest's `limits` set `timeout_ms` and `memory_bytes` per call, up to the
  node's ceilings; `limits.cpu_ms` lowers the CPU time of epoch mode below the
  node's `:cpu_ms`; `limits.fuel` is read only in fuel mode, up to `:max_fuel`.
  """

  require Logger

  alias Atanor.Wasm.{Cache, Host, Native}
  alias Atanor.{Deployment, Env, Manifest, Package, Request, Response}

  @defaults [
    queue_wait_ms: 1_000,
    tick_ms: 10,
    cpu: :epoch,
    pooling: true,
    cpu_ms: 5_000,
    fuel: 1_000_000_000,
    max_response_bytes: 8_000_000,
    timeout_ms: 30_000,
    memory_bytes: 64 * 1024 * 1024,
    max_timeout_ms: 120_000,
    max_memory_bytes: 512 * 1024 * 1024,
    max_fuel: 10_000_000_000,
    max_resources: 4_096,
    max_field_bytes: 16_384,
    grace_ms: 2_000,
    stderr_bytes: 4_096,
    table_elements: 100_000,
    compile_timeout_ms: 60_000,
    compile_threads: 2,
    compile_queue: 16,
    host_reply_dirty_bytes: 262_144
  ]

  @type limit :: :timeout | :memory | :cpu
  @type error :: {:limit, limit} | :overloaded | :response_too_large | {:trap | :guest, String.t()}

  @doc """
  The node settings with their defaults. Without overrides they are built once and kept in `:persistent_term`,
  as they are fixed for the VM. `overrides` is for tests and tools; invalid settings raise `ArgumentError`.
  """
  @spec settings(keyword) :: map
  def settings(overrides \\ [])

  def settings([]) do
    case :persistent_term.get({__MODULE__, :settings}, nil) do
      nil ->
        settings = build_settings([])
        :persistent_term.put({__MODULE__, :settings}, settings)
        settings

      settings ->
        settings
    end
  end

  def settings(overrides), do: build_settings(overrides)

  defp build_settings(overrides) do
    config =
      Application.get_env(:atanor, :wasm, [])
      |> Keyword.merge(overrides)

    threads = Keyword.get(config, :threads, :erlang.system_info(:logical_processors))

    config =
      config
      |> Keyword.put_new(:threads, threads)
      |> Keyword.put_new(:queue, 4 * threads)

    max_calls = Keyword.get(config, :max_calls, 4 * threads)

    config =
      config
      |> Keyword.put_new(:max_calls, max_calls)
      |> Keyword.put_new(:max_nested_calls, threads)
      |> Keyword.put_new(:max_waiting, 2 * threads)
      |> Keyword.put_new(:worker_calls, max(max_calls - div(max_calls, 4), 1))

    settings = Map.new(Keyword.merge(@defaults, config))
    validate!(settings)
    settings
  end

  defp validate!(settings) do
    unless settings.cpu in [:epoch, :fuel] do
      raise ArgumentError, ":atanor, :wasm :cpu must be :epoch or :fuel"
    end

    unless is_boolean(settings.pooling) do
      raise ArgumentError, ":atanor, :wasm :pooling must be true or false"
    end

    unless settings.max_calls >= settings.threads do
      raise ArgumentError, ":atanor, :wasm :max_calls must be at least :threads"
    end

    for key <- [
          :threads,
          :max_calls,
          :max_nested_calls,
          :max_waiting,
          :worker_calls,
          :queue,
          :queue_wait_ms,
          :tick_ms,
          :cpu_ms,
          :fuel,
          :max_response_bytes,
          :timeout_ms,
          :memory_bytes,
          :max_timeout_ms,
          :max_memory_bytes,
          :max_fuel,
          :max_resources,
          :max_field_bytes,
          :grace_ms,
          :stderr_bytes,
          :table_elements,
          :compile_timeout_ms,
          :compile_threads,
          :compile_queue,
          :host_reply_dirty_bytes
        ] do
      unless is_integer(settings[key]) and settings[key] > 0 do
        raise ArgumentError, ":atanor, :wasm #{inspect(key)} must be a positive integer"
      end
    end

    settings
  end

  @doc """
  Compiles and links the component of a WASM package, cached under the
  package id. Refused with `{:not_granted, {:import, name}}` when the
  component imports an interface the manifest does not grant (B1), and with
  `{:missing_export, name}` when the manifest grants alarms or sockets and
  the component does not export the handler.
  """
  @spec build(atom, Package.t()) :: {:ok, Deployment.t()} | {:error, term}
  def build(instance, %Package{id: id, manifest: %Manifest{kind: :wasm} = manifest, component: bytes}) do
    with {:ok, compiled} <- compile(instance, id, bytes),
         {:ok, prepared, sockets?, local?} <- prepare(compiled, manifest) do
      {:ok,
       %Deployment{
         id: id,
         manifest: manifest,
         module: __MODULE__,
         wasm: prepared,
         request?: true,
         ws?: sockets?,
         local_ws?: local?
       }}
    end
  end

  defp compile(instance, hash, bytes) do
    case Cache.fetch(instance, hash, bytes) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, message} -> {:error, {:invalid_component, message}}
    end
  end

  defp prepare(compiled, manifest) do
    grants = %{
      sql: manifest.cells != %{},
      secrets: manifest.secrets != [],
      call: manifest.workers != [],
      http: manifest.http_allow != [],
      alarms: manifest.alarms,
      sockets: manifest.sockets,
      jobs: manifest.jobs
    }

    started = System.monotonic_time()

    case Native.prepare(compiled, grants) do
      {:ok, {prepared, sockets?, local?}} ->
        :telemetry.execute([:atanor, :wasm, :prepare], %{duration: System.monotonic_time() - started}, %{
          worker: manifest.name
        })

        {:ok, prepared, sockets?, local?}

      {:error, {:not_granted, name}} ->
        {:error, {:not_granted, {:import, name}}}

      {:error, {kind, name}} when kind in [:unsupported_import, :missing_export] ->
        {:error, {kind, name}}

      {:error, {:prepare_failed, message}} ->
        {:error, {:invalid_component, message}}
    end
  end

  @doc """
  Runs `request` in a fresh instance of the deployment.

  Returns `{:error, {:limit, :timeout | :memory | :cpu}}` when a limit
  stopped the guest, and `{:error, :overloaded}` when no thread was free in
  time. The calling process answers the guest's host calls (cells, secrets,
  worker calls, outbound HTTP, alarms, sockets) with `env`, so they run with
  the grants of the deployment the request started on (D1).
  """
  @spec invoke(Deployment.t(), Request.t(), Env.t()) :: {:ok, Response.t()} | {:error, error | term}
  def invoke(%Deployment{} = deployment, %Request{} = request, %Env{} = env) do
    case run(deployment, env, http_call(request)) do
      {:ok, {status, headers, body}} -> {:ok, %Response{status: status, headers: headers, body: body}}
      {:error, _} = error -> error
    end
  end

  @doc false
  # The alarm and WebSocket calls of `Atanor.Dispatch`, each in a fresh
  # instance, with the results the native callbacks return. The caller answers
  # the host calls, so `attach` finds the socket in `env`.
  @spec execute(Env.t(), Atanor.Dispatch.call()) :: {:ok, term} | {:error, term}
  def execute(%Env{deployment: deployment} = env, call) do
    case call do
      {:alarm, {namespace, key}, payload} ->
        with {:ok, nil} <- run(deployment, env, {:alarm, namespace, key, payload}), do: {:ok, :ok}

      {:job, job} ->
        with {:ok, nil} <-
               run(
                 deployment,
                 env,
                 {:job, elem(job.cell, 0), elem(job.cell, 1), job.id, job.idempotency_key || job.id, job.kind,
                  job.payload, job.attempt}
               ),
             do: {:ok, :ok}

      {:ws_init, %Request{} = r} ->
        socket = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

        case run(deployment, env, {:ws_open, socket, r.method, r.path, r.query, r.headers}) do
          {:ok, :accept} -> {:ok, {:ok, socket}}
          {:ok, {:reject, response}} -> reject(deployment, response)
          {:error, _} = error -> error
        end

      {:ws_in, {:cell_message, message}, socket} when not is_binary(message) ->
        # Cell messages reach a guest as bytes; other terms are for native workers.
        {:ok, {:ok, socket}}

      {:ws_in, message, socket} ->
        {kind, data} = incoming(message)

        case run(deployment, env, {:ws_message, socket, kind, data}) do
          {:ok, {frames, close?}} -> {:ok, reply(frames, close?, socket)}
          {:error, _} = error -> error
        end

      {:ws_local, {kind, data}, socket} ->
        run(deployment, env, {:ws_local, socket, kind, data})

      {:ws_close, socket} ->
        with {:ok, nil} <- run(deployment, env, {:ws_close, socket}), do: {:ok, :ok}
    end
  end

  defp incoming({:cell_message, data}), do: {:cell, data}
  defp incoming({kind, data}), do: {kind, data}

  defp reply([], false, socket), do: {:ok, socket}
  defp reply([], true, socket), do: {:stop, socket}
  defp reply(frames, false, socket), do: {:reply, frames, socket}
  defp reply(frames, true, socket), do: {:close, frames, socket}

  defp reject(deployment, {status, headers, body}) do
    response = %Response{status: status, headers: headers, body: body}

    if Response.valid?(response) do
      {:ok, {:reject, response}}
    else
      Atanor.Workers.log(deployment, "returned an invalid response", inspect(response, limit: 20))
      {:error, :bad_response}
    end
  end

  # Runs one call and waits for its result, answering host calls meanwhile.
  defp run(%Deployment{wasm: prepared} = deployment, %Env{} = env, call) do
    settings = settings()
    limits = Map.put(limits(deployment.manifest, settings), :nested, env.depth > 0)
    tag = :erlang.unique_integer([:positive])
    started = System.monotonic_time()

    result =
      case Native.invoke(prepared, call, limits, self(), tag) do
        :ok -> await(tag, env, limits.timeout_ms + limits.queue_wait_ms + settings.grace_ms, started)
        :overloaded -> {{:error, :overloaded}, "", nil}
      end

    finish(result, env.instance, deployment, started, elem(call, 0))
  end

  @doc false
  def limits(manifest, settings) do
    %{
      timeout_ms: min(Map.get(manifest.limits, :timeout_ms, settings.timeout_ms), settings.max_timeout_ms),
      memory_bytes: min(Map.get(manifest.limits, :memory_bytes, settings.memory_bytes), settings.max_memory_bytes),
      cpu_ms: min(Map.get(manifest.limits, :cpu_ms, settings.cpu_ms), settings.cpu_ms),
      fuel: min(Map.get(manifest.limits, :fuel, settings.fuel), settings.max_fuel),
      max_response_bytes: settings.max_response_bytes,
      queue_wait_ms: settings.queue_wait_ms,
      stderr_bytes: settings.stderr_bytes,
      table_elements: settings.table_elements,
      max_resources: settings.max_resources,
      max_field_bytes: settings.max_field_bytes
    }
  end

  defp http_call(%Request{} = r) do
    authority = if r.port in [80, 443], do: r.host, else: "#{r.host}:#{r.port}"
    path = if r.query == "", do: r.path, else: r.path <> "?" <> r.query
    {:http, r.method, r.scheme, authority, path, r.headers, r.body}
  end

  defp await(tag, env, wait_ms, started) do
    elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    receive do
      {:atanor_wasm, ^tag, :host, id, op, args} ->
        Native.host_reply(id, Host.handle(env, op, args, max(wait_ms - elapsed, 0)))
        await(tag, env, wait_ms, started)

      {:atanor_wasm, ^tag, :done, result, stderr, timing} ->
        {result, stderr, timing}
    after
      max(wait_ms - elapsed, 0) -> {{:error, {:limit, :timeout}}, "", nil}
    end
  end

  defp finish({result, stderr, timing}, instance, deployment, started, call) do
    worker = Deployment.worker(deployment)
    duration = System.monotonic_time() - started
    metadata = %{instance: instance, worker: worker, deployment: deployment.id, call: call}

    if stderr != "" do
      Logger.warning("worker #{worker} (deployment #{deployment.id}) wrote to stderr: #{String.trim(stderr)}")
    end

    measurements = Map.merge(%{duration: duration}, timings(timing))

    case result do
      {:ok, value} ->
        :telemetry.execute([:atanor, :wasm, :invoke], measurements, Map.put(metadata, :result, :ok))
        {:ok, value}

      {:error, {:limit, kind}} = error ->
        :telemetry.execute([:atanor, :wasm, :invoke], measurements, Map.put(metadata, :result, {:limit, kind}))
        :telemetry.execute([:atanor, :wasm, :limit], %{count: 1}, Map.put(metadata, :limit, kind))
        error

      {:error, reason} = error ->
        :telemetry.execute([:atanor, :wasm, :invoke], measurements, Map.put(metadata, :result, error_kind(reason)))
        log(deployment, reason)
        error
    end
  end

  defp error_kind({kind, _}) when kind in [:trap, :guest], do: kind
  defp error_kind(reason), do: reason

  defp log(deployment, {kind, message}) when kind in [:trap, :guest],
    do: Atanor.Workers.log(deployment, "failed (#{kind})", message)

  defp log(_deployment, _reason), do: :ok

  defp timings([instantiate_ns, run_ns, cpu_ns, memory_bytes, fuel_used]) do
    %{
      instantiate: System.convert_time_unit(instantiate_ns, :nanosecond, :native),
      run: System.convert_time_unit(run_ns, :nanosecond, :native),
      cpu: System.convert_time_unit(cpu_ns, :nanosecond, :native),
      memory_bytes: memory_bytes,
      fuel_used: fuel_used
    }
  end

  defp timings(nil), do: %{}
end
