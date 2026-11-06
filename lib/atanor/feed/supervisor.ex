defmodule Atanor.Feed.Supervisor do
  @moduledoc false
  # The dynamic supervisor of the instance's change feed tailers. A tailer is
  # started by the first subscriber and stops when none remain.

  use DynamicSupervisor

  def child_spec(config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, type: :supervisor}
  end

  def start_link(config), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: name(config.name))

  @doc "The dynamic supervisor of the instance's feed tailers."
  def name(instance), do: Module.concat(instance, FeedSupervisor)

  @doc "Starts the instance's tailer at `position`, or returns the running one."
  def start_tailer(instance, position) do
    case DynamicSupervisor.start_child(name(instance), {Atanor.Feed.Tailer, {instance, position}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
end
