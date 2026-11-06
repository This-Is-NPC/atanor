defmodule Atanor.Test.FeedSubscriber do
  @moduledoc """
  A process that subscribes to the change feed on the node where `start/4`
  runs and forwards its messages to `target`; used by the cluster tests.
  """

  @doc "Starts the subscriber and sends `{:feed_subscribed, pid, ref}` to `target`."
  def start(instance, worker, namespace, target) when is_pid(target) do
    spawn(fn ->
      {:ok, deployment} = Atanor.Registry.deployment(instance, worker)
      env = Atanor.Env.new(instance, deployment)
      {:ok, ref} = Atanor.Env.subscribe(env, namespace, from: :now)
      send(target, {:feed_subscribed, self(), ref})
      loop(target, ref)
    end)
  end

  defp loop(target, ref) do
    receive do
      {:atanor_changes, ^ref, changes, position} ->
        send(target, {:feed_changes, changes, position})
        loop(target, ref)

      {:atanor_feed_dropped, ^ref, position} ->
        send(target, {:feed_dropped, position})
    end
  end
end
