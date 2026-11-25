defmodule Atanor.Rehearsal.Cell do
  @moduledoc false
  # One sampled cell of a rehearsal (design §17.3): restore a copy of the
  # cell, apply the candidate's migrations to the copy with `Alambique.Sqlite`
  # and describe the result. Alambique applies a migration through an
  # `Alambique.Tx`, which only exists inside a live cell, so the loop below is
  # the file-level equivalent: one transaction per version that also sets
  # `PRAGMA user_version`, with each statement held to the rules of a
  # migration in a live cell: one statement per string and no transaction
  # control. Every statement gets what is left of the cell's time budget.

  alias Alambique.Sqlite
  alias Atanor.Restore

  # Objects of the library (internal tables and their triggers) are not part of the
  # comparison, and the capture triggers are dropped from the copy: a live cell
  # drops them around every DDL statement, and SQLite refuses to drop a column that
  # a trigger names.
  @user_objects ~S"""
  SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_master
  WHERE name NOT LIKE '\_alambique\_%' ESCAPE '\' AND name NOT LIKE 'sqlite\_%' ESCAPE '\'
  ORDER BY type, name
  """
  @capture_triggers ~S"SELECT name FROM sqlite_master WHERE type = 'trigger' AND sql LIKE '%\_alambique\_feed%' ESCAPE '\'"

  @doc """
  Rehearses `migrations` (`[{version, [statement]}]`) on a restored copy of
  `cell` at `path`. Returns the cell's report, a map with string keys.
  """
  @spec run(map, String.t(), [{pos_integer, [String.t()]}], Path.t(), map) :: map
  def run(%{location: location, clock: clock}, cell, migrations, path, options) do
    started = System.monotonic_time(:millisecond)
    deadline = started + options.timeout_ms
    {namespace, key} = split(cell)
    base = %{"cell" => cell, "namespace" => namespace, "key" => key, "location" => location.id}

    outcome =
      try do
        restore_and_migrate(location, clock, cell, migrations, path, options, deadline)
      after
        File.rm(path)
      end

    duration = System.monotonic_time(:millisecond) - started

    case outcome do
      {:ok, report} -> base |> Map.merge(report) |> Map.put("duration_ms", duration)
      {:error, error} -> Map.merge(base, %{"outcome" => "failed", "error" => error, "duration_ms" => duration})
    end
  end

  defp split(cell) do
    [namespace, key] = String.split(cell, ".", parts: 2)
    {namespace, key}
  end

  defp restore_and_migrate(location, clock, cell, migrations, path, options, deadline) do
    with {:ok, restored} <- restore(location, clock, cell, path, options),
         :ok <- not_empty(restored, path) do
      open_and_migrate(path, migrations, options, deadline)
    end
  end

  defp restore(location, clock, cell, path, options) do
    case Restore.to_file(location, clock, cell, path, :latest, options.timeout_ms) do
      {:ok, restored} -> {:ok, restored}
      {:error, reason} -> {:error, error("restore", nil, reason)}
    end
  end

  # A cell that never committed has nothing to migrate.
  defp not_empty(%{txid: 0}, _path), do: {:ok, %{"outcome" => "empty"}}
  defp not_empty(_restored, path), do: if(File.exists?(path), do: :ok, else: {:ok, %{"outcome" => "empty"}})

  defp open_and_migrate(path, migrations, options, deadline) do
    case Sqlite.open(path) do
      {:ok, conn} ->
        try do
          migrate(conn, migrations, options, deadline)
        after
          Sqlite.close(conn)
        end

      {:error, reason} ->
        {:error, error("open", nil, reason)}
    end
  end

  defp migrate(conn, migrations, options, deadline) do
    max_version = migrations |> Enum.map(&elem(&1, 0)) |> Enum.max()

    with {:ok, _} <- run(conn, "PRAGMA recursive_triggers = ON", deadline),
         {:ok, from} <- user_version(conn, deadline),
         :ok <- not_too_new(from, max_version),
         {:ok, before} <- describe(conn, deadline),
         :ok <- drop_capture_triggers(conn, deadline),
         {:ok, applied} <- apply_all(conn, Enum.filter(migrations, &(elem(&1, 0) > from)), deadline),
         {:ok, integrity} <- integrity(conn, options.integrity_check, deadline),
         {:ok, after_state} <- describe(conn, deadline) do
      {:ok,
       %{
         "outcome" => if(applied == [], do: "nothing_pending", else: "migrated"),
         "from_version" => from,
         "to_version" => max(from, max_version),
         "applied" => Enum.map(applied, &elem(&1, 0)),
         "version_durations_ms" => Map.new(applied, fn {version, ms} -> {Integer.to_string(version), ms} end),
         "row_counts_before" => before.rows,
         "row_counts_after" => after_state.rows,
         "row_count_decreased" => for({table, n} <- before.rows, Map.get(after_state.rows, table, n) < n, do: table),
         "schema_hash" => after_state.schema,
         "integrity" => integrity,
         "error" => nil
       }
       |> fail_on_integrity()}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, timed_out(reason, nil) |> as_error("open")}
    end
  end

  # One statement with what is left of the cell's time budget; Alambique stops
  # it at that deadline with `:statement_timeout`.
  defp run(conn, sql, deadline, opts \\ []) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 -> Sqlite.run(conn, sql, [], [{:timeout_ms, left} | opts])
      _ -> {:error, :statement_timeout}
    end
  end

  defp not_too_new(from, max_version) when from <= max_version, do: :ok

  defp not_too_new(from, max_version),
    do:
      {:error,
       error("migration", from, "cell is at version #{from}, past the candidate's #{max_version} (schema_too_new)")}

  defp fail_on_integrity(%{"integrity" => "ok"} = report), do: report

  defp fail_on_integrity(report),
    do: %{report | "outcome" => "failed", "error" => error("check", nil, report["integrity"])}

  defp user_version(conn, deadline) do
    case run(conn, "PRAGMA user_version", deadline) do
      {:ok, %{rows: [[version]]}} -> {:ok, version}
      {:error, reason} -> {:error, timed_out(reason, nil) |> as_error("open")}
    end
  end

  # `{:ok, [{version, duration_ms}]}`; the first failing version stops the rest.
  defp apply_all(conn, pending, deadline) do
    Enum.reduce_while(pending, {:ok, []}, fn {version, statements}, {:ok, done} ->
      started = System.monotonic_time(:millisecond)

      with :ok <- before_deadline(deadline, version),
           :ok <- apply_version(conn, version, statements, deadline) do
        {:cont, {:ok, [{version, System.monotonic_time(:millisecond) - started} | done]}}
      else
        {:error, %{} = error} -> {:halt, {:error, error}}
        {:error, reason} -> {:halt, {:error, error("migration", version, reason)}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  defp before_deadline(deadline, version) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, error("timeout", version, :timeout)}
  end

  defp apply_version(conn, version, statements, deadline) do
    with {:ok, _} <- run(conn, "BEGIN IMMEDIATE", deadline),
         :ok <- Enum.reduce_while(statements, :ok, &run_statement(conn, &1, &2, deadline)),
         {:ok, _} <- run(conn, "PRAGMA user_version = #{version}", deadline),
         {:ok, _} <- run(conn, "COMMIT", deadline) do
      :ok
    else
      {:error, reason} ->
        if Sqlite.transaction_status(conn) == {:ok, :transaction}, do: Sqlite.execute(conn, "ROLLBACK")
        {:error, timed_out(reason, version)}
    end
  end

  # A migration string is one statement, and the transaction is the
  # rehearsal's, as in a live cell: `A; B` gives `{:multiple_statements, _}`
  # and `BEGIN` or `COMMIT` gives `:not_authorized`.
  defp run_statement(conn, statement, :ok, deadline) do
    case run(conn, statement, deadline, no_transaction_control: true) do
      {:ok, _} -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp timed_out(:statement_timeout, version), do: error("timeout", version, :timeout)
  defp timed_out(reason, _version), do: reason

  defp drop_capture_triggers(conn, deadline) do
    with {:ok, %{rows: rows}} <- run(conn, @capture_triggers, deadline) do
      Enum.reduce_while(rows, :ok, fn [name], :ok ->
        case run(conn, "DROP TRIGGER main." <> Restore.quote_identifier(name), deadline) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, error("open", nil, reason)}}
        end
      end)
    else
      {:error, reason} -> {:error, timed_out(reason, nil) |> as_error("open")}
    end
  end

  defp integrity(conn, check, deadline) do
    case run(conn, "PRAGMA " <> Atom.to_string(check), deadline) do
      {:ok, %{rows: [["ok"]]}} -> {:ok, "ok"}
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      {:error, reason} -> {:error, timed_out(reason, nil) |> as_error("check")}
    end
  end

  defp as_error(%{} = error, _stage), do: error
  defp as_error(reason, stage), do: error(stage, nil, reason)

  # Row counts per user table, and a hash of the normalized schema.
  defp describe(conn, deadline) do
    with {:ok, %{rows: objects}} <- run(conn, @user_objects, deadline),
         {:ok, rows} <- count_rows(conn, for(["table", name | _] <- objects, do: name), deadline) do
      normalized = for [type, name, table, sql] <- objects, do: [type, name, table, String.split(sql)]
      hash = :crypto.hash(:sha256, :erlang.term_to_binary(normalized)) |> Base.encode16(case: :lower)
      {:ok, %{rows: rows, schema: hash}}
    else
      {:error, reason} -> {:error, timed_out(reason, nil) |> as_error("check")}
    end
  end

  defp count_rows(conn, tables, deadline) do
    Enum.reduce_while(tables, {:ok, %{}}, fn table, {:ok, acc} ->
      case run(conn, "SELECT count(*) FROM " <> Restore.quote_identifier(table), deadline) do
        {:ok, %{rows: [[n]]}} -> {:cont, {:ok, Map.put(acc, table, n)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp error(stage, version, reason) do
    %{"stage" => stage, "version" => version, "message" => if(is_binary(reason), do: reason, else: inspect(reason))}
  end
end
