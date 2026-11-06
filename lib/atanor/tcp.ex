defmodule Atanor.TCP do
  @moduledoc """
  TCP listeners (design §7.3). One listener runs for each operator
  `listeners:` name that an active deployment claims with a manifest route
  `{"tcp": {"listener": name}}` (or `{"tcp": {"listener": name, "protocol":
  "ranch"}}`).

  `Atanor.Workers` calls `open/2` before it registers a deployment, so a port
  that cannot be bound refuses the activation, and `sync/1` afterwards, which
  closes the listeners nobody claims anymore. Closing a listener ends its
  connections.

  The server starts after the first load of the deployments (design §2.1),
  which therefore finds it absent: it opens the listeners the registry holds
  when it starts, and logs the ones it cannot bind.

  A listener runs on ThousandIsland by default, or on Ranch when the operator
  configures `protocol: :ranch`; Ranch is an optional dependency, and a ranch
  listener refuses the activation when it is not loaded. A listener with
  `tls_mode: :implicit` speaks TLS from the first byte. A listener with
  `tls_mode: :starttls` gives the worker a plain socket and upgrades it when
  the worker returns `{:starttls, bytes, state}` from `handle_tcp/3`; the
  connection handler then calls `starttls/2` and switches the socket to the
  listener's current certificate.
  """

  use GenServer

  require Logger

  alias Atanor.{Registry, TCP.Connection, TCP.TLS}

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: server(config.name)]]}}
  end

  @doc """
  Starts the listeners in `names` that are not running. Names the operator did
  not map are left to the registry, which refuses them.
  """
  @spec open(atom, [String.t()]) :: :ok | {:error, {:listener_failed, String.t(), term}}
  def open(instance, names), do: call(instance, {:open, names})

  @doc "Closes the listeners that no active deployment claims."
  @spec sync(atom) :: :ok
  def sync(instance), do: call(instance, :sync)

  @doc "The port a running listener is bound to."
  @spec port(atom, String.t()) :: {:ok, :inet.port_number()} | :error
  def port(instance, listener) do
    case GenServer.call(server(instance), {:listener, listener}) do
      %{kind: :ranch, ref: ref} ->
        case apply(:ranch, :get_port, [ref]) do
          port when is_integer(port) -> {:ok, port}
          _ -> :error
        end

      %{kind: :thousand_island, pid: pid} ->
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        {:ok, port}

      nil ->
        :error
    end
  end

  @doc """
  Whether `listener` accepts STARTTLS upgrades. Called by the connection
  handler when a worker returns `{:starttls, bytes, state}` from
  `handle_tcp/3`; `:ok` lets the handler switch the connection to TLS with the
  certificate loaded at that moment. Both a plain and an implicit-TLS listener
  refuse it.
  """
  @spec starttls(atom, String.t()) :: :ok | {:error, term}
  def starttls(instance, listener) do
    case TLS.mode(instance, listener) do
      :starttls -> :ok
      :implicit -> {:error, :already_tls}
      nil -> {:error, :not_starttls}
      :error -> {:error, :not_starttls}
    end
  end

  defp server(instance), do: Module.concat(instance, TCP)

  defp call(instance, message) do
    case GenServer.whereis(server(instance)) do
      nil -> :ok
      pid -> GenServer.call(pid, message)
    end
  end

  @impl true
  def init(config) do
    # A listener that fails to start must not take the instance down.
    Process.flag(:trap_exit, true)

    state =
      Enum.reduce(Registry.listeners(config.name), %{config: config, listeners: %{}}, fn name, state ->
        case start(state, name) do
          {:ok, state} ->
            state

          {:error, reason} ->
            Logger.error("atanor: TCP listener #{name} not opened: #{inspect(reason)}")
            state
        end
      end)

    {:ok, state}
  end

  @impl true
  def handle_call({:open, names}, _from, state) do
    names = Enum.filter(names, &is_map_key(state.config.listeners, &1))

    result =
      Enum.reduce_while(names, {:ok, state}, fn name, {:ok, state} ->
        case start(state, name) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, reason} -> {:halt, {:error, {:listener_failed, name, reason}, state}}
        end
      end)

    case result do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:sync, _from, state) do
    claimed = MapSet.new(Registry.listeners(state.config.name))

    listeners =
      Map.filter(state.listeners, fn {name, listener} ->
        keep? = name in claimed
        unless keep?, do: close(listener)
        keep?
      end)

    {:reply, :ok, %{state | listeners: listeners}}
  end

  def handle_call({:listener, listener}, _from, state), do: {:reply, state.listeners[listener], state}
  def handle_call({:pid, listener}, _from, state), do: {:reply, listener_pid(state.listeners[listener]), state}

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    {gone, listeners} = Map.split_with(state.listeners, fn {_name, listener} -> Map.get(listener, :pid) == pid end)

    for {name, _} <- gone, reason != :normal do
      Logger.error("atanor: TCP listener #{name} stopped: #{inspect(reason)}")
    end

    {:noreply, %{state | listeners: listeners}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.listeners, fn {_name, listener} -> close(listener) end)
    :ok
  end

  defp start(%{listeners: running} = state, name) when is_map_key(running, name), do: {:ok, state}

  defp start(%{config: config} = state, name) do
    listener = Map.fetch!(config.listeners, name)

    case listener.protocol do
      :thousand_island -> start_thousand_island(state, listener)
      :ranch -> start_ranch(state, listener)
    end
  end

  defp start_thousand_island(state, listener) do
    config = state.config
    tcp = config.tcp
    implicit? = listener.tls_mode == :implicit

    with {:ok, transport_options} <- transport_options(config, listener) do
      options = [
        port: listener.port,
        handler_module: Connection,
        handler_options: %{instance: config.name, listener: listener.name},
        transport_options: transport_options,
        read_timeout: tcp.idle_timeout_ms,
        shutdown_timeout: config.stop.connections_ms,
        num_acceptors: listener.acceptors,
        num_connections: ceil(listener.max_connections / listener.acceptors)
      ]

      options =
        if implicit? do
          options ++
            [
              transport_module: TLS.Transport,
              handshake_timeout: listener.tls.handshake_timeout_ms
            ]
        else
          options
        end

      case ThousandIsland.start_link(options) do
        {:ok, pid} ->
          {:ok, put_listener(state, listener.name, %{kind: :thousand_island, pid: pid})}

        {:error, {:shutdown, {:failed_to_start_child, _, reason}}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp start_ranch(state, listener) do
    config = state.config

    with :ok <- ranch_available(),
         {:ok, _apps} <- Application.ensure_all_started(:ranch),
         {:ok, transport, socket_opts} <- ranch_authentication(config, listener) do
      trans_opts = %{
        num_acceptors: listener.acceptors,
        max_connections: listener.max_connections,
        handshake_timeout: handshake_timeout(listener),
        socket_opts: [ip: listener.ip, port: listener.port] ++ socket_opts
      }

      ref = {:atanor, config.name, listener.name}

      case apply(:ranch, :start_listener, [
             ref,
             transport,
             trans_opts,
             Atanor.TCP.Ranch,
             %{
               instance: config.name,
               listener: listener.name
             }
           ]) do
        {:ok, _pid} ->
          {:ok, put_listener(state, listener.name, %{kind: :ranch, ref: ref})}

        {:error, {:already_started, _pid}} ->
          {:ok, put_listener(state, listener.name, %{kind: :ranch, ref: ref})}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Ranch is an optional dependency. Without it, a ranch listener refuses the
  # activation instead of failing at load time.
  defp ranch_available do
    if Code.ensure_loaded?(:ranch) and function_exported?(:ranch, :start_listener, 5),
      do: :ok,
      else: {:error, {:missing_dependency, :ranch}}
  end

  defp ranch_authentication(config, listener) do
    if listener.tls_mode == :implicit do
      case TLS.options(config.name, listener.name) do
        {:ok, ssl_opts} ->
          {:ok, Atanor.TCP.Ranch.Transport, ssl_opts ++ [atanor: %{instance: config.name, listener: listener.name}]}

        :error ->
          {:error, {:tls, :not_configured}}
      end
    else
      {:ok, :ranch_tcp, []}
    end
  end

  defp transport_options(config, %{tls_mode: :implicit} = listener) do
    case TLS.options(config.name, listener.name) do
      {:ok, ssl_opts} ->
        {:ok,
         [
           ip: listener.ip,
           buffer: config.tcp.max_chunk_bytes,
           atanor: %{instance: config.name, listener: listener.name}
         ] ++
           ssl_opts}

      :error ->
        {:error, {:tls, :not_configured}}
    end
  end

  defp transport_options(config, listener), do: {:ok, [ip: listener.ip, buffer: config.tcp.max_chunk_bytes]}

  defp handshake_timeout(%{tls: %{handshake_timeout_ms: timeout}}), do: timeout
  defp handshake_timeout(_listener), do: 5_000

  defp put_listener(state, name, listener),
    do: %{state | listeners: Map.put(state.listeners, name, listener)}

  defp listener_pid(%{kind: :thousand_island, pid: pid}), do: pid
  defp listener_pid(_listener), do: nil

  defp close(%{kind: :ranch, ref: ref}) do
    _ = apply(:ranch, :stop_listener, [ref])
    :ok
  end

  defp close(%{kind: :thousand_island, pid: pid}) do
    ThousandIsland.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end
end
