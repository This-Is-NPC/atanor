defmodule Atanor.Unavailable do
  @moduledoc false
  # The availability reasons the ingress can report (design §8.4). A reason is
  # kept as an atom from the cell call that failed to the HTTP answer, so the
  # client is told whether the call did not run and why.

  require Logger

  alias Atanor.{Cell, Config}

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
  def reason({:unavailable, reason}), do: reason(reason) || :owner_unreachable
  def reason({:unavailable, _owner, _expires_at_ms}), do: :owner_unreachable
  def reason({:lost, _node, _reason}), do: :owner_unreachable
  def reason({:cell_down, reason}), do: reason(reason) || :owner_unreachable
  def reason({:wake_failed, _}), do: :owner_unreachable
  def reason(_), do: nil

  @doc """
  The `Retry-After` of a 503, in seconds. `held_elsewhere` (a node outside the cluster holds the lease of the
  routed `cell`, so it is no member) waits for the lease: one `http.retry_after_s` when it is released or no longer held, else the
  time to its expiry plus the skew margin, at most `http.retry_after_max_s`. Any other reason, or a lease that
  cannot be read, gets `http.retry_after_s`.
  """
  @spec retry_after_s(Config.t(), term, Cell.address() | nil) :: pos_integer
  def retry_after_s(%Config{http: http} = config, :held_elsewhere, {_ns, _key} = cell) do
    with {:ok, id} <- Cell.id(cell),
         {:ok, %{owner: nil, released: false, expires_at_ms: expires}} when is_integer(expires) <-
           Alambique.lease(config.alambique, id) do
      left_ms = expires + Config.skew_margin_ms(config) - Config.now_ms(config)
      left_s = ceil(left_ms / 1_000)
      left_s |> max(http.retry_after_s) |> min(max(http.retry_after_max_s, http.retry_after_s))
    else
      _ -> http.retry_after_s
    end
  end

  def retry_after_s(%Config{http: http}, _reason, _cell), do: http.retry_after_s

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
