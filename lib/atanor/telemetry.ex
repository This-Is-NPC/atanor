defmodule Atanor.Telemetry do
  @moduledoc false
  # The events of calls into workers (docs/telemetry.md).

  alias Atanor.{Env, Response}

  @doc """
  Times `fun`, which returns `{:ok, value} | {:error, reason}` (a Plug's conn counts), and emits
  `[:atanor, :call]` with the worker, deployment, cell and outcome.
  """
  def call(%Env{} = env, cell, kind, forwarded?, fun) do
    started = System.monotonic_time()
    result = fun.()

    meta = %{
      worker: Env.worker(env),
      deployment: env.deployment.id,
      cell: cell,
      kind: kind,
      node: node(),
      instance: env.instance,
      forwarded: forwarded?,
      release: Atanor.Release.id(env.instance)
    }

    :telemetry.execute(
      [:atanor, :call],
      %{duration: System.monotonic_time() - started},
      Map.merge(meta, outcome(result))
    )

    result
  end

  defp outcome({:ok, %Response{status: status}}), do: %{result: :ok, status: status}
  defp outcome({:ok, %Plug.Conn{status: status}}), do: %{result: :ok, status: status}
  defp outcome({:error, %Plug.Conn{status: status}}), do: %{result: :error, reason: :plug_failed, status: status}
  defp outcome({:ok, _}), do: %{result: :ok}
  defp outcome({:error, reason}), do: %{result: :error, reason: reason}
end
