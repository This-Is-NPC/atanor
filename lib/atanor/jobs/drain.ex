defmodule Atanor.Jobs.Drain do
  @moduledoc false
  # On a graceful stop, stop taking new job work (the alarm scheduler goes
  # before this child) and give local tasks up to `stop.jobs_ms` to finish.
  # The slots process is still alive because it stops after this child.

  use GenServer

  alias Atanor.{Jobs, Registry}

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {GenServer, :start_link, [__MODULE__, config, [name: name(config.name)]]},
      # The wait in terminate/2 ends at stop.jobs_ms; the supervisor gives it a little more before it kills it.
      shutdown: config.stop.jobs_ms + 5_000
    }
  end

  def name(instance), do: Module.concat(instance, JobsDrain)

  @impl true
  def init(config) do
    # Without it the supervisor's shutdown signal kills the process and terminate/2 never runs.
    Process.flag(:trap_exit, true)
    {:ok, config}
  end

  @impl true
  def terminate(_reason, config), do: run(config)

  @doc false
  # Shared with `Atanor.Drain`, which runs it first when a drain is asked for.
  def run(config) do
    # A job that finishes now must not start the next one of its cell.
    try do
      Atanor.Jobs.Slots.close(config.name)
    catch
      _, _ -> :ok
    end

    deadline = System.monotonic_time(:millisecond) + config.stop.jobs_ms
    wait(config.name, deadline)
  end

  defp wait(instance, deadline) do
    running =
      try do
        Registry.config(instance) && Jobs.stats(instance).running
      rescue
        _ -> 0
      catch
        _, _ -> 0
      end

    if running > 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      wait(instance, deadline)
    else
      :ok
    end
  end
end
