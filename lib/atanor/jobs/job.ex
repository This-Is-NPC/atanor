defmodule Atanor.Jobs.Job do
  @moduledoc """
  One job handed to a worker's `handle_job/2` (design §15). The id is stable
  across retries and takeovers; use it, or `idempotency_key`, to deduplicate
  effects outside the cell (design §8.13).
  """

  @enforce_keys [:id, :cell, :worker, :kind, :payload, :attempt, :max_attempts]
  defstruct [
    :id,
    :cell,
    :worker,
    :kind,
    :payload,
    :idempotency_key,
    :operation_id,
    :inserted_at_ms,
    :due_at_ms,
    attempt: 1,
    max_attempts: 1
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          cell: Atanor.Cell.address(),
          worker: String.t(),
          kind: String.t(),
          payload: binary,
          idempotency_key: String.t() | nil,
          operation_id: String.t() | nil,
          inserted_at_ms: integer | nil,
          due_at_ms: integer | nil,
          attempt: pos_integer,
          max_attempts: pos_integer
        }
end
