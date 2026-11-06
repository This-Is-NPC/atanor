defmodule Atanor.Test.ScriptedWorker do
  @moduledoc """
  Test worker whose every callback returns what `script/1` last set, to check how the dispatcher judges
  the values a worker returns. A test that uses it runs alone (`async: false`) or in the one module that sets it.
  """
  @behaviour Atanor.Worker

  def script(value), do: :persistent_term.put(__MODULE__, value)

  defp answer do
    case :persistent_term.get(__MODULE__) do
      {:raise, message} -> raise message
      value -> value
    end
  end

  @impl true
  def handle_request(_request, _env), do: %Atanor.Response{status: 200}

  @impl true
  def route_key(_input, _env), do: answer()

  @impl true
  def ranch_protocol(_env), do: answer()

  @impl true
  def tcp_init(_info, _env), do: answer()

  @impl true
  def handle_tcp(_data, _state, _env), do: answer()

  @impl true
  def ws_init(_request, _env), do: answer()

  @impl true
  def handle_ws(_message, _state, _env), do: answer()

  @impl true
  def handle_ws_local(_message, _state, _env), do: answer()

  @impl true
  def handle_alarm(_cell, _payload, _env), do: answer()

  @impl true
  def handle_job(_job, _env), do: answer()
end
