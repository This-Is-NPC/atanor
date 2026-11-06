defmodule Atanor.HTTP.Socket do
  @moduledoc false
  # A WebSocket served by a worker (design §7.3): the `WebSock` callbacks run
  # the worker's `handle_ws/3` (or a WASM worker's socket handler) through
  # `Atanor.Dispatch`. The deployment is the one the upgrade request resolved.
  @behaviour WebSock

  alias Atanor.{Dispatch, Env, Registry}
  alias Atanor.Diagnostics.Breadcrumb

  defstruct [:env, :cell, :worker, :started, :breadcrumb, :rate, :burst, :tokens, :refilled]

  @impl true
  def init(%{env: env, cell: cell, worker: worker} = arg) do
    env = %{env | socket: self()}

    breadcrumb =
      Breadcrumb.open(env.instance, %{
        kind: "websocket",
        worker: Env.worker(env),
        deployment: env.deployment.id,
        cell: {:cell, cell}
      })

    limits = Registry.config(env.instance).websocket
    now = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      env: env,
      cell: cell,
      worker: worker,
      started: System.monotonic_time(),
      breadcrumb: breadcrumb,
      rate: limits.max_frames_per_s,
      burst: limits.frame_burst,
      tokens: limits.frame_burst,
      refilled: now
    }

    # A socket on a protected route ends with its token (1008), whatever the idle timeout says.
    if exp = arg[:expires_at],
      do:
        Process.send_after(self(), :atanor_token_expired, max(trunc(exp * 1000) - System.system_time(:millisecond), 0))

    :telemetry.execute([:atanor, :ws, :connect], %{count: 1}, meta(state))
    {:ok, state}
  end

  @impl true
  def handle_in({data, opcode: opcode}, state) when opcode in [:text, :binary] do
    case take(state, System.monotonic_time(:millisecond)) do
      {:ok, state} -> frame({opcode, data}, state)
      :limit -> {:stop, :normal, 1008, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:atanor_cell_message, message}, state), do: deliver({:cell_message, message}, state)
  def handle_info(:atanor_token_expired, state), do: {:stop, :normal, 1008, state}
  def handle_info({:atanor_channel, frame}, state), do: {:push, frame, state}
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    Breadcrumb.hold(state.breadcrumb)

    try do
      Dispatch.execute(state.env, state.cell, {:ws_close, state.worker})
    after
      Breadcrumb.release(state.breadcrumb)
      Breadcrumb.close(state.breadcrumb)
    end

    duration = System.monotonic_time() - state.started
    :telemetry.execute([:atanor, :ws, :disconnect], %{duration: duration}, Map.put(meta(state), :reason, reason))
  end

  # Token bucket: `websocket.max_frames_per_s` refills, up to `websocket.frame_burst`. `now` is in milliseconds.
  @doc false
  def take(state, now) do
    tokens = min(state.burst, state.tokens + (now - state.refilled) * state.rate / 1000)
    if tokens >= 1, do: {:ok, %{state | tokens: tokens - 1, refilled: now}}, else: :limit
  end

  # A worker with a local callback sees every frame first, on this node (design §7.6).
  defp frame(message, %{env: %{deployment: %{local_ws?: true}}} = state) do
    case held(state, fn -> Dispatch.execute_local(state.env, state.cell, {:ws_local, message, state.worker}) end) do
      {:ok, :pass} -> deliver(message, state)
      {:ok, :drop} -> {:ok, state}
      {:error, _} -> {:stop, :error, state}
    end
  end

  defp frame(message, state), do: deliver(message, state)

  defp held(state, fun) do
    Breadcrumb.hold(state.breadcrumb)

    try do
      fun.()
    after
      Breadcrumb.release(state.breadcrumb)
    end
  end

  defp deliver(message, state) do
    result = held(state, fn -> Dispatch.execute(state.env, state.cell, {:ws_in, message, state.worker}) end)

    case result do
      {:ok, {:ok, worker}} -> {:ok, %{state | worker: worker}}
      {:ok, {:reply, frames, worker}} -> {:push, frames, %{state | worker: worker}}
      {:ok, {:stop, worker}} -> {:stop, :normal, %{state | worker: worker}}
      {:ok, {:close, frames, worker}} -> {:stop, :normal, 1000, frames, %{state | worker: worker}}
      {:error, _} -> {:stop, :error, state}
    end
  end

  defp meta(state), do: %{worker: Env.worker(state.env), deployment: state.env.deployment.id, cell: state.cell}
end
