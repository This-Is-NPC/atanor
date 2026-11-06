defmodule Atanor.Takeover do
  @moduledoc """
  The early takeover of one cell whose owner the detector confirmed down
  (design §8.10). Everything that resolves the owner of a cell calls `recover/3`
  when the owner is `{:unavailable, owner, _}`: `Atanor.Dispatch` for HTTP, TCP,
  WebSocket and alarm work, and `Atanor.Cell` for the cell calls of workers.

  It is lazy and per cell: Atanor never lists the cells of a lost node. The
  call that needs a cell takes it, so the cost lands on the cells that are used.
  Safety does not depend on the verdict: `Alambique.take_over/4` raises the
  epoch with a conditional write, and the old owner is fenced if it was only
  slow.
  """

  alias Atanor.Deployments.Watcher
  alias Atanor.{Detector, Fence, Jobs, Registry}

  @doc """
  Takes the cell with Alambique id `id` over on this node when its lease names
  `owner`, a node the detector has confirmed down.

    * `{:ok, node}`: the cell is served by `node` now (this node, or the one that
      won a concurrent takeover);
    * `:stale`: the lease no longer names `owner` (the cell was taken, or
      released, meanwhile): look the owner up again;
    * `:no_quorum`: this node and the peers it still reaches are not a majority
      of the nodes it knows (`takeover.quorum`), so it may be the one that was
      cut off; it leaves the cell to the other side or to its lease;
    * `{:error, :owner_down}`: the detector confirms the owner down but takeover
      is disabled; the cell waits for its lease;
    * `{:error, :owner_unreachable}`: the owner is not confirmed down yet, or the
      takeover did not finish; the call did not run;
    * `{:error, :held_elsewhere}`: the owner is no node of this cluster (see `unreachable/2`); the call
      did not run and this node never takes the cell from it.

  A takeover that lost a race (`:epoch_changed`, `:contended`) reads the lease
  again, up to `takeover.attempts` times, so two nodes that suspect the same
  owner end with one winner and the epoch raised once.
  """
  @spec recover(atom, String.t(), String.t()) ::
          {:ok, node} | :stale | :no_quorum | {:error, :owner_down | :owner_unreachable | :held_elsewhere | term}
  def recover(instance, id, owner) do
    config = Registry.config(instance)

    case Detector.down_owner(instance, owner) do
      {:ok, _node, _reason} when not config.takeover.enabled ->
        {:error, :owner_down}

      {:ok, node, reason} ->
        started = System.monotonic_time()

        result =
          if config.takeover.quorum and not quorum?(instance),
            do: :no_quorum,
            else: attempt(config, id, owner, {node, reason}, config.takeover.attempts)

        :telemetry.execute([:atanor, :cell, :take_over], %{duration: System.monotonic_time() - started}, %{
          instance: instance,
          cell: id,
          node: node,
          reason: reason,
          result: outcome(result)
        })

        result

      :error ->
        {:error, unreachable(instance, owner)}
    end
  end

  @doc """
  Why a cell whose lease names `owner` cannot be reached and `owner` is not down: `:held_elsewhere` when
  `owner` is no node of this cluster (a node being replaced holds it until it hands it back or the lease
  ends), else `:owner_unreachable`.
  """
  @spec unreachable(atom, String.t()) :: :held_elsewhere | :owner_unreachable
  def unreachable(instance, owner) do
    if Enum.any?(Watcher.nodes(instance), &(Atom.to_string(&1) == owner)),
      do: :owner_unreachable,
      else: :held_elsewhere
  end

  defp quorum?(instance) do
    Detector.quorum?(instance)
  catch
    :exit, _ -> false
  end

  defp attempt(_config, _id, _owner, _down, 0), do: {:error, :takeover_contended}

  defp attempt(config, id, owner, {node, reason} = down, attempts) do
    case lease(config, id) do
      {:ok, %{owner_id: ^owner, released: false, epoch: epoch, expires_at_ms: expires}} ->
        # Before the takeover, so no handler of this node can start in the gap: the old owner's fence ends
        # at `expires - skew_margin` on its clock (design §8.13).
        Fence.hold(config, id, expires)

        opts = [epoch: epoch] ++ if(config.takeover.timeout_ms, do: [timeout: config.takeover.timeout_ms], else: [])

        case Alambique.take_over(config.alambique, id, {:atanor_node_down, node, reason}, opts) do
          {:ok, served_by} ->
            release_claims(config, id, node, epoch + 1)
            {:ok, served_by}

          {:error, {:epoch_changed, _}} ->
            attempt(config, id, owner, down, attempts - 1)

          {:error, {:contended, _, _}} ->
            attempt(config, id, owner, down, attempts - 1)

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error

      # Released, taken by another node, or never held: the ordinary lookup serves it.
      _ ->
        :stale
    end
  end

  # The jobs the dead node had claimed in the cell become claimable on the new owner (design §15.11).
  # It runs off the caller's path: the request that needed the cell does not wait for it.
  defp release_claims(%{jobs: %{release_claims: true}, name: instance}, id, node, epoch) do
    Task.Supervisor.start_child(Atanor.Tasks.name(instance), fn -> Jobs.release_claims(instance, id, node, epoch) end)
  end

  defp release_claims(_config, _id, _node, _epoch), do: :ok

  defp lease(config, id) do
    opts = if config.takeover.timeout_ms, do: [timeout: config.takeover.timeout_ms], else: []

    case Alambique.lease(config.alambique, id, opts) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, {:lease_unreadable, reason}}
    end
  end

  defp outcome({:ok, node}), do: if(node == node(), do: :ok, else: :moved)
  defp outcome(:stale), do: :stale
  defp outcome(:no_quorum), do: :no_quorum
  defp outcome({:error, reason}), do: {:error, reason}
end
