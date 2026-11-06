defmodule Atanor.Change.Rewind do
  @moduledoc """
  The change feed marker of a cell rewind (design §16.6): the cell went back to
  an earlier state, for example because a bulk operation was undone
  (design §15.10).

  It is delivered in the same list as `Atanor.Change`, after the changes it
  undoes. After it, the cell holds the state it had at `to_txid`: a worker that
  keeps a copy of the cell must put the copy back to that state and carry on
  with the changes that follow. The changes of the cell with a `txid` above
  `to_txid` and at most `from_txid` were undone. Changes at or below `to_txid`
  can arrive again after the marker, with the `id` they had.

  Fields: the cell `namespace` and `cell` key, `from_txid` (the last TXID of the
  state that was replaced), `to_txid` (the TXID that was restored), `txid` (the
  rewind's own TXID), `target` (`{:txid, n}` or `{:timestamp, ms}`, what the
  caller asked for), `kept` (the internal tables, named `_atanor_*`, that stayed
  as they were), the publication time `at` in Unix milliseconds and the `id`,
  the idempotency key, as for `Atanor.Change`.
  """

  @enforce_keys [:namespace, :cell, :from_txid, :to_txid, :txid, :target, :kept, :at, :id]
  defstruct [:namespace, :cell, :from_txid, :to_txid, :txid, :target, :kept, :at, :id]

  @type t :: %__MODULE__{
          namespace: String.t(),
          cell: String.t(),
          from_txid: non_neg_integer,
          to_txid: non_neg_integer,
          txid: pos_integer,
          target: {:txid, non_neg_integer} | {:timestamp, integer},
          kept: [String.t()],
          at: non_neg_integer,
          id: String.t()
        }
end
