defmodule Atanor.Alarms.Scheduler do
  @moduledoc """
  Fires the due alarms of the shards this node owns (design §2, §7.4). Every
  `:tick_ms` it asks `Atanor.Alarms.run/2` to scan the store's alarm index.
  The schedulers of an instance's prefix, on every node, are the members of a
  `:pg` group; a shard belongs to the member that wins rendezvous hashing, so
  with one node it owns all of them.
  """
  use GenServer

  require Logger

  alias Atanor.Alarms

  @scope Atanor.PG

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: Module.concat(config.name, Alarms)]]}}
  end

  @impl true
  def init(config) do
    case Alarms.ensure_shards(config) do
      :ok ->
        :pg.join(@scope, Alarms.group(config.prefix), self())
        Process.send_after(self(), :tick, config.alarms.tick_ms)
        {:ok, config}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:tick, config) do
    scan(config)
    Process.send_after(self(), :tick, config.alarms.tick_ms)
    {:noreply, config}
  end

  def handle_info(_, config), do: {:noreply, config}

  defp scan(config) do
    me = self()

    # A view of the :pg group can be empty for a moment while the scheduler
    # starts or a peer leaves; this node still scans its own index.
    members =
      case :pg.get_members(@scope, Alarms.group(config.prefix)) do
        [] -> [me]
        members -> members
      end

    Alarms.run(config.name, fn shard -> Alarms.owner(members, shard) == me end)
  rescue
    exception -> Logger.error("atanor: alarm scan failed: " <> Exception.format(:error, exception, __STACKTRACE__))
  end
end
