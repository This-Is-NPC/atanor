defmodule Atanor.Unavailable do
  @moduledoc false
  # The availability reasons the ingress can report (design §8.4). A reason is
  # kept as an atom from the cell call that failed to the HTTP answer, so the
  # client is told whether the call did not run and why.

  require Logger

  @reasons [
    :no_quorum,
    :owner_unreachable,
    :owner_down,
    :draining,
    :held_elsewhere,
    :fenced,
    :overloaded,
    :deployment_unavailable,
    :store_unavailable
  ]

  @doc "The reasons a 503 can name."
  @spec reasons() :: [atom]
  def reasons, do: @reasons

  @doc "The availability reason of an error term, or `nil` when it is not one."
  @spec reason(term) :: atom | nil
  def reason(:no_quorum), do: :no_quorum
  def reason(:owner_unreachable), do: :owner_unreachable
  def reason(:owner_down), do: :owner_down
  def reason(:held_elsewhere), do: :held_elsewhere
  def reason(:fenced), do: :fenced
  def reason(:lease_lost), do: :fenced
  def reason(:lease_expired), do: :fenced
  def reason(:overloaded), do: :overloaded
  def reason(:busy), do: :overloaded
  # A full disk: SQLite's message for SQLITE_FULL (what an ENOSPC on the database or the WAL becomes), or the
  # POSIX atom. The statement did not commit, and the node recovers when it frees the disk (`Atanor.Disk`).
  def reason("database or disk is full"), do: :overloaded
  def reason(:enospc), do: :overloaded
  def reason(:draining), do: :draining
  def reason(:stale), do: :owner_unreachable
  def reason(:taken_elsewhere), do: :owner_unreachable
  def reason(:takeover_contended), do: :owner_down
  def reason(:epoch_changed), do: :owner_unreachable
  def reason({:epoch_changed, _epoch}), do: :owner_unreachable
  def reason({:contended, _owner, _epoch}), do: :owner_unreachable
  def reason({:deployment_unavailable, _}), do: :deployment_unavailable
  # The store did not answer a request a transaction needed; the transaction was rolled back.
  def reason({:store, _}), do: :store_unavailable
  # The lease could not be read for a read or a lookup, which ran nothing.
  def reason({:lease_unreadable, _}), do: :store_unavailable
  # A transaction function that did not match the error of a statement (`{:ok, _} = Tx.execute(...)`) fails
  # with the error as the term of the exception: the reason is that of the error.
  def reason({:raised, %{term: {:error, error}}, _stacktrace}), do: reason(error)
  def reason({:unavailable, reason}), do: reason(reason) || :owner_unreachable
  def reason({:unavailable, _owner, _expires_at_ms}), do: :owner_unreachable
  def reason({:lost, _node, _reason}), do: :owner_unreachable
  def reason({:cell_down, reason}), do: reason(reason) || :owner_unreachable
  def reason({:wake_failed, _}), do: :owner_unreachable
  def reason(_), do: nil

  @doc """
  The error a routing failure becomes. A `{:foreign_store, node}` is a
  configuration error (a node of another store joined this instance): it is kept
  as it is, logged, and never retried or counted as unavailability (design §8.4).
  Any other failure is `{:unavailable, reason}`, `:owner_unreachable` when the
  term names no reason.
  """
  @spec error(atom, term) :: {:error, {:foreign_store, node} | {:unavailable, atom}}
  def error(instance, {:foreign_store, node} = reason) do
    foreign_store(instance, node)
    {:error, reason}
  end

  def error(_instance, reason), do: {:error, {:unavailable, reason(reason) || :owner_unreachable}}

  @doc false
  # Logs and emits `[:atanor, :foreign_store]` for a call refused toward `node`.
  def foreign_store(instance, node) do
    :telemetry.execute([:atanor, :foreign_store], %{count: 1}, %{instance: instance, node: node})

    Logger.error(
      "atanor: #{inspect(node)} runs this instance over another store or prefix, so the call was refused " <>
        "(foreign_store). Give every node of the instance the same store and placement (design §8.4)."
    )
  end

  @doc "The availability reason of an `{:error, reason}` tuple, or `nil`."
  @spec from_error(term) :: atom | nil
  def from_error({:error, reason}), do: reason(reason)
  def from_error(_), do: nil
end
