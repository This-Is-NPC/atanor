defmodule Atanor.Signal do
  @moduledoc false
  # SIGTERM runs the drain while the listeners keep serving, then stops the VM (design §8.11). The
  # application swaps this handler in for OTP's `erl_signal_handler`, which would call `init:stop/0` at
  # once and close the listeners first, and swaps it back when the application stops. The other signals
  # keep OTP's behavior.
  @behaviour :gen_event

  require Logger

  @server :erl_signal_server
  @default :erl_signal_handler

  @doc "Installs the handler. Nothing changes when OTP's own handler is not there."
  @spec install() :: :ok | {:error, term}
  def install, do: swap(@default, __MODULE__)

  @doc "Puts OTP's handler back."
  @spec uninstall() :: :ok | {:error, term}
  def uninstall, do: swap(__MODULE__, @default)

  defp swap(from, to) do
    case :gen_event.swap_handler(@server, {from, []}, {to, []}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(_args), do: {:ok, :ok}

  @impl true
  def handle_event(:sigterm, state) do
    # The drain takes seconds: it does not run in the event manager, which also delivers the other signals.
    spawn(&terminate/0)
    {:ok, state}
  end

  def handle_event(event, state) do
    {:ok, ^state} = @default.handle_event(event, {:state})
    {:ok, state}
  end

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}
  @impl true
  def handle_info(_info, state), do: {:ok, state}

  @doc false
  # Drains every running instance whose `stop.sigterm` is `:drain`, in parallel, then stops the VM with
  # status 1 if any left a cell to its lease. A drain that fails is a status 1 too, and the VM stops anyway.
  # A second SIGTERM joins the drains that run (it forces nothing; SIGKILL does).
  def terminate do
    Logger.info("atanor: SIGTERM received, draining before the VM stops")

    status =
      Atanor.Drain.instances()
      |> Task.async_stream(&drain/1, timeout: :infinity, ordered: false)
      |> Enum.reduce(0, fn
        {:ok, status}, acc -> max(status, acc)
        {:exit, _reason}, _acc -> 1
      end)

    stop = Application.get_env(:atanor, :vm_stop, &System.stop/1)
    stop.(status)
  end

  defp drain(instance) do
    case Atanor.drain(instance, exit: false) do
      {:ok, %{errors: []}} -> 0
      _ -> 1
    end
  catch
    _kind, _reason -> 1
  end
end
