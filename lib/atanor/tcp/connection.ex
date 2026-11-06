defmodule Atanor.TCP.Connection do
  @moduledoc false
  # One accepted TCP connection (design §7.3). It pins the deployment that
  # claimed the listener when the connection arrived and runs the worker's TCP
  # callbacks through `Atanor.Dispatch` until the connection closes.
  use ThousandIsland.Handler

  require Logger

  alias Atanor.{Dispatch, Env, Registry}
  alias Atanor.TCP.TLS

  defstruct [:env, :listener, :cell, :worker, :started, :closed, bytes_in: 0, bytes_out: 0]

  @impl ThousandIsland.Handler
  def handle_connection(socket, %{instance: instance, listener: listener}) do
    case Registry.listener(instance, listener) do
      {:ok, deployment} ->
        env = Env.new(instance, deployment)
        state = %__MODULE__{env: env, listener: listener, started: System.monotonic_time()}
        :telemetry.execute([:atanor, :tcp, :connect], %{count: 1}, meta(state))
        {:ok, {_ip, _port} = peer} = ThousandIsland.Socket.peername(socket)

        case Dispatch.execute(env, nil, {:tcp_init, %{listener: listener, peer: peer}}) do
          {:ok, {:ok, worker}} -> advance(socket, state, {:ok, {:continue, worker}})
          other -> advance(socket, state, other)
        end

      :error ->
        {:close, nil}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %__MODULE__{} = state) do
    state = %{state | bytes_in: state.bytes_in + byte_size(data)}
    advance(socket, state, Dispatch.execute(state.env, state.cell, {:tcp_data, data, state.worker}))
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state), do: disconnect(state, :peer)
  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state), do: disconnect(state, :timeout)
  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state), do: disconnect(state, :shutdown)
  @impl ThousandIsland.Handler
  def handle_error(_reason, _socket, state), do: disconnect(state, :error)

  defp advance(socket, state, {:ok, {:continue, worker}}), do: bind(socket, %{state | worker: worker}, [])
  defp advance(socket, state, {:ok, {:reply, bytes, worker}}), do: bind(socket, %{state | worker: worker}, bytes)

  defp advance(socket, state, {:ok, {:starttls, bytes, worker}}) do
    state = %{state | worker: worker}

    with {:ok, state} <- send_bytes(socket, state, bytes),
         :ok <- Atanor.TCP.starttls(state.env.instance, state.listener) do
      {:switch_transport, {TLS.Transport, %{instance: state.env.instance, listener: state.listener}}, state}
    else
      {:error, reason} ->
        Logger.error("atanor: listener #{state.listener} refuses STARTTLS: #{inspect(reason)}")
        {:close, %{state | closed: :error}}
    end
  end

  defp advance(socket, state, {:ok, {:close, bytes}}) do
    _ = send_bytes(socket, state, bytes)
    {:close, %{state | closed: :worker}}
  end

  defp advance(_socket, state, {:error, _}), do: {:close, %{state | closed: :error}}

  # The routing key is asked after the worker answered, until it names a cell.
  defp bind(socket, state, bytes) do
    with {:ok, state} <- send_bytes(socket, state, bytes),
         {:ok, state} <- route(state) do
      {:continue, state}
    else
      {:error, _} -> {:close, %{state | closed: :error}}
    end
  end

  defp route(%{cell: nil} = state) do
    case Dispatch.route(state.env, {:tcp, state.worker}) do
      {:ok, cell, :strong} -> {:ok, %{state | cell: cell}}
      :none -> {:ok, state}
      {:error, _} = error -> error
    end
  end

  defp route(state), do: {:ok, state}

  defp send_bytes(_socket, state, []), do: {:ok, state}

  defp send_bytes(socket, state, bytes) do
    with :ok <- ThousandIsland.Socket.send(socket, bytes),
         do: {:ok, %{state | bytes_out: state.bytes_out + IO.iodata_length(bytes)}}
  end

  defp disconnect(%__MODULE__{} = state, reason) do
    measurements = %{
      duration: System.monotonic_time() - state.started,
      bytes_in: state.bytes_in,
      bytes_out: state.bytes_out
    }

    :telemetry.execute(
      [:atanor, :tcp, :disconnect],
      measurements,
      Map.put(meta(state), :reason, state.closed || reason)
    )
  end

  defp disconnect(_, _), do: :ok

  defp meta(state) do
    %{worker: Env.worker(state.env), deployment: state.env.deployment.id, listener: state.listener, cell: state.cell}
  end
end
