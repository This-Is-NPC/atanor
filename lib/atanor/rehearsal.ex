defmodule Atanor.Rehearsal do
  @moduledoc """
  Migration rehearsal (design §17.3): applies a published package's
  migrations to restored copies of sampled cells, in a temporary directory on
  the node that received the request, and stores a report under
  `rehearsals/<id>` in the metadata store.

  It never wakes, leases, migrates or writes a live cell, and publishes no
  change feed. The options are those of `:rehearsal` in `Atanor`; a request
  may lower `sample_size`, `max_cells` and `timeout_ms`, and sets `seed`,
  `strict_schema` and `integrity_check`.

  A record is `running` until the task writes the final state (`done`,
  `failed` or `cancelled`). A `running` record not updated for `:stale_ms` is
  read as `stale`: its node died. Reports older than `:retention_ms` are
  removed when a rehearsal starts or the list is read.
  """

  require Logger

  alias Atanor.{Alarms, Deployments, Registry, Release, Store}
  alias Atanor.Diagnostics.Breadcrumb
  alias Atanor.Rehearsal.Cell
  alias Atanor.Restore

  @prefix "rehearsals/"
  @request_keys ~w(worker id sample_size max_cells timeout_ms seed strict_schema integrity_check)
  @lowerable ~w(sample_size max_cells timeout_ms)a
  @attempts 5
  @id ~r/\Ah-\d{13}-[0-9a-f]+\z/
  @package_id ~r/\A[0-9a-f]{64}\z/

  @type error ::
          {:invalid, String.t()}
          | :package_not_found
          | :wrong_worker
          | :already_running
          | :not_found
          | :invalid_state
          | {:store, term}

  @doc """
  Starts a rehearsal of package `id` of `worker` and returns its record (state
  `"running"`). `attrs` is the decoded request body.
  """
  @spec start(atom, map) :: {:ok, map} | {:error, error}
  def start(instance, attrs) do
    config = Registry.config(instance)

    with {:ok, options} <- options(attrs, config.rehearsal),
         {:ok, package} <- package(instance, attrs),
         {:ok, keys} <- recent_keys(instance, config),
         :ok <- idle(instance, List.last(keys)),
         record = new_record(config, package, options),
         {:ok, _etag} <- put(instance, record, :if_none_match) do
      {:ok, _} =
        Task.Supervisor.start_child(Atanor.Tasks.name(instance), fn -> task(instance, record, package, options) end)

      {:ok, record}
    end
  end

  @doc "One record, with `stale` for an abandoned `running` one."
  @spec get(atom, String.t()) :: {:ok, map} | {:error, :not_found | {:store, term}}
  def get(instance, id) do
    with {:ok, record, _etag} <- read(instance, id), do: {:ok, present(record, Registry.config(instance))}
  end

  @doc "The newest `limit` records, newest first."
  @spec list(atom, pos_integer) :: {:ok, [map]} | {:error, {:store, term}}
  def list(instance, limit) do
    config = Registry.config(instance)

    with {:ok, keys} <- recent_keys(instance, config) do
      records =
        for key <- keys |> Enum.reverse() |> Enum.take(limit),
            {:ok, record, _etag} <- [read(instance, key_id(key))],
            do: present(record, config)

      {:ok, records}
    end
  end

  @doc """
  Asks a running rehearsal to stop before its next cell. The cells done stay
  in the report. A rehearsal that is not running cannot be cancelled.
  """
  @spec cancel(atom, String.t()) :: {:ok, map} | {:error, error}
  def cancel(instance, id) do
    config = Registry.config(instance)

    update(instance, id, fn record ->
      if effective_state(record, config) == "running",
        do: {:ok, Map.put(record, "cancel_requested", true)},
        else: {:error, :invalid_state}
    end)
    |> case do
      {:ok, record} -> {:ok, present(record, config)}
      error -> error
    end
  end

  # -- request ----------------------------------------------------------------

  defp options(attrs, settings) do
    with :ok <- known_keys(attrs),
         {:ok, lowered} <- lowered(attrs, settings),
         {:ok, strict} <- optional(attrs, "strict_schema", settings.strict_schema, &is_boolean/1, "a boolean"),
         {:ok, check} <- integrity_check(attrs, settings.integrity_check),
         {:ok, seed} <- optional(attrs, "seed", settings.seed || random_seed(), &is_integer/1, "an integer") do
      {:ok,
       Map.merge(
         Map.take(settings, [:max_scan, :page_size, :concurrency]),
         Map.merge(lowered, %{strict_schema: strict, integrity_check: check, seed: seed})
       )}
    end
  end

  defp known_keys(attrs) do
    case Map.keys(attrs) -- @request_keys do
      [] -> :ok
      unknown -> {:error, {:invalid, "unknown fields: #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp lowered(attrs, settings) do
    Enum.reduce_while(@lowerable, {:ok, %{}}, fn key, {:ok, acc} ->
      limit = Map.fetch!(settings, key)

      case Map.get(attrs, Atom.to_string(key), limit) do
        value when is_integer(value) and value in 1..limit//1 -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, {:error, {:invalid, "#{key} must be an integer from 1 to #{limit}"}}}
      end
    end)
  end

  defp integrity_check(attrs, default) do
    case Map.get(attrs, "integrity_check", Atom.to_string(default)) do
      "quick_check" -> {:ok, :quick_check}
      "integrity_check" -> {:ok, :integrity_check}
      _ -> {:error, {:invalid, "integrity_check must be \"quick_check\" or \"integrity_check\""}}
    end
  end

  defp optional(attrs, key, default, valid?, expected) do
    value = Map.get(attrs, key, default)
    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid, "#{key} must be #{expected}"}}
  end

  defp random_seed, do: :rand.uniform(4_294_967_296)

  defp package(instance, %{"worker" => worker, "id" => id}) when is_binary(worker) and is_binary(id) do
    if Regex.match?(@package_id, id), do: fetch_package(instance, worker, id), else: {:error, :package_not_found}
  end

  defp package(_instance, _attrs), do: {:error, {:invalid, "worker and id are required strings"}}

  defp fetch_package(instance, worker, id) do
    case Deployments.fetch_package(instance, id) do
      {:ok, %{manifest: %{name: ^worker}} = package} -> {:ok, package}
      {:ok, _other} -> {:error, :wrong_worker}
      {:error, :not_found} -> {:error, :package_not_found}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  # The newest record decides: a running rehearsal is always newer than the
  # ones before it, because a new one waits for it to end.
  defp idle(_instance, nil), do: :ok

  defp idle(instance, key) do
    case get(instance, key_id(key)) do
      {:ok, %{"state" => "running"}} -> {:error, :already_running}
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp new_record(config, package, options) do
    now = Alarms.now(config)

    %{
      "id" => "h-" <> String.pad_leading(Integer.to_string(now), 13, "0") <> "-" <> random_suffix(),
      "state" => "running",
      "worker" => package.manifest.name,
      "package" => package.id,
      "release" => %{"id" => Release.id(config)},
      "node" => Atom.to_string(node()),
      "started_at_ms" => now,
      "updated_at_ms" => now,
      "finished_at_ms" => nil,
      "cancel_requested" => false,
      "options" => Map.new(options, fn {key, value} -> {Atom.to_string(key), value(value)} end),
      "progress" => %{"done" => 0, "total" => nil},
      "summary" => nil,
      "cells" => [],
      "reason" => nil,
      "error" => nil
    }
  end

  defp value(atom) when is_atom(atom) and atom not in [true, false, nil], do: Atom.to_string(atom)
  defp value(other), do: other

  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  # -- task -------------------------------------------------------------------

  defp task(instance, record, package, options) do
    meta = %{kind: "rehearsal", rehearsal_id: record["id"], worker: record["worker"], package: record["package"]}
    config = Registry.config(instance)
    dir = Path.join(run_root(config), record["id"])

    try do
      Breadcrumb.wrap(instance, meta, fn ->
        File.mkdir_p!(run_root(config))
        Restore.remove_abandoned(run_root(config), config.rehearsal.stale_ms)
        File.mkdir_p!(dir)
        finish(instance, record["id"], rehearse(instance, config, record, package, options, dir))
      end)
    rescue
      exception -> fail(instance, record["id"], Exception.message(exception))
    catch
      kind, reason -> fail(instance, record["id"], inspect({kind, reason}))
    after
      File.rm_rf(dir)
    end
  end

  defp run_root(config), do: config.rehearsal.dir || Path.join(config.data_dir, "rehearsals")

  defp rehearse(instance, config, record, package, options, dir) do
    namespaces = for {ns, [_ | _] = migrations} <- Enum.sort(package.manifest.cells), do: {ns, migrations}

    if namespaces == [] do
      %{state: "done", reason: "nothing_to_rehearse", cells: [], summary: summary([], %{}, %{}, options, namespaces)}
    else
      with {:ok, selected, sampling} <- sample(config, namespaces, options) do
        cells = run_cells(instance, config, record, namespaces, selected, options, dir)
        conclude(cells, sampling, options, namespaces)
      else
        {:error, reason} -> %{state: "failed", cells: [], summary: nil, error: failure("sampling", reason)}
      end
    end
  end

  defp conclude({cancelled?, cells}, sampling, options, namespaces) do
    summary = summary(cells, sampling, schema_groups(cells), options, namespaces)
    inconsistent? = options.strict_schema and not summary["schema_consistent"]

    cond do
      cancelled? ->
        %{state: "cancelled", cells: cells, summary: summary}

      Enum.any?(cells, &(&1["outcome"] == "failed")) ->
        %{state: "failed", cells: cells, summary: summary}

      inconsistent? ->
        %{
          state: "failed",
          cells: cells,
          summary: summary,
          error: failure("schema", "sampled cells end with different schemas")
        }

      true ->
        %{state: "done", cells: cells, summary: summary}
    end
  end

  # -- sampling -----------------------------------------------------------------

  # Reservoir-samples `sample_size` cells of each namespace, listing the schema
  # index page by page (`Alambique.list_cells/2`) in every location.
  defp sample(config, namespaces, options) do
    locations = Alambique.Feed.ctx(config.alambique).locations
    state = %{rand: :rand.seed_s(:exsss, options.seed), total: 0, selected: [], sampling: %{}}

    Enum.reduce_while(namespaces, {:ok, state}, fn {ns, _}, {:ok, state} ->
      want = min(options.sample_size, options.max_cells - state.total)

      case scan_namespace(config, locations, ns, want, options, state.rand) do
        {:ok, picked, info, rand} ->
          {:cont,
           {:ok,
            %{
              state
              | rand: rand,
                total: state.total + length(picked),
                selected: state.selected ++ picked,
                sampling: Map.put(state.sampling, ns, info)
            }}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, state.selected, state.sampling}
      error -> error
    end
  end

  defp scan_namespace(_config, _locations, _ns, 0, _options, rand),
    do: {:ok, [], %{"scanned" => 0, "sampled" => 0, "max_scan_reached" => false}, rand}

  defp scan_namespace(config, locations, ns, want, options, rand) do
    acc = %{rand: rand, want: want, seen: 0, kept: %{}, reached: false}

    result =
      Enum.reduce_while(locations, {:ok, acc}, fn location, {:ok, acc} ->
        case scan_location(config.alambique, location, ns <> ".", options, acc, nil) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          error -> {:halt, error}
        end
      end)

    with {:ok, acc} <- result do
      picked = acc.kept |> Map.values() |> Enum.sort_by(&elem(&1, 0))
      {:ok, picked, %{"scanned" => acc.seen, "sampled" => length(picked), "max_scan_reached" => acc.reached}, acc.rand}
    end
  end

  defp scan_location(_alambique, _location, _prefix, %{max_scan: max} = _options, %{seen: max} = acc, _cursor),
    do: {:ok, %{acc | reached: true}}

  defp scan_location(alambique, location, prefix, options, acc, cursor) do
    limit = min(options.page_size, options.max_scan - acc.seen)

    case Alambique.list_cells(alambique, location: location, prefix: prefix, after: cursor, limit: limit) do
      {:ok, %{cells: ids, next: next}} ->
        acc = Enum.reduce(ids, acc, &keep(&1, location, &2))

        cond do
          next == nil -> {:ok, acc}
          acc.seen >= options.max_scan -> {:ok, %{acc | reached: true}}
          true -> scan_location(alambique, location, prefix, options, acc, next)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Algorithm R: the n-th id replaces a random slot with probability want/n.
  defp keep(id, location, %{seen: seen, want: want, kept: kept} = acc) do
    seen = seen + 1
    item = {id, location}

    cond do
      map_size(kept) < want ->
        %{acc | seen: seen, kept: Map.put(kept, map_size(kept), item)}

      true ->
        {slot, rand} = :rand.uniform_s(seen, acc.rand)
        kept = if slot <= want, do: Map.put(kept, slot - 1, item), else: kept
        %{acc | seen: seen, kept: kept, rand: rand}
    end
  end

  # -- cells ------------------------------------------------------------------------

  defp run_cells(instance, config, record, namespaces, selected, options, dir) do
    migrations = Map.new(namespaces)
    clock = Alambique.Feed.ctx(config.alambique).clock
    total = length(selected)
    tasks = Atanor.Tasks.name(instance)

    stream =
      selected
      |> Enum.with_index()
      |> then(
        &Task.Supervisor.async_stream_nolink(
          tasks,
          &1,
          fn {{id, location}, index} ->
            ns = id |> String.split(".", parts: 2) |> hd()

            report =
              Cell.run(%{location: location, clock: clock}, id, migrations[ns], Path.join(dir, "#{index}.db"), options)

            Map.put(report, "frozen", frozen(config, id))
          end,
          max_concurrency: config.rehearsal.concurrency,
          timeout: :infinity,
          ordered: false
        )
      )

    checkpoint(instance, record["id"], 0, total)

    {cancelled?, cells} =
      Enum.reduce_while(stream, {false, []}, fn result, {_, done} ->
        done = [cell_report(result) | done]

        case checkpoint(instance, record["id"], length(done), total) do
          :cancel -> {:halt, {true, done}}
          :continue -> {:cont, {false, done}}
        end
      end)

    {cancelled?, Enum.sort_by(cells, & &1["cell"])}
  end

  defp frozen(config, id) do
    case Alambique.frozen?(config.alambique, id) do
      {:ok, frozen?} -> frozen?
      {:error, _} -> nil
    end
  end

  defp cell_report({:ok, report}), do: report

  defp cell_report({:exit, reason}),
    do: %{"cell" => nil, "outcome" => "failed", "error" => failure("task", {:exit, reason})}

  # Records progress and the heartbeat, and reads the cancel request.
  defp checkpoint(instance, id, done, total) do
    config = Registry.config(instance)

    result =
      update(instance, id, fn record ->
        {:ok, %{record | "updated_at_ms" => Alarms.now(config), "progress" => %{"done" => done, "total" => total}}}
      end)

    case result do
      {:ok, %{"cancel_requested" => true}} ->
        :cancel

      {:ok, _} ->
        :continue

      {:error, reason} ->
        Logger.warning("atanor: rehearsal #{id} could not update its record: #{inspect(reason)}")
        :continue
    end
  end

  # -- report -------------------------------------------------------------------------

  defp schema_groups(cells) do
    for %{"schema_hash" => hash, "namespace" => ns} <- cells, reduce: %{} do
      acc -> update_in(acc, [Access.key(ns, %{}), Access.key(hash, 0)], &(&1 + 1))
    end
  end

  defp summary(cells, sampling, groups, options, namespaces) do
    outcomes = Enum.frequencies_by(cells, & &1["outcome"])

    versions =
      for {ns, migrations} <- namespaces, into: %{} do
        from = for %{"namespace" => ^ns, "from_version" => version} <- cells, do: version

        {ns,
         %{
           "from_min" => Enum.min(from, fn -> nil end),
           "from_max" => Enum.max(from, fn -> nil end),
           "to" => migrations |> List.last() |> elem(0)
         }}
      end

    %{
      "namespaces" => length(namespaces),
      "scanned" => sampling |> Map.values() |> Enum.sum_by(& &1["scanned"]),
      "sampled" => length(cells),
      "ok" => Map.get(outcomes, "migrated", 0) + Map.get(outcomes, "nothing_pending", 0),
      "failed" => Map.get(outcomes, "failed", 0),
      "skipped" => Map.get(outcomes, "empty", 0),
      "schema_consistent" => Enum.all?(groups, fn {_ns, hashes} -> map_size(hashes) == 1 end),
      "schema_groups" => groups,
      "max_duration_ms" => cells |> Enum.map(&(&1["duration_ms"] || 0)) |> Enum.max(fn -> 0 end),
      "versions" => versions,
      "sampling" => sampling,
      "max_cells_reached" => length(cells) >= options.max_cells
    }
  end

  defp failure(stage, reason) do
    %{"stage" => stage, "version" => nil, "message" => if(is_binary(reason), do: reason, else: inspect(reason))}
  end

  defp finish(instance, id, result) do
    config = Registry.config(instance)

    fields = %{
      "state" => result.state,
      "cells" => result.cells,
      "summary" => result.summary,
      "reason" => result[:reason],
      "error" => result[:error],
      "finished_at_ms" => Alarms.now(config)
    }

    case update(instance, id, fn record ->
           {:ok, Map.merge(record, fields) |> Map.put("updated_at_ms", fields["finished_at_ms"])}
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("atanor: rehearsal #{id} could not store its report: #{inspect(reason)}")
    end
  end

  defp fail(instance, id, message) do
    Logger.warning("atanor: rehearsal #{id} failed: #{message}")
    finish(instance, id, %{state: "failed", cells: [], summary: nil, error: failure("task", message)})
  end

  # -- store --------------------------------------------------------------------------

  defp present(record, config), do: %{record | "state" => effective_state(record, config)}

  defp effective_state(%{"state" => "running", "updated_at_ms" => updated}, config) do
    if Alarms.now(config) - updated > config.rehearsal.stale_ms, do: "stale", else: "running"
  end

  defp effective_state(%{"state" => state}, _config), do: state

  defp key_id(@prefix <> id), do: id

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
    case Store.put(instance, @prefix <> record["id"], Jason.encode!(record), condition) do
      {:ok, etag} -> {:ok, etag}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  # Compare-and-swap on the record; `fun` gets the stored record.
  defp update(instance, id, fun, attempts \\ @attempts) do
    with {:ok, record, etag} <- read(instance, id),
         {:ok, updated} <- fun.(record) do
      case Store.put(instance, @prefix <> id, Jason.encode!(updated), {:if_match, etag}) do
        {:ok, _etag} -> {:ok, updated}
        {:error, :precondition_failed} when attempts > 1 -> update(instance, id, fun, attempts - 1)
        {:error, reason} -> {:error, {:store, reason}}
      end
    end
  end

  # Ascending keys of the stored reports, after removing the expired ones. The
  # id starts with the creation time, so expiry needs no read.
  defp recent_keys(instance, config) do
    cutoff = Alarms.now(config) - config.rehearsal.retention_ms

    with {:ok, keys} <- all_keys(instance, nil, []) do
      {expired, kept} =
        keys |> Enum.filter(&String.starts_with?(&1, @prefix <> "h-")) |> Enum.split_with(&expired?(&1, cutoff))

      Enum.each(expired, &Store.delete(instance, &1))
      {:ok, kept}
    end
  end

  defp all_keys(instance, after_key, acc) do
    case Store.list(instance, @prefix, after_key, Registry.config(instance).metadata.page_size) do
      {:ok, keys, nil} -> {:ok, acc ++ keys}
      {:ok, keys, next} -> all_keys(instance, next, acc ++ keys)
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp expired?(@prefix <> "h-" <> <<ms::binary-size(13), _::binary>>, cutoff) do
    match?({created, ""} when created < cutoff, Integer.parse(ms))
  end

  defp expired?(_malformed_id, _cutoff), do: false
end
