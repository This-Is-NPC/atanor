defmodule Atanor.Tasks do
  @moduledoc false
  # The instance's background tasks (job attempts, alarm handlers, lease reads, migrations, moves). They use
  # the instance's tables, so the supervisor stops before the detector and Alambique (design §8.11).

  @doc "Name of the task supervisor of instance `name`."
  def name(name), do: Module.concat(name, Tasks)

  def child_spec(config) do
    Supervisor.child_spec({Task.Supervisor, name: name(config.name)}, shutdown: config.stop.tasks_ms)
  end
end
