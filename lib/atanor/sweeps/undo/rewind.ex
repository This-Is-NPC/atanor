defmodule Atanor.Sweeps.Undo.Rewind do
  @moduledoc false
  # One cell of an undo apply (design §15.10): rewind the cell to the position
  # the operation recorded, if no data was written since the report.
  #
  # `keep: :internal` carries Atanor's `_atanor_*` tables over from the current
  # state, so the jobs, alarms and undo positions do not go back. `schema:
  # :same` refuses a position with another `user_version`, because a rewound
  # cell cannot be migrated forward together with carried tables.
  #
  # "Written since the report" is Alambique's data TXID: `if_head: {txid, :data}`
  # refuses the rewind when data was committed after the report's head and
  # ignores wakes, which commit empty fences. It is checked again under the
  # lease, so no write slips in between. A rewind counts as data.

  alias Atanor.{Alarms, Cell}

  @doc """
  The `"apply"` entry of a cell: a map with a `"state"` of

    * `"rewound"` with `"txid"` (the rewind), `"from"`, `"to"`, `"kept"` and `"at_ms"`;
    * `"data_written"` with `"data"` (the TXID of the last data commit) and
      `"expected"` (the report's head): the cell was written since the report
      and was left as it was;
    * `"unknown"`: the rewind may have landed, and the cell is left to the operator;
    * `"skipped"` with `"reason"`;
    * `"failed"` with `"error"` (`"stage"` and `"message"`).

  A cell whose earlier try is `"rewinding"` or `"unknown"` may have been rewound
  already: a rewind counts as data, so the cell then reads as written since the
  report and its entry is `"unknown"`.
  """
  @spec run(atom, map, map) :: map
  def run(_instance, _config, %{"head_txid" => nil}), do: skipped("no_head")

  def run(instance, config, entry) do
    started = System.monotonic_time(:millisecond)
    {:ok, address} = Cell.parse(entry["cell"])

    opts = [
      if_head: {entry["head_txid"], :data},
      keep: :internal,
      schema: :same,
      timeout: config.sweeps.undo_timeout_ms
    ]

    result =
      case Cell.rewind(instance, address, {:txid, entry["before_txid"]}, opts) do
        {:ok, rewind} -> rewound(rewind, config)
        {:error, reason} -> failure(reason, entry)
      end

    :telemetry.execute(
      [:atanor, :sweep, :undo_rewind],
      %{count: 1, duration_ms: System.monotonic_time(:millisecond) - started},
      %{instance: instance, cell: entry["cell"], result: result["state"], node: node()}
    )

    result
  end

  @doc "The entry of a cell whose rewind task was killed: the rewind may have landed."
  @spec killed(term) :: map
  def killed(reason), do: %{"state" => "unknown", "error" => error(reason)}

  defp rewound(rewind, config) do
    %{
      "state" => "rewound",
      "txid" => rewind.txid,
      "from" => rewind.from,
      "to" => rewind.to,
      "kept" => rewind.kept,
      "at_ms" => Alarms.now(config)
    }
  end

  defp failure({:data_written, data}, entry) do
    state = if get_in(entry, ["apply", "state"]) in ["rewinding", "unknown"], do: "unknown", else: "data_written"
    %{"state" => state, "data" => data, "expected" => entry["head_txid"]}
  end

  defp failure(reason, _entry) when reason in [:outcome_unknown, :timeout],
    do: %{"state" => "unknown", "error" => error(reason)}

  defp failure(reason, _entry), do: %{"state" => "failed", "error" => error(reason)}

  defp skipped(reason), do: %{"state" => "skipped", "reason" => reason}

  defp error(reason), do: %{"stage" => "rewind", "message" => inspect(reason)}
end
