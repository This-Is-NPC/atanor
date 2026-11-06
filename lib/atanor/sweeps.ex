defmodule Atanor.Sweeps do
  @moduledoc """
  Managed bulk operations (design §15.6). An operation is one JSON record in
  the metadata store; per-cell markers live in the target cells. A single
  driver holds a lease and resumes from the last processed page. Pause, resume
  and cancel are conditional writes on the record. The first cells are a
  canary and the job outcomes of recent cells feed an error-rate guard that
  halts the operation (design §15.8).
  """

  alias Atanor.{Cell, Dispatch, Jobs, Registry, Store}
  alias Atanor.Jobs.Schema

  @prefix "operations/"

  @guard_options ~w(canary_size canary_gate canary_window_ms canary_timeout_ms
                    guard_window_cells guard_error_rate guard_min_cells guard_poll_ms guard_attempts)a

  @doc "Creates a running operation and returns it."
  def start(instance, attrs) do
    config = Registry.config(instance)

    case Store.list(Store.handle(instance), @prefix, nil, config.sweeps.max_records) do
      {:ok, keys, _next} when length(keys) >= config.sweeps.max_records -> {:error, :too_many_operations}
      {:ok, _keys, _next} -> start(instance, config, attrs)
      {:error, _} = error -> error
    end
  end

  defp start(instance, config, attrs) do
    now = System.os_time(:millisecond)
    id = new_id(now)
    selector = selector!(attrs[:selector] || attrs["selector"], instance)
    action = action!(attrs[:action] || attrs["action"], config)
    granted!(instance, selector, action)
    rate = positive!(attrs[:rate_per_s] || attrs["rate_per_s"] || config.sweeps.rate_per_s, :rate_per_s)
    concurrency = positive!(attrs[:concurrency] || attrs["concurrency"] || config.sweeps.concurrency, :concurrency)
    page_size = positive!(attrs[:page_size] || attrs["page_size"] || config.sweeps.page_size, :page_size)

    if rate > config.sweeps.rate_per_s,
      do: raise(ArgumentError, "rate_per_s must not exceed the instance's sweeps rate_per_s")

    if concurrency > config.sweeps.concurrency,
      do: raise(ArgumentError, "concurrency must not exceed the instance's sweeps concurrency")

    if page_size > config.sweeps.page_size,
      do: raise(ArgumentError, "page_size must not exceed the instance's sweeps page_size")

    options = guard_options!(attrs, config)
    undo = undo!(Map.get(attrs, :undo, Map.get(attrs, "undo", config.sweeps.undo)))

    operation = %{
      "id" => id,
      "state" => "running",
      "selector" => selector,
      "action" => action,
      "rate_per_s" => rate,
      "concurrency" => concurrency,
      "page_size" => page_size,
      "cursor" => nil,
      "driver" => nil,
      "lease_id" => nil,
      "lease_until_ms" => 0,
      "counters" => %{"dispatched" => 0, "skipped" => 0, "failed" => 0, "jobs_failed" => 0},
      "last_error" => nil,
      "halt_reason" => nil,
      "canary" => canary_record(options),
      "guard" => guard_record(options),
      "undo" => %{"enabled" => undo, "positions" => 0},
      "recent" => [],
      "created_at_ms" => now,
      "updated_at_ms" => now
    }

    case Store.put(Store.handle(instance), @prefix <> id, Jason.encode!(operation), :if_none_match) do
      {:ok, _etag} ->
        emit(instance, operation, :started)
        {:ok, operation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Loads one operation."
  def get(instance, id) do
    with {:ok, body, etag, _meta} <- Store.get(Store.handle(instance), @prefix <> id) do
      {:ok, Jason.decode!(body), etag}
    end
  end

  @doc "Whether an operation record is in a state that never changes again."
  def terminal?(op), do: op["state"] in ["done", "cancelled", "failed"]

  @doc """
  All operation records. A record in `known`, a map of store key to a terminal record, is not read again.
  """
  def list(instance, after_key \\ nil, limit \\ 100, known \\ %{}) do
    with {:ok, keys, _next} <- Store.list(Store.handle(instance), @prefix, after_key, limit) do
      operations =
        for key <- keys,
            {:ok, op} <- [known_or_get(instance, key, known)],
            do: op

      {:ok, operations}
    end
  end

  defp known_or_get(instance, key, known) do
    case known do
      %{^key => op} ->
        {:ok, op}

      _ ->
        with {:ok, body, _etag, _meta} <- Store.get(Store.handle(instance), key), do: {:ok, Jason.decode!(body)}
    end
  end

  @doc "Pauses a running operation."
  def pause(instance, id), do: control(instance, id, "paused", ["running"])

  @doc """
  Resumes a paused or halted operation. A halted operation starts with an empty
  guard window; resuming one halted by its canary accepts the canary.
  """
  def resume(instance, id), do: control(instance, id, "running", ["paused", "halted"])

  @doc "Confirms the canary of an operation in `awaiting_confirmation` and continues it."
  def continue(instance, id), do: control(instance, id, "running", ["awaiting_confirmation"])

  @doc "Cancels a running, paused, halted or awaiting operation."
  def cancel(instance, id),
    do: control(instance, id, "cancelled", ["running", "paused", "halted", "awaiting_confirmation"])

  # The driver rewrites the record on every checkpoint and lease renewal, so the compare-and-swap of a control
  # can lose against it; the state is read again and the control retried.
  defp control(instance, id, state, from, attempt \\ 1) do
    attempts = Registry.config(instance).sweeps.control_attempts

    with {:ok, op, etag} <- get(instance, id),
         true <- op["state"] in from do
      now = System.os_time(:millisecond)
      updated = op |> reopen(state) |> Map.merge(%{"state" => state, "updated_at_ms" => now})

      case Store.put(Store.handle(instance), @prefix <> id, Jason.encode!(updated), {:if_match, etag}) do
        {:ok, _} ->
          event =
            case {state, op["state"]} do
              {"paused", _} -> :paused
              {"running", "awaiting_confirmation"} -> :continued
              {"running", _} -> :resumed
              {"cancelled", _} -> :cancelled
            end

          emit(instance, op, event)
          {:ok, updated}

        {:error, :precondition_failed} when attempt < attempts ->
          control(instance, id, state, from, attempt + 1)

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :invalid_state}
      {:error, _} = error -> error
    end
  end

  # Leaving `halted` or `awaiting_confirmation` clears the guard window and
  # accepts the canary; a plain pause changes nothing else.
  defp reopen(%{"state" => from} = op, "running") when from in ["halted", "awaiting_confirmation"] do
    op
    |> Map.merge(%{"recent" => [], "halt_reason" => nil})
    |> Map.update("canary", nil, &(&1 && Map.merge(&1, %{"passed" => true, "until_ms" => nil})))
    |> Map.update("guard", nil, &(&1 && Map.merge(&1, %{"halted" => false, "failures" => 0})))
  end

  defp reopen(op, _state), do: op

  defp emit(instance, op, event, extra \\ %{}) do
    :telemetry.execute(
      [:atanor, :sweep, event],
      %{count: 1},
      Map.merge(
        %{
          instance: instance,
          operation: op["id"],
          selector: op["selector"]["kind"],
          driver: op["driver"],
          node: node()
        },
        extra
      )
    )
  end

  @doc """
  Counts the outcomes of a sample of this operation's per-cell markers. The
  sample starts at the beginning of the selector and reads at most `sample`
  cells; those cells are woken.

  With `cells: [cell_id]` it reads those cells (at most `sample`) instead, and
  with `at: :latest` it reads them through `Alambique.Query`, which does not
  wake a cell. The counts have the same shape; a cell that could not be read
  counts in `errors`.
  """
  def sample_outcomes(instance, id, sample \\ 100, opts \\ []) do
    with {:ok, op, _etag} <- get(instance, id) do
      config = Registry.config(instance)
      cells = Keyword.get(opts, :cells) || chunk_cells(instance, %{op | "cursor" => nil}, sample)
      cells = Enum.take(cells, sample)

      results =
        if Keyword.get(opts, :at) == :latest,
          do: query_markers(config, cells, id),
          else: wake_markers(instance, config, cells, id)

      counts = Enum.frequencies(results)

      %{
        sampled: length(results),
        done: Map.get(counts, :done, 0),
        failed: Map.get(counts, :failed, 0),
        pending: Map.get(counts, :pending, 0),
        missing: Map.get(counts, :missing, 0),
        errors: Map.get(counts, {:error, :cell}, 0)
      }
    end
  end

  @marker_sql "SELECT state FROM _atanor_jobs WHERE operation_id = ? LIMIT 1"

  defp wake_markers(instance, config, cells, id) do
    Task.Supervisor.async_stream_nolink(Atanor.Tasks.name(instance), cells, &marker(instance, &1, id),
      max_concurrency: config.sweeps.concurrency,
      timeout: config.sweeps.cell_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :cell}
    end)
  end

  defp marker(instance, cell, id) do
    case Cell.query(instance, cell, @marker_sql, [id]) do
      {:ok, %{rows: rows}} -> outcome(rows)
      {:error, _} -> {:error, :cell}
    end
  end

  # Cells are cell ids; a replica read never wakes them.
  defp query_markers(config, cells, id) do
    %{rows: rows, errors: errors} =
      Alambique.Query.all(config.alambique, cells, @marker_sql, [id],
        concurrency: config.sweeps.concurrency,
        timeout_ms: config.sweeps.cell_timeout_ms
      )

    found = MapSet.new(rows, & &1.cell)
    failed = MapSet.new(errors, &elem(&1, 0))
    missing = Enum.reject(cells, &(&1 in found or &1 in failed))

    Enum.map(rows, &outcome([&1.values])) ++
      List.duplicate({:error, :cell}, length(errors)) ++ List.duplicate(:missing, length(missing))
  end

  defp outcome([["done"]]), do: :done
  defp outcome([["dead"]]), do: :failed
  defp outcome([[_]]), do: :pending
  defp outcome([]), do: :missing

  # -- driver -----------------------------------------------------------------

  @doc false
  # Driver entry point. Returns `:again`, `{:wait, ms}`, `:retry`, `:done`,
  # `:stop` or `{:error, reason}` and updates the record with each page's
  # cursor and counters.
  def drive_page(instance, id, lease_id) do
    config = Registry.config(instance)
    now = System.os_time(:millisecond)

    with {:ok, op, etag} <- get(instance, id),
         {:ok, op, etag} <- claim_or_renew(instance, op, etag, id, lease_id, config, now),
         true <- op["state"] == "running" do
      case gate(instance, op, etag, lease_id, config, now) do
        {:proceed, op, etag} -> drive_cells(instance, op, etag, lease_id, config, now)
        other -> other
      end
    else
      {:error, :conflict} -> :stop
      {:error, _} = error -> error
      false -> :stop
      _ -> :stop
    end
  end

  defp drive_cells(instance, op, etag, lease_id, config, now) do
    id = op["id"]

    case next_cells(instance, op) do
      {:ok, %{cells: [], next: nil}} ->
        finish(instance, op, etag, "done", lease_id, now)

      {:ok, %{cells: cells, next: next}} ->
        {cells, next} = canary_limit(op, cells, next)
        {page, error} = dispatch_page(instance, op, cells, config)

        if error do
          retry_page(instance, op, etag, id, lease_id, config, now, error)
        else
          cursor = next || last_cursor(cells, op)
          counters = merge_counters(op["counters"], page)
          state = if next == nil, do: "done", else: "running"
          {state, canary} = canary_after(op, length(cells), state, now)

          changes = %{
            "cursor" => cursor,
            "counters" => counters,
            "state" => state,
            "canary" => canary,
            "recent" => recent(op, cells),
            "undo" => count_positions(op["undo"], page["positions"]),
            "last_error" => nil,
            "updated_at_ms" => now,
            "driver" => if(state == "running", do: op["driver"]),
            "lease_id" => if(state == "running", do: op["lease_id"]),
            "lease_until_ms" => if(state == "running", do: now + config.sweeps.lease_ttl_ms, else: 0)
          }

          case checkpoint(instance, id, etag, Map.merge(op, changes), lease_id) do
            {:ok, _updated, _etag} ->
              measurements = Map.new(counters, fn {key, value} -> {String.to_atom(key), value} end)

              :telemetry.execute([:atanor, :sweep, :page], measurements, %{
                instance: instance,
                operation: id,
                cursor: cursor,
                node: node()
              })

              case state do
                "done" ->
                  emit(instance, op, :done)
                  :done

                "awaiting_confirmation" ->
                  emit(instance, op, :awaiting_confirmation)
                  :stop

                "running" ->
                  :again
              end

            {:error, :conflict} ->
              lease_lost(instance, id)

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        finish(instance, Map.put(op, "last_error", inspect(reason)), etag, "failed", lease_id, now)
    end
  end

  defp lease_lost(instance, id) do
    :telemetry.execute([:atanor, :sweep, :lease_lost], %{count: 1}, %{instance: instance, operation: id, node: node()})
    :stop
  end

  # -- canary and guard ---------------------------------------------------------

  defp guard_options!(attrs, config) do
    options =
      for key <- @guard_options, into: %{} do
        name = Atom.to_string(key)
        {key, Map.get(attrs, key, Map.get(attrs, name, config.sweeps[key]))}
      end

    case check_options(options) do
      :ok -> options
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc false
  # The one validation of the canary and guard options, for the instance's
  # `sweeps:` defaults and for an operation. Returns `:ok` or `{:error, message}`.
  def check_options(options) do
    invalid = for {key, value} <- options, not option?(key, value), do: key

    cond do
      invalid != [] ->
        {:error, "invalid sweep option(s): #{Enum.join(invalid, ", ")}"}

      options.canary_timeout_ms < options.canary_window_ms ->
        {:error, "canary_timeout_ms must not be less than canary_window_ms"}

      options.guard_min_cells > options.guard_window_cells ->
        {:error, "guard_min_cells must not exceed guard_window_cells"}

      true ->
        :ok
    end
  end

  defp option?(:canary_size, value), do: is_integer(value) and value >= 0
  defp option?(:canary_gate, value), do: value in ["auto", "pause"]
  defp option?(:guard_error_rate, value), do: is_number(value) and value > 0 and value <= 1
  defp option?(_key, value), do: is_integer(value) and value > 0

  defp canary_record(o) do
    %{
      "size" => o.canary_size,
      "gate" => o.canary_gate,
      "window_ms" => o.canary_window_ms,
      "timeout_ms" => o.canary_timeout_ms,
      "until_ms" => nil,
      "passed" => o.canary_size == 0,
      "dispatched" => 0,
      "started_at_ms" => nil
    }
  end

  defp guard_record(o) do
    %{
      "window" => o.guard_window_cells,
      "error_rate" => o.guard_error_rate,
      "min_cells" => o.guard_min_cells,
      "poll_ms" => o.guard_poll_ms,
      "attempts" => o.guard_attempts,
      "halted" => false,
      "failures" => 0,
      "last_at_ms" => 0
    }
  end

  # Cells still allowed before the canary is complete, or nil when the canary
  # is not dispatching.
  defp canary_remaining(%{"canary" => %{"passed" => false, "until_ms" => nil} = canary}),
    do: max(canary["size"] - canary["dispatched"], 0)

  defp canary_remaining(_op), do: nil

  # A canary smaller than the page ends the page early: the cursor moves to the
  # last canary cell, so the rest of the page is listed again.
  defp canary_limit(op, cells, next) do
    case canary_remaining(op) do
      remaining when is_integer(remaining) and remaining < length(cells) ->
        cells = Enum.take(cells, remaining)
        {cells, last_cursor(cells, op)}

      _ ->
        {cells, next}
    end
  end

  # Starts the canary window or the confirmation pause once the canary is out.
  defp canary_after(%{"canary" => %{"passed" => false, "until_ms" => nil} = canary}, count, "running", now) do
    dispatched = canary["dispatched"] + count
    canary = %{canary | "dispatched" => dispatched}

    cond do
      dispatched < canary["size"] -> {"running", canary}
      canary["gate"] == "pause" -> {"awaiting_confirmation", canary}
      true -> {"running", %{canary | "until_ms" => now + canary["window_ms"], "started_at_ms" => now}}
    end
  end

  defp canary_after(op, _count, state, _now), do: {state, op["canary"]}

  defp recent(%{"guard" => %{"window" => window}} = op, cells) do
    ids = for {ns, key} <- cells, do: ns <> "." <> key
    Enum.take(op["recent"] ++ ids, -window)
  end

  defp recent(op, _cells), do: op["recent"]

  # Runs before a page: the canary wait, then the polled error-rate guard.
  # Records without a guard (written by an earlier version) are not guarded.
  defp gate(instance, %{"canary" => %{"until_ms" => until_ms}} = op, etag, lease_id, config, now)
       when is_integer(until_ms),
       do: canary_check(instance, op, etag, lease_id, config, now)

  defp gate(
         instance,
         %{"guard" => %{"poll_ms" => poll_ms, "last_at_ms" => last}, "recent" => [_ | _]} = op,
         etag,
         lease_id,
         config,
         now
       )
       when now - last >= poll_ms do
    case sample_guard(instance, op, now) do
      {:ok, op, counts} ->
        if tripped?(op, counts, op["guard"]["min_cells"]),
          do: halt(instance, op, etag, lease_id, now, "error_rate"),
          else: {:proceed, op, etag}

      {:error, op} ->
        sample_failed(instance, op, etag, lease_id, config, now)
    end
  end

  defp gate(_instance, op, etag, _lease_id, _config, _now), do: {:proceed, op, etag}

  defp canary_check(instance, op, etag, lease_id, config, now) do
    canary = op["canary"]

    if now < canary["until_ms"] do
      {:wait, canary["until_ms"] - now}
    else
      case sample_guard(instance, op, now) do
        {:ok, op, counts} ->
          cond do
            tripped?(op, counts, min(op["guard"]["min_cells"], canary["dispatched"])) ->
              halt(instance, op, etag, lease_id, now, "error_rate")

            counts.pending > 0 and now < canary["started_at_ms"] + canary["timeout_ms"] ->
              {:wait, op["guard"]["poll_ms"]}

            counts.pending > 0 ->
              halt(instance, op, etag, lease_id, now, "canary_timeout")

            true ->
              emit(instance, op, :canary_passed)
              {:proceed, put_in(op, ["canary", "passed"], true) |> put_in(["canary", "until_ms"], nil), etag}
          end

        {:error, op} ->
          sample_failed(instance, op, etag, lease_id, config, now)
      end
    end
  end

  # One read of the job outcomes of the recent cells, without waking them.
  defp sample_guard(instance, op, now) do
    guard = op["guard"]
    counts = sample_outcomes(instance, op["id"], guard["window"], cells: op["recent"], at: :latest)

    if counts.errors > 0 do
      {:error, put_in(op, ["guard", "failures"], guard["failures"] + 1)}
    else
      rate = if counts.done + counts.failed == 0, do: 0.0, else: counts.failed / (counts.done + counts.failed)

      guard =
        Map.merge(guard, %{
          "failures" => 0,
          "last_at_ms" => now,
          "samples" => counts.sampled,
          "done" => counts.done,
          "failed" => counts.failed,
          "rate" => Float.round(rate, 3)
        })

      {:ok, %{op | "guard" => guard}, counts}
    end
  end

  defp tripped?(op, counts, min_cells) do
    decided = counts.done + counts.failed
    decided > 0 and decided >= min_cells and counts.failed / decided > op["guard"]["error_rate"]
  end

  # A failed sample is retried; the operation halts only after `attempts` in a row.
  defp sample_failed(instance, op, etag, lease_id, config, now) do
    if op["guard"]["failures"] >= op["guard"]["attempts"] do
      halt(instance, op, etag, lease_id, now, "guard_unavailable")
    else
      retry_page(instance, op, etag, op["id"], lease_id, config, now, :guard_sample)
    end
  end

  defp halt(instance, op, etag, lease_id, now, reason) do
    op = op |> put_in(["guard", "halted"], true) |> Map.put("halt_reason", reason)
    finish(instance, op, etag, "halted", lease_id, now)
  end

  # A cell that is unavailable while its owner is being taken over is not a
  # failed operation: keep the cursor and retry the page. The per-cell markers
  # make the cells already dispatched in this page harmless to repeat.
  defp retry_page(instance, op, etag, id, lease_id, config, now, error) do
    updated =
      Map.merge(op, %{
        "last_error" => inspect(error),
        "lease_until_ms" => now + config.sweeps.lease_ttl_ms,
        "updated_at_ms" => now
      })

    case checkpoint(instance, id, etag, updated, lease_id) do
      {:ok, _updated, _etag} ->
        :retry

      {:error, :conflict} ->
        :stop

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_or_renew(instance, op, etag, id, lease_id, config, now) do
    cond do
      op["driver"] == to_string(node()) and op["lease_id"] == lease_id and op["lease_until_ms"] > now ->
        {:ok, op, etag}

      op["driver"] == to_string(node()) and op["lease_id"] == lease_id ->
        renew(instance, op, etag, id, lease_id, now + config.sweeps.lease_ttl_ms, now)

      op["state"] != "running" ->
        {:error, :conflict}

      op["lease_until_ms"] > now and op["driver"] != to_string(node()) ->
        {:error, :conflict}

      true ->
        updated =
          Map.merge(op, %{
            "driver" => to_string(node()),
            "lease_id" => lease_id,
            "lease_until_ms" => now + config.sweeps.lease_ttl_ms,
            "updated_at_ms" => now
          })

        case Store.put(Store.handle(instance), @prefix <> id, Jason.encode!(updated), {:if_match, etag}) do
          {:ok, new_etag} -> {:ok, updated, new_etag}
          {:error, :precondition_failed} -> {:error, :conflict}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp renew(instance, op, etag, id, _lease_id, lease_until, now) do
    updated = Map.merge(op, %{"lease_until_ms" => lease_until, "updated_at_ms" => now})

    case Store.put(Store.handle(instance), @prefix <> id, Jason.encode!(updated), {:if_match, etag}) do
      {:ok, new_etag} -> {:ok, updated, new_etag}
      {:error, :precondition_failed} -> {:error, :conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkpoint(instance, id, etag, updated, _lease_id) do
    case Store.put(Store.handle(instance), @prefix <> id, Jason.encode!(updated), {:if_match, etag}) do
      {:ok, new_etag} -> {:ok, updated, new_etag}
      {:error, :precondition_failed} -> {:error, :conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish(instance, op, etag, state, lease_id, now, counters \\ nil) do
    updated =
      Map.merge(op, %{
        "state" => state,
        "driver" => nil,
        "lease_id" => nil,
        "lease_until_ms" => 0,
        "updated_at_ms" => now,
        "counters" => counters || op["counters"]
      })

    case checkpoint(instance, op["id"], etag, updated, lease_id) do
      {:ok, _updated, _etag} ->
        case state do
          "halted" -> emit(instance, op, :halted, %{reason: op["halt_reason"]})
          "done" -> emit(instance, op, :done)
          "failed" -> emit(instance, op, :failed)
        end

        if state == "done", do: :done, else: :stop

      {:error, :conflict} ->
        :stop

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Releases a driver's lease without changing the operation state.
  def release(instance, id, lease_id) do
    with {:ok, op, etag} <- get(instance, id),
         true <- op["lease_id"] == lease_id do
      updated = Map.merge(op, %{"driver" => nil, "lease_id" => nil, "lease_until_ms" => 0})
      _ = Store.put(Store.handle(instance), @prefix <> id, Jason.encode!(updated), {:if_match, etag})
      :ok
    else
      _ -> :ok
    end
  end

  defp dispatch_page(instance, op, cells, config) do
    chunks = Enum.chunk_every(cells, op["concurrency"])
    rate = op["rate_per_s"]
    interval = max(div(1_000, rate), 1)

    start_at = System.monotonic_time(:millisecond)

    {counters, _next_at, error} =
      Enum.reduce_while(
        chunks,
        {%{"dispatched" => 0, "skipped" => 0, "failed" => 0, "jobs_failed" => 0, "positions" => 0}, start_at, nil},
        fn chunk, {counters, next_at, _} ->
          {tasks, next_at} =
            Enum.map_reduce(chunk, next_at, fn cell, at ->
              now = System.monotonic_time(:millisecond)
              if at > now, do: Process.sleep(at - now)
              started = max(now, at)

              task =
                Task.Supervisor.async_nolink(Atanor.Tasks.name(instance), fn ->
                  dispatch_cell(instance, op, cell, config)
                end)

              {task, started + interval}
            end)

          results = Task.yield_many(tasks, config.sweeps.cell_timeout_ms)

          counters =
            Enum.reduce(results, counters, fn {task, result}, acc ->
              outcome =
                case result do
                  {:ok, {:ok, {kind, positioned?}}} -> {kind, positioned?}
                  {:ok, {:error, reason}} -> {:failed, reason}
                  nil -> Task.shutdown(task, :brutal_kill) && {:failed, :timeout}
                  {:exit, reason} -> {:failed, reason}
                end

              case outcome do
                {:enqueued, positioned?} -> acc |> Map.update!("dispatched", &(&1 + 1)) |> add_position(positioned?)
                {:skipped, positioned?} -> acc |> Map.update!("skipped", &(&1 + 1)) |> add_position(positioned?)
                {:failed, reason} -> Map.put(acc, "failed", acc["failed"] + 1) |> Map.put("last_error", reason)
              end
            end)

          if counters["last_error"],
            do: {:halt, {Map.delete(counters, "last_error"), next_at, counters["last_error"]}},
            else: {:cont, {counters, next_at, nil}}
        end
      )

    {counters, error}
  end

  defp add_position(counters, true), do: Map.update!(counters, "positions", &(&1 + 1))
  defp add_position(counters, false), do: counters

  defp dispatch_cell(instance, op, cell, config) do
    action = op["action"]
    attempts = config.sweeps.cell_attempts

    result =
      Enum.reduce_while(1..attempts, {:error, :cell}, fn attempt, _ ->
        result = do_dispatch(instance, op, cell, action)

        case result do
          {:ok, _} ->
            {:halt, result}

          {:error, reason} when attempt < attempts ->
            Process.sleep(config.sweeps.retry_ms)
            {:cont, {:error, reason}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    result
  end

  defp do_dispatch(instance, op, cell, action) do
    spec = %{
      kind: action["kind"],
      payload: Base.decode64!(action["payload_base64"] || ""),
      scheduled_at_ms:
        if(action["mode"] == "run",
          do: Atanor.Alarms.now(Registry.config(instance)),
          else: action["scheduled_at_ms"]
        ),
      max_attempts: action["max_attempts"],
      unique_key: action["unique_key"],
      unique_period: action["unique_period"] || :until_done,
      idempotency_key: action["idempotency_key"],
      operation_id: op["id"]
    }

    undo? = get_in(op, ["undo", "enabled"]) == true

    case Cell.transaction(
           instance,
           cell,
           fn tx ->
             Schema.ensure!(tx, if(undo?, do: [:undo], else: []))
             enqueue_with_position(tx, instance, op, cell, spec, undo?)
           end,
           idempotent: true,
           isolated: undo?
         ) do
      {:ok, {{:ok, {:duplicate, _id}}, positioned?}} ->
        {:ok, {:skipped, positioned?}}

      {:ok, {{:ok, _id}, positioned?}} ->
        if action["mode"] == "run" do
          _ = Dispatch.internal(instance, cell, {:jobs, Atanor.Alarms.now(Registry.config(instance))})
        end

        {:ok, {:enqueued, positioned?}}

      {:ok, {{:error, reason}, _positioned}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # The position row shares the job's transaction: a failed insert rolls both
  # back. A replay finds the operation marker (`:duplicate`) and adds no row;
  # whether the cell holds one from the first run is reported for the count.
  defp enqueue_with_position(tx, instance, op, cell, spec, undo?) do
    result = Jobs.enqueue(tx, instance, op["action"]["worker"], cell, spec)

    positioned? =
      case {undo?, result} do
        {false, _} ->
          false

        {true, {:ok, {:duplicate, _id}}} ->
          Schema.undo_recorded?(tx, op["id"])

        {true, {:ok, id}} ->
          Schema.record_undo!(tx, op["id"], id, Atanor.Alarms.now(Registry.config(instance)))
          true
      end

    {result, positioned?}
  end

  # -- selectors ---------------------------------------------------------------

  @doc false
  def next_cells(instance, op) do
    selector = op["selector"]
    cursor = op["cursor"]
    limit = op["page_size"]

    case selector["kind"] do
      "namespace" ->
        list_cells(instance, selector["namespace"] <> ".", cursor, limit, selector["namespace"])

      "prefix" ->
        list_cells(instance, selector["prefix"], cursor, limit, nil)

      "index" ->
        index_cells(instance, selector, cursor, limit)

      _ ->
        {:error, {:unknown_selector, selector["kind"]}}
    end
  end

  defp list_cells(instance, prefix, cursor, limit, ns) do
    case Alambique.list_cells(Registry.config(instance).alambique, prefix: prefix, after: cursor, limit: limit) do
      {:ok, %{cells: ids, next: next}} ->
        cells =
          for id <- ids,
              {:ok, {namespace, key}} <- [Cell.parse(id)],
              ns == nil or namespace == ns,
              do: {namespace, key}

        {:ok, %{cells: cells, next: next}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp index_cells(instance, selector, cursor, limit) do
    cell = {selector["cell"]["namespace"], selector["cell"]["key"]}
    sql = selector["sql"]
    ns = selector["namespace"]

    case Cell.query(instance, cell, sql, [cursor || "", limit]) do
      {:ok, %{rows: rows}} ->
        keys = for [key] <- rows, is_binary(key), do: key
        next = if length(keys) == limit, do: List.last(keys), else: nil
        {:ok, %{cells: for(key <- keys, do: {ns, key}), next: next}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chunk_cells(instance, op, sample) do
    instance
    |> pages(%{op | "cursor" => nil})
    |> Stream.flat_map(fn
      {:ok, cells} -> cells
      {:error, _reason} -> []
    end)
    |> Enum.take(sample)
  end

  @doc false
  # Every page of the operation's selector from its cursor: `{:ok, cells}`, then
  # `{:error, reason}` and the end if a page cannot be listed.
  def pages(instance, op) do
    Stream.resource(
      fn -> op end,
      fn
        :done ->
          {:halt, :done}

        current ->
          case next_cells(instance, current) do
            {:ok, %{cells: [], next: nil}} ->
              {:halt, :done}

            {:ok, %{cells: cells, next: next}} ->
              {[{:ok, cells}], %{current | "cursor" => next || last_cursor(cells, current)}}

            {:error, reason} ->
              {[{:error, reason}], :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp last_cursor(cells, op) do
    case {op["selector"]["kind"], List.last(cells)} do
      {_, nil} -> op["cursor"]
      {"index", {_ns, key}} -> key
      {_, {ns, key}} -> ns <> "." <> key
    end
  end

  # Records written before positions existed have no `undo` field.
  defp count_positions(%{"positions" => count} = undo, added), do: %{undo | "positions" => count + added}
  defp count_positions(undo, _added), do: undo

  defp merge_counters(old, new) do
    Map.merge(old, Map.take(new, ["dispatched", "skipped", "failed"]), fn _key, a, b -> a + b end)
  end

  # -- validation --------------------------------------------------------------

  defp selector!(%{"kind" => "namespace", "namespace" => ns}, instance) do
    namespace!(instance, ns)
    %{"kind" => "namespace", "namespace" => ns}
  end

  defp selector!(%{"kind" => "prefix", "prefix" => prefix}, _instance) when is_binary(prefix) and byte_size(prefix) > 0,
    do: %{"kind" => "prefix", "prefix" => prefix}

  defp selector!(
         %{"kind" => "index", "cell" => %{"namespace" => ns, "key" => key}, "namespace" => target, "sql" => sql},
         instance
       )
       when is_binary(key) and is_binary(sql) and byte_size(sql) < 10_000 do
    namespace!(instance, target)
    %{"kind" => "index", "cell" => %{"namespace" => ns, "key" => key}, "namespace" => target, "sql" => sql}
  end

  defp selector!(other, _instance), do: raise(ArgumentError, "invalid selector: #{inspect(other, limit: 10)}")

  defp action!(action, config) when is_map(action) do
    worker = action["worker"] || action[:worker]
    kind = action["kind"] || action[:kind]
    payload = action["payload_base64"] || action[:payload_base64] || ""
    unless is_binary(worker) and worker =~ ~r/\A[a-z0-9_-]+\z/, do: raise(ArgumentError, "invalid action worker")
    unless is_binary(kind) and kind != "" and byte_size(kind) <= 100, do: raise(ArgumentError, "invalid action kind")
    payload = Base.decode64!(payload)
    if byte_size(payload) > config.jobs.max_payload_bytes, do: raise(ArgumentError, "action payload is too large")

    mode = action["mode"] || action[:mode] || "enqueue"
    unless mode in ["enqueue", "run"], do: raise(ArgumentError, "invalid action mode")

    %{
      "mode" => mode,
      "worker" => worker,
      "kind" => kind,
      "payload_base64" => Base.encode64(payload),
      "scheduled_at_ms" => action["scheduled_at_ms"] || action[:scheduled_at_ms],
      "max_attempts" => action["max_attempts"] || action[:max_attempts],
      "unique_key" => action["unique_key"] || action[:unique_key],
      "unique_period" => action["unique_period"] || action[:unique_period],
      "idempotency_key" => action["idempotency_key"] || action[:idempotency_key]
    }
  end

  defp action!(other, _config), do: raise(ArgumentError, "invalid action: #{inspect(other, limit: 10)}")

  defp namespace!(instance, ns) do
    with :ok <- Cell.validate_namespace(ns),
         {:ok, _} <- Registry.namespace(instance, ns) do
      :ok
    else
      _ -> raise ArgumentError, "namespace #{inspect(ns)} is not granted by an active worker"
    end
  end

  # The action's worker runs the job, so its manifest must grant jobs and every namespace the selector reads.
  defp granted!(instance, selector, %{"worker" => worker}) do
    manifest =
      case Registry.deployment(instance, worker) do
        {:ok, %{manifest: manifest}} -> manifest
        :error -> nil
      end

    missing = for ns <- selected_namespaces(selector), manifest == nil or not is_map_key(manifest.cells, ns), do: ns

    if manifest == nil or not manifest.jobs or missing != [] do
      raise ArgumentError,
            "worker #{inspect(worker)} is not granted jobs in namespace #{inspect(List.first(missing) || selector_namespace(selector))}"
    end
  end

  defp selected_namespaces(%{"kind" => "namespace", "namespace" => ns}), do: [ns]

  defp selected_namespaces(%{"kind" => "index", "cell" => %{"namespace" => ns}, "namespace" => target}),
    do: [ns, target]

  defp selected_namespaces(%{"kind" => "prefix", "prefix" => prefix}),
    do: [prefix |> String.split(".", parts: 2) |> hd()]

  defp selector_namespace(selector), do: selector |> selected_namespaces() |> List.last()

  defp undo!(value) when is_boolean(value), do: value
  defp undo!(value), do: raise(ArgumentError, "undo must be a boolean, got: #{inspect(value)}")

  defp positive!(value, _what) when is_integer(value) and value > 0, do: value
  defp positive!(value, what), do: raise(ArgumentError, "#{what} must be a positive integer, got: #{inspect(value)}")

  defp new_id(now) do
    Integer.to_string(now, 36)
    |> String.pad_leading(9, "0")
    |> Kernel.<>(Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
  end
end
