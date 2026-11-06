defmodule Atanor.Jobs.Drain do
  @moduledoc false
  # On a graceful stop, stop taking new job work (the alarm scheduler goes
  # before this child) and give local tasks up to `stop.jobs_ms` to finish.
  # The slots process is still alive because it stops after this child.
  # `release/1` makes the claims this node leaves behind claimable at once, for the node that takes the cells.

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

  @doc false
  # Releases this node's claims in the cells it holds, while it still owns them (the hibernation that
  # follows hands them back). It releases nothing while a job still runs here: that job is not over,
  # and its claim keeps it from running twice. Returns the number of claims released.
  @spec release(Atanor.Config.t()) :: {:ok, non_neg_integer} | {:busy, pos_integer}
  def release(%{jobs: %{release_claims: false}}), do: {:ok, 0}

  def release(config) do
    case running(config.name) do
      0 -> {:ok, release_cells(config, nil, 0)}
      running -> {:busy, running}
    end
  end

  defp release_cells(config, after_id, released) do
    %{cells: ids, next: next} = Alambique.cells(config.alambique, after: after_id, limit: 100)

    released =
      ids
      |> Task.async_stream(&Jobs.release_own(config.name, &1),
        max_concurrency: config.stop.drain_concurrency,
        timeout: config.stop.drain_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.reduce(released, fn
        {:ok, {:ok, count}}, acc -> acc + count
        _, acc -> acc
      end)

    if next, do: release_cells(config, next, released), else: released
  end

  defp wait(instance, deadline) do
    if running(instance) > 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      wait(instance, deadline)
    else
      :ok
    end
  end

  defp running(instance) do
    Registry.config(instance) && Jobs.stats(instance).running
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end
end
