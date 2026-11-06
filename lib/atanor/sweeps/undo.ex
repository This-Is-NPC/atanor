defmodule Atanor.Sweeps.Undo do
  @moduledoc """
  The undo of a bulk operation (design §15.10), in two steps that share one
  record under `undos/<operation-id>` in the metadata store.

  `start/2` makes the report: it restores every target cell that holds a
  position of the operation at that position and at the latest point in the
  store, and compares the two copies. It runs as a task on the node that
  received the request, in temporary files under
  `data_dir/undos/<operation-id>/` that are removed when it ends, and never
  writes a live cell.

  `rewind/2` applies a finished report: it rewinds each cell to its recorded
  position with `Alambique.rewind/4`, only if the cell is still at the head the
  report saw. The record is the ledger of the cells already rewound, so a
  repeated call continues where the last one stopped (`Atanor.Sweeps.Undo.Rewind`).

  A record is `running` until the task writes the final state (`done` or
  `failed`). A `running` record not updated for `sweeps.undo_stale_ms` is read
  as `stale`: its node died. The record is removed with its operation.
  """

  require Logger

  alias Atanor.{Alarms, Registry, Restore, Store, Sweeps}
  alias Atanor.Diagnostics.Breadcrumb
  alias Atanor.Sweeps.Undo.{Cell, Rewind}

  @prefix "undos/"
  @id ~r/\A[0-9A-Za-z]+\z/

  @type error ::
          :not_found
          | :undo_not_enabled
          | :already_running
          | :operation_active
          | :report_required
          | :report_truncated
          | :jobs_active
          | {:store, term}

  @doc """
  Starts the report of `operation_id` and returns its record (state
  `"running"`). A finished or stale record is replaced; the cells that an
  earlier apply rewound keep their entry and are not read again.
  """
  @spec start(atom, String.t()) :: {:ok, map} | {:error, error}
  def start(instance, operation_id) do
    config = Registry.config(instance)

    with {:ok, op, _etag} <- operation(instance, operation_id),
         :ok <- enabled(op),
         {:ok, previous, condition} <- idle(instance, config, operation_id),
         record = new_record(config, operation_id),
         {:ok, _etag} <- put(instance, record, condition) do
      rewound = rewound(previous)
      {:ok, _} = Task.Supervisor.start_child(Atanor.Tasks.name(instance), fn -> task(instance, op, record, rewound) end)
      {:ok, record}
    end
  end

  @doc """
  Applies the finished report of `operation_id`: starts the rewind of its cells
  and returns the record (mode `"apply"`, state `"running"`). It needs a
  settled operation (`done` or `cancelled`), a report that is not truncated and
  has no pending or running job. Calling it again after a `done`, `failed` or
  `stale` apply continues with the cells that were not rewound.
  """
  @spec rewind(atom, String.t()) :: {:ok, map} | {:error, error}
  def rewind(instance, operation_id) do
    config = Registry.config(instance)

    with {:ok, op, _etag} <- operation(instance, operation_id),
         :ok <- enabled(op),
         :ok <- settled(op),
         {:ok, previous, etag} <- finished(instance, config, operation_id),
         record = new_apply_record(config, previous),
         {:ok, _etag} <- put(instance, record, {:if_match, etag}) do
      {:ok, _} = Task.Supervisor.start_child(Atanor.Tasks.name(instance), fn -> rewind_task(instance, record) end)
      {:ok, record}
    end
  end

  @doc "The report of an operation, with `stale` for an abandoned `running` one."
  @spec get(atom, String.t()) :: {:ok, map} | {:error, :not_found | {:store, term}}
  def get(instance, operation_id) do
    with {:ok, record, _etag} <- read(instance, operation_id),
         do: {:ok, present(record, Registry.config(instance))}
  end

  @doc "Removes the report of an operation; a missing one is not an error."
  @spec delete(atom, String.t()) :: :ok
  def delete(instance, operation_id) do
    _ = Store.delete(instance, @prefix <> operation_id)
    :ok
  end

  defp operation(instance, id) do
    if Regex.match?(@id, id) do
      case Sweeps.get(instance, id) do
        {:error, reason} when reason != :not_found -> {:error, {:store, reason}}
        other -> other
      end
    else
      {:error, :not_found}
    end
  end

  defp enabled(op), do: if(get_in(op, ["undo", "enabled"]) == true, do: :ok, else: {:error, :undo_not_enabled})

  defp settled(op), do: if(op["state"] in ["done", "cancelled"], do: :ok, else: {:error, :operation_active})

  # A running record that still beats its heartbeat blocks a new one.
  defp idle(instance, config, id) do
    case read(instance, id) do
      {:ok, record, etag} ->
        if effective_state(record, config) == "running",
          do: {:error, :already_running},
          else: {:ok, record, {:if_match, etag}}

      {:error, :not_found} ->
        {:ok, nil, :if_none_match}

      {:error, _} = error ->
        error
    end
  end

  # What an apply starts from: a finished report, or the record of an earlier apply.
  defp finished(instance, config, id) do
    case idle(instance, config, id) do
      {:ok, nil, _condition} -> {:error, :report_required}
      {:ok, %{"mode" => "report", "state" => state}, _} when state != "done" -> {:error, :report_required}
      {:ok, %{"mode" => "report", "summary" => %{"truncated" => true}}, _} -> {:error, :report_truncated}
      {:ok, %{"summary" => %{"pending_jobs" => pending}}, _} when pending > 0 -> {:error, :jobs_active}
      {:ok, record, {:if_match, etag}} -> {:ok, record, etag}
      {:error, _} = error -> error
    end
  end

  # The entries of the cells that an apply rewound, by cell id.
  defp rewound(%{"mode" => "apply", "cells" => cells}),
    do: for(%{"apply" => %{"state" => "rewound"}} = entry <- cells, into: %{}, do: {entry["cell"], entry})

  defp rewound(_previous), do: %{}

  defp new_apply_record(config, previous) do
    previous
    |> Map.merge(new_record(config, previous["operation"]))
    |> Map.merge(%{"mode" => "apply", "cells" => previous["cells"], "summary" => previous["summary"]})
    |> Map.put("report_undo_id", previous["report_undo_id"] || previous["undo_id"])
  end

  defp new_record(config, operation_id) do
    now = Alarms.now(config)

    %{
      "undo_id" => "u-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
      "operation" => operation_id,
      "mode" => "report",
      "state" => "running",
      "node" => Atom.to_string(node()),
      "started_at_ms" => now,
      "updated_at_ms" => now,
      "finished_at_ms" => nil,
      "summary" => nil,
      "cells" => [],
      "error" => nil
    }
  end

  # -- task -------------------------------------------------------------------

  defp task(instance, op, record, rewound) do
    config = Registry.config(instance)
    root = Path.join(config.data_dir, "undos")
    dir = Path.join(root, op["id"])
    meta = %{kind: "undo_report", operation_id: op["id"]}

    try do
      Breadcrumb.wrap(instance, meta, fn ->
        File.mkdir_p!(root)
        Restore.remove_abandoned(root, config.sweeps.undo_stale_ms)
        File.rm_rf!(dir)
        File.mkdir_p!(dir)
        finish(instance, config, record, report(instance, config, op, record, dir, rewound))
      end)
    rescue
      exception -> fail(instance, config, record, Exception.message(exception))
    catch
      kind, reason -> fail(instance, config, record, inspect({kind, reason}))
    after
      File.rm_rf(dir)
    end
  end

  # A page at a time, so the record shows progress and the copies of a page are
  # gone before the next one.
  defp report(instance, config, op, record, dir, rewound) do
    max = config.sweeps.undo_max_cells
    start = %{walked: 0, entries: [], truncated: false, beat: record["started_at_ms"]}

    instance
    |> Sweeps.pages(%{op | "cursor" => nil})
    |> Enum.reduce_while({:ok, start}, fn
      {:error, reason}, _acc ->
        {:halt, {:error, "listing the target cells failed: " <> inspect(reason)}}

      {:ok, cells}, {:ok, acc} ->
        entries = acc.entries ++ run_cells(instance, config, op, cells, dir, {acc.walked, rewound})
        acc = %{acc | walked: acc.walked + length(cells), entries: entries}
        acc = heartbeat(instance, config, record, acc)

        if length(entries) >= max,
          do: {:halt, {:ok, %{acc | entries: Enum.take(entries, max), truncated: true}}},
          else: {:cont, {:ok, acc}}
    end)
  end

  defp run_cells(instance, config, op, cells, dir, {offset, rewound}) do
    cells
    |> Enum.with_index(offset)
    |> then(
      &Task.Supervisor.async_stream_nolink(
        Atanor.Tasks.name(instance),
        &1,
        fn {address, index} ->
          files = {Path.join(dir, "#{index}-before.db"), Path.join(dir, "#{index}-latest.db")}

          case Map.fetch(rewound, elem(address, 0) <> "." <> elem(address, 1)) do
            {:ok, entry} -> entry
            :error -> Cell.run(instance, config, address, op["id"], files)
          end
        end,
        max_concurrency: config.sweeps.undo_concurrency,
        timeout: 2 * config.sweeps.undo_timeout_ms,
        on_timeout: :kill_task,
        zip_input_on_exit: true,
        ordered: true
      )
    )
    |> Enum.flat_map(fn
      {:ok, :no_position} -> []
      {:ok, entry} -> [entry]
      {:exit, {{{namespace, key}, _index}, reason}} -> [failed(namespace <> "." <> key, reason)]
    end)
  end

  defp failed(id, reason) do
    stage = if reason == :timeout, do: "timeout", else: "task"

    %{
      "cell" => id,
      "before_txid" => nil,
      "before_at_ms" => nil,
      "job_state" => nil,
      "frozen" => nil,
      "restorable" => false,
      "error" => %{"stage" => stage, "message" => inspect(reason)}
    }
  end

  # -- apply -------------------------------------------------------------------

  # The record is the ledger: it is stored after every cell, so a rewind that
  # landed is known to the next call even when this node dies.
  defp rewind_task(instance, record) do
    config = Registry.config(instance)
    meta = %{kind: "undo_apply", operation_id: record["operation"]}

    try do
      Breadcrumb.wrap(instance, meta, fn -> rewind_cells(instance, config, record) end)
    rescue
      exception -> fail_apply(instance, config, record, Exception.message(exception))
    catch
      kind, reason -> fail_apply(instance, config, record, inspect({kind, reason}))
    end
  end

  # The ledger in the store is newer than the record the task started with.
  defp fail_apply(instance, config, record, message) do
    undo_id = record["undo_id"]

    current =
      case read(instance, record["operation"]) do
        {:ok, %{"undo_id" => ^undo_id} = stored, _etag} -> stored
        _ -> record
      end

    fail(instance, config, current, message)
  end

  # Cells go in groups of `undo_concurrency`. The ledger marks a group as
  # `rewinding` before it starts, so a node that dies in the middle leaves a
  # mark that the next call reads: that cell may already be rewound.
  defp rewind_cells(instance, config, record) do
    pending =
      for {entry, index} <- Enum.with_index(record["cells"]), get_in(entry, ["apply", "state"]) != "rewound", do: index

    final =
      pending
      |> Enum.chunk_every(config.sweeps.undo_concurrency)
      |> Enum.reduce(record, fn group, acc -> rewind_group(instance, config, acc, group) end)

    done(instance, config, final, %{"state" => "done", "summary" => apply_summary(final), "cells" => final["cells"]})
  end

  defp rewind_group(instance, config, record, group) do
    entries = Enum.map(group, &{Enum.at(record["cells"], &1), &1})

    record =
      Enum.reduce(entries, record, fn {_entry, index}, acc -> put_apply(acc, index, %{"state" => "rewinding"}) end)

    record = ledger(record, instance, config)

    instance
    |> Atanor.Tasks.name()
    |> Task.Supervisor.async_stream_nolink(
      entries,
      fn {entry, index} -> {index, Rewind.run(instance, config, entry)} end,
      max_concurrency: config.sweeps.undo_concurrency,
      timeout: 2 * config.sweeps.undo_timeout_ms,
      on_timeout: :kill_task,
      zip_input_on_exit: true,
      ordered: false
    )
    |> Enum.reduce(record, fn
      {:ok, {index, result}}, acc ->
        acc |> put_apply(index, result) |> ledger(instance, config)

      {:exit, {{_entry, index}, reason}}, acc ->
        acc |> put_apply(index, Rewind.killed(reason)) |> ledger(instance, config)
    end)
  end

  defp put_apply(record, index, result) do
    cells = List.update_at(record["cells"], index, &Map.put(&1, "apply", result))
    %{record | "cells" => cells}
  end

  defp ledger(record, instance, config) do
    record = %{record | "updated_at_ms" => Alarms.now(config), "summary" => apply_summary(record)}
    store(instance, record)
    record
  end

  defp apply_summary(%{"cells" => cells, "summary" => summary}) do
    counts = Enum.frequencies_by(cells, &get_in(&1, ["apply", "state"]))

    summary
    |> Map.merge(
      for state <- ["rewound", "data_written", "skipped", "failed", "unknown", "rewinding"], into: %{} do
        {state, Map.get(counts, state, 0)}
      end
    )
    |> Map.put("waiting", Map.get(counts, nil, 0))
  end

  # -- record -----------------------------------------------------------------

  defp summary(%{walked: walked, entries: entries, truncated: truncated}) do
    %{
      "cells" => walked,
      "with_position" => length(entries),
      "restorable" => Enum.count(entries, & &1["restorable"]),
      "unrestorable" => Enum.count(entries, &(not &1["restorable"])),
      "pending_jobs" => Enum.count(entries, &(&1["job_state"] in ["pending", "running"])),
      "truncated" => truncated
    }
  end

  # The heartbeat is written at most every quarter of the stale time.
  defp heartbeat(instance, config, record, acc) do
    now = Alarms.now(config)

    if now - acc.beat >= div(config.sweeps.undo_stale_ms, 4) do
      store(instance, %{record | "updated_at_ms" => now, "summary" => summary(acc)})
      %{acc | beat: now}
    else
      acc
    end
  end

  defp finish(instance, config, record, {:ok, acc}) do
    done(instance, config, record, %{"state" => "done", "summary" => summary(acc), "cells" => acc.entries})
  end

  defp finish(instance, config, record, {:error, message}), do: fail(instance, config, record, message)

  defp fail(instance, config, record, message) do
    Logger.warning("atanor: undo report of #{record["operation"]} failed: #{message}")
    done(instance, config, record, %{"state" => "failed", "error" => %{"stage" => "task", "message" => message}})
  end

  defp done(instance, config, record, fields) do
    now = Alarms.now(config)
    final = record |> Map.merge(fields) |> Map.merge(%{"updated_at_ms" => now, "finished_at_ms" => now})

    if store(instance, final) == :ok do
      {event, measurements} =
        case final["mode"] do
          "report" -> {:undo_report, %{cells: final["summary"]["cells"] || 0}}
          "apply" -> {:undo_apply, %{cells: length(final["cells"]), rewound: final["summary"]["rewound"] || 0}}
        end

      :telemetry.execute(
        [:atanor, :sweep, event],
        Map.merge(%{count: 1, duration_ms: now - record["started_at_ms"]}, measurements),
        %{instance: instance, operation: record["operation"], state: final["state"], node: node()}
      )
    end

    :ok
  end

  # A record that was replaced after this one went stale is not overwritten.
  defp store(instance, record) do
    undo_id = record["undo_id"]

    with {:ok, %{"undo_id" => ^undo_id}, etag} <- read(instance, record["operation"]),
         {:ok, _etag} <-
           Store.put(instance, @prefix <> record["operation"], Jason.encode!(record), {:if_match, etag}) do
      :ok
    else
      {:ok, _replaced, _etag} ->
        :replaced

      {:error, :precondition_failed} ->
        :replaced

      {:error, reason} ->
        Logger.warning("atanor: undo record could not be stored: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp present(record, config), do: %{record | "state" => effective_state(record, config)}

  defp effective_state(%{"state" => "running", "updated_at_ms" => updated}, config) do
    if Alarms.now(config) - updated > config.sweeps.undo_stale_ms, do: "stale", else: "running"
  end

  defp effective_state(%{"state" => state}, _config), do: state

  defp read(instance, id) do
    with true <- Regex.match?(@id, id),
         {:ok, body, etag, _meta} <- Store.get(instance, @prefix <> id) do
      {:ok, Jason.decode!(body), etag}
    else
      false -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp put(instance, record, condition) do
    case Store.put(instance, @prefix <> record["operation"], Jason.encode!(record), condition) do
      {:ok, etag} -> {:ok, etag}
      {:error, :precondition_failed} -> {:error, :already_running}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end
end
