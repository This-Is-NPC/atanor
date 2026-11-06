defmodule Atanor.Change do
  @moduledoc """
  One row change read from the change feed (design §16).

  A change is plain data: the cell `namespace` and `cell` key, the `table`, the
  `op` (`:insert`, `:update` or `:delete`), the primary `key` and the new `row`
  as maps of column to value (as Alambique records them, `row` is `nil` for a
  delete), the `txid` of the replicated batch, the record time `at` in Unix
  milliseconds and Alambique's record `id`.

  `row` can be partial. With `alambique: [feed: [tables: ...]]` the instance
  leaves columns out of the feed: a column that is not a key of `row` was
  omitted by that configuration, it is not NULL (a NULL column is present with
  the value `nil`). The columns of `key` are always in `row`. An update that
  changes only omitted columns produces no change. Read an omitted column from
  the cell, in a call.

  `id` is the idempotency key: delivery is at least once, so the same change
  can be read or delivered more than once with the same `id`. Table names that
  start with `_atanor_` are Atanor's own bookkeeping; they are internal to the feed and never appear.

  When a cell is rewound the list also holds an `Atanor.Change.Rewind` marker.
  """

  @enforce_keys [:namespace, :cell, :table, :op, :key, :row, :txid, :at, :id]
  defstruct [:namespace, :cell, :table, :op, :key, :row, :txid, :at, :id]

  @type op :: :insert | :update | :delete

  @type t :: %__MODULE__{
          namespace: String.t(),
          cell: String.t(),
          table: String.t(),
          op: op,
          key: %{optional(String.t()) => term},
          row: %{optional(String.t()) => term} | nil,
          txid: pos_integer,
          at: non_neg_integer,
          id: String.t()
        }

  @doc false
  @spec from_record(Alambique.Feed.Record.t() | Alambique.Feed.Rewind.t()) ::
          {:ok, t | Atanor.Change.Rewind.t()} | {:error, :invalid_cell_id}
  def from_record(%Alambique.Feed.Rewind{} = marker) do
    with {:ok, {namespace, cell}} <- Atanor.Cell.parse(marker.cell) do
      {:ok,
       %Atanor.Change.Rewind{
         namespace: namespace,
         cell: cell,
         from_txid: marker.from_txid,
         to_txid: marker.to_txid,
         txid: marker.txid,
         target: marker.target,
         kept: marker.kept,
         at: marker.at,
         id: marker.id
       }}
    end
  end

  def from_record(%Alambique.Feed.Record{} = record) do
    with {:ok, {namespace, cell}} <- Atanor.Cell.parse(record.cell) do
      {:ok,
       %__MODULE__{
         namespace: namespace,
         cell: cell,
         table: record.table,
         op: record.op,
         key: record.key,
         row: record.values,
         txid: elem(record.position, 0),
         at: record.at,
         id: record.id
       }}
    end
  end
end
