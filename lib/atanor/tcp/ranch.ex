defmodule Atanor.TCP.Ranch do
  @moduledoc """
  Atanor's Ranch protocol for `protocol: :ranch` listeners (design §7.3).

  Ranch calls `start_link/3` once per accepted connection, in its connection
  supervisor. This module resolves the deployment the listener serves at that
  moment (the same D1 pinning as a ThousandIsland connection), builds its
  `Atanor.Env`, asks the worker for `ranch_protocol(env)` and starts the
  returned `{module, opts}` with the env added to the options.

  The options Atanor adds are plain data:

    * `:atanor_env` - the `Atanor.Env` of the connection, at the top level of a
      keyword list or a map.
    * `:atanor_listener` - the name of the listener that accepted the
      connection (a string), next to `:atanor_env`. Inbound SMTP and
      submission can share a worker and tell themselves apart by it.
    * `:atanor_tls_options` - the listener's current `:ssl` server options (a
      keyword list), or `[]` when the listener is plain.
    * `:tls_options` - the same list under the name gen_smtp reads for its own
      STARTTLS, when the listener has `tls_mode: :starttls`.
    * For the gen_smtp `{callback, opts}` form, `:atanor_env` is also put in
      `opts[:callbackoptions]` with `:atanor_listener`; gen_smtp passes that
      list as the fourth argument of `callback.init/4`.

  A worker named by a `"protocol": "ranch"` route must export
  `Atanor.Worker.ranch_protocol/1`; activation is refused without it.
  """

  if Code.ensure_loaded?(:ranch_protocol) do
    @behaviour :ranch_protocol
  end

  require Logger

  alias Atanor.{Env, Registry, TCP.TLS}

  def start_link(ref, transport, %{instance: instance, listener: listener}) do
    case Registry.listener(instance, listener) do
      {:ok, deployment} -> start_connection(ref, transport, instance, listener, deployment)
      :error -> close(ref, transport)
    end
  end

  def start_link(ref, transport, _opts), do: close(ref, transport)

  defp start_connection(ref, transport, instance, listener, deployment) do
    env = Env.new(instance, deployment)
    started = System.monotonic_time()

    with {:ok, {module, opts}} <- protocol(deployment, env),
         {:ok, pid} <- start(module, ref, transport, opts, env, instance, listener) do
      :telemetry.execute([:atanor, :tcp, :connect], %{count: 1}, meta(env, listener))
      watch(pid, meta(env, listener), started)
      {:ok, pid}
    else
      {:error, reason} ->
        Logger.error("atanor: ranch listener #{listener} refused a connection: #{inspect(reason)}")

        close(ref, transport)
    end
  end

  defp protocol(deployment, env) do
    case deployment.module.ranch_protocol(env) do
      {module, opts} when is_atom(module) ->
        if Code.ensure_loaded?(module),
          do: {:ok, {module, opts}},
          else: {:error, {:module_not_loaded, module}}

      other ->
        {:error, {:bad_ranch_protocol, other}}
    end
  catch
    kind, reason -> {:error, {:crashed, Atanor.Workers.format_crash(kind, reason, __STACKTRACE__)}}
  end

  defp start(module, ref, transport, opts, env, instance, listener) do
    opts = with_env(opts, env, listener, tls_options(instance, listener))

    case module.start_link(ref, transport, opts) do
      {:ok, pid} -> {:ok, pid}
      other -> {:error, {:start_link, other}}
    end
  catch
    kind, reason -> {:error, {:crashed, Atanor.Workers.format_crash(kind, reason, __STACKTRACE__)}}
  end

  # The gen_smtp form: `{Callback, Opts}`. `callbackoptions` is the list
  # gen_smtp passes to `Callback:init/4`.
  defp with_env({callback, opts}, env, listener, tls) when is_atom(callback) and is_list(opts) do
    opts = merge(opts, env, listener, tls)
    callback_options = Keyword.get(opts, :callbackoptions, [])

    callback_options =
      if Keyword.keyword?(callback_options),
        do: Keyword.merge(callback_options, atanor_env: env, atanor_listener: listener),
        else: callback_options

    {callback, Keyword.put(opts, :callbackoptions, callback_options)}
  end

  defp with_env(opts, env, listener, tls) when is_list(opts), do: merge(opts, env, listener, tls)

  defp with_env(opts, env, listener, tls) when is_map(opts),
    do: Map.merge(opts, %{atanor_env: env, atanor_listener: listener, atanor_tls_options: tls})

  defp with_env(opts, _env, _listener, _tls), do: opts

  defp merge(opts, env, listener, tls) do
    opts
    |> Keyword.put(:atanor_env, env)
    |> Keyword.put(:atanor_listener, listener)
    |> Keyword.put(:atanor_tls_options, tls)
    |> then(fn opts -> if tls == [], do: opts, else: Keyword.put(opts, :tls_options, tls) end)
  end

  defp tls_options(instance, listener) do
    case TLS.mode(instance, listener) do
      :starttls ->
        case TLS.options(instance, listener) do
          {:ok, opts} -> opts
          :error -> []
        end

      _ ->
        []
    end
  end

  defp close(ref, transport) do
    pid =
      spawn_link(fn ->
        case apply(:ranch, :handshake, [ref]) do
          {:ok, socket} -> transport.close(socket)
          _ -> :ok
        end
      end)

    {:ok, pid}
  end

  defp watch(pid, meta, started) do
    spawn(fn ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, reason} ->
          :telemetry.execute(
            [:atanor, :tcp, :disconnect],
            %{duration: System.monotonic_time() - started},
            Map.merge(meta, %{reason: reason(reason), exit_reason: reason})
          )
      end
    end)
  end

  defp reason(:normal), do: :peer
  defp reason(:shutdown), do: :shutdown
  defp reason({:shutdown, _}), do: :shutdown
  defp reason(_reason), do: :error

  defp meta(env, listener) do
    %{
      worker: Env.worker(env),
      deployment: env.deployment.id,
      listener: listener,
      cell: nil
    }
  end
end
