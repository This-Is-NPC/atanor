defmodule Atanor.Diagnostics do
  @moduledoc """
  Crash breadcrumbs and reports (design §17.2).

  A unit of durable work (a job attempt, an alarm, a sweep driver page, a
  migration task, a deployment activation or a WebSocket connection) opens a
  file under `data_dir/diagnostics/units/` with a JSON body naming its worker,
  deployment, cell, job, operation and release. The file's first byte is `1`
  while the unit runs; the tracker removes it when the process ends. A VM
  crash leaves the byte at `1` and a report is written at the next start,
  enriched with `Alambique.crashes/2` and `Alambique.frozen?/2`.

  Reports live at `<prefix>/crashes/<node>/<id>`; a store failure keeps a
  local pending copy and retries. `GET /crashes` lists them.
  """

  use GenServer

  require Logger

  alias Atanor.{Config, Release, Store}

  @units "units"
  @pending "pending"

  @doc false
  def child_spec(%Config{} = config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, restart: :permanent}
  end

  @doc false
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config, name: name(config.name))

  @doc "The process name of the instance's diagnostics."
  def name(instance), do: Module.concat(instance, Diagnostics)

  @doc false
  # Called by `Atanor.Diagnostics.Breadcrumb` when a unit file is created.
  def track(instance, pid, path) do
    if whereis(instance), do: GenServer.cast(name(instance), {:track, pid, path})
    :ok
  end

  @doc false
  def untrack(instance, path) do
    if whereis(instance), do: GenServer.cast(name(instance), {:untrack, path})
    :ok
  end

  defp whereis(instance) do
    is_pid(Process.whereis(name(instance)))
  end

  @doc """
  One page of crash reports, newest first in the page. Options: `:node`,
  `:after` (a key) and `:limit` (default 100).
  """
  @spec list(atom, keyword) :: {:ok, %{crashes: [map], next: String.t() | nil}} | {:error, term}
  def list(instance, opts \\ []) do
    node = opts[:node]
    limit = opts[:limit] || 100
    prefix = if node, do: "crashes/#{node}/", else: "crashes/"
    store = Store.handle(instance)

    with {:ok, keys, next} <- Store.list(store, prefix, opts[:after], limit) do
      reports =
        for key <- keys,
            {:ok, body, _etag, _meta} <- [Store.get(store, key)],
            {:ok, report} <- [decode(body)],
            do: report

      {:ok, %{crashes: Enum.sort_by(reports, &(&1["detected_at_ms"] || 0), :desc), next: next}}
    end
  end

  @doc "One crash report by node and id."
  @spec get(atom, String.t(), String.t()) :: {:ok, map} | {:error, :not_found | term}
  def get(instance, node, id) do
    case Store.get(Store.handle(instance), report_key(node, id)) do
      {:ok, body, _etag, _meta} ->
        case decode(body) do
          {:ok, report} -> {:ok, report}
          :error -> {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  @doc "The store key of a crash report."
  def report_key(node, id), do: "crashes/#{node}/#{id}"

  # -- server -----------------------------------------------------------------

  @impl true
  def init(%Config{} = config) do
    # So that terminate/2 runs when the supervisor stops the node.
    Process.flag(:trap_exit, true)
    units = Path.join(config.diagnostics.dir, @units)
    pending = Path.join(config.diagnostics.dir, @pending)
    File.mkdir_p(units)
    File.mkdir_p(pending)

    {files, truncated} =
      if config.diagnostics.enabled, do: take_files(units, config.diagnostics.max_files), else: {[], 0}

    # `tracked` maps path -> ref and `refs` maps ref -> path.
    state = %{
      config: config,
      units: units,
      pending: pending,
      tracked: %{},
      refs: %{},
      files: files,
      truncated: truncated,
      retry: nil,
      cleanup: nil
    }

    if config.diagnostics.enabled do
      Process.send_after(self(), :scan, config.diagnostics.settle_ms)
      {:ok, schedule_cleanup(state)}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:scan, state) do
    state = scan(state)
    state = retry_pending(state)
    {:noreply, state}
  rescue
    exception ->
      Logger.warning("atanor: crash-report scan failed: " <> Exception.format(:error, exception, __STACKTRACE__))
      {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    cleanup(state)
    {:noreply, schedule_cleanup(state)}
  rescue
    exception ->
      Logger.warning("atanor: crash-report cleanup failed: " <> Exception.format(:error, exception, __STACKTRACE__))
      {:noreply, schedule_cleanup(state)}
  end

  def handle_info(:retry, state) do
    {:noreply, retry_pending(%{state | retry: nil})}
  rescue
    exception ->
      Logger.warning("atanor: crash-report retry failed: " <> Exception.format(:error, exception, __STACKTRACE__))
      {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {path, refs} ->
        File.rm(path)
        {:noreply, %{state | tracked: Map.delete(state.tracked, path), refs: refs}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:track, pid, path}, state) do
    ref = Process.monitor(pid)
    {:noreply, %{state | tracked: Map.put(state.tracked, path, ref), refs: Map.put(state.refs, ref, path)}}
  end

  def handle_cast({:untrack, path}, state) do
    case Map.pop(state.tracked, path) do
      {nil, _tracked} ->
        {:noreply, state}

      {ref, tracked} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | tracked: tracked, refs: Map.delete(state.refs, ref)}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.keys(state.tracked), &File.rm/1)
    :ok
  end

  # -- scanning a previous boot ----------------------------------------------

  defp take_files(dir, max) do
    files =
      case File.ls(dir) do
        {:ok, names} -> Enum.sort(Enum.map(names, &Path.join(dir, &1)))
        {:error, _} -> []
      end

    {keep, rest} = Enum.split(files, max)
    Enum.each(rest, &File.rm/1)
    {keep, length(rest)}
  end

  defp scan(state) do
    units = read_units(state.files)
    remove_files(state.files)

    if units == [] do
      state
    else
      report = report(state, units, state.truncated)
      write_report(state, report)
    end
  end

  defp read_units(files) do
    Enum.reduce(files, [], fn path, units ->
      case read_unit(path) do
        {:busy, unit} -> [Map.put(unit, "path", path) | units]
        :idle -> units
        {:error, reason} -> [%{"path" => path, "error" => inspect(reason)} | units]
      end
    end)
  end

  defp read_unit(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, fd} ->
        try do
          case :file.read(fd, 1) do
            {:ok, <<0>>} ->
              :idle

            {:ok, <<1>>} ->
              case :file.read(fd, 64 * 1024) do
                {:ok, body} ->
                  case decode(body) do
                    {:ok, unit} -> {:busy, unit}
                    :error -> {:error, :invalid_body}
                  end

                :eof ->
                  {:error, :empty_body}

                {:error, reason} ->
                  {:error, reason}
              end

            {:ok, other} ->
              {:error, {:invalid_busy_byte, other}}

            :eof ->
              {:error, :empty_file}

            {:error, reason} ->
              {:error, reason}
          end
        after
          File.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_files(files), do: Enum.each(files, &File.rm/1)

  defp report(state, units, truncated) do
    now = System.os_time(:millisecond)
    id = "c-" <> Integer.to_string(now, 36) <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    config = state.config
    {units, dropped} = Enum.split(units, config.diagnostics.max_units)

    %{
      "id" => id,
      "node" => Atom.to_string(node()),
      "detected_at_ms" => now,
      "release" => Release.info(config),
      "units" => Enum.map(units, &enrich(&1, config)),
      "truncated" => truncated + length(dropped)
    }
  end

  defp enrich(unit, config) do
    case unit["cell"] do
      cell when is_binary(cell) ->
        crashes =
          try do
            case Alambique.crashes(config.alambique, cell) do
              {:ok, counter} -> counter
              {:error, reason} -> %{"error" => inspect(reason)}
            end
          catch
            kind, reason -> %{"error" => inspect({kind, reason})}
          end

        frozen =
          try do
            case Alambique.frozen?(config.alambique, cell) do
              {:ok, value} -> value
              {:error, reason} -> %{"error" => inspect(reason)}
            end
          catch
            kind, reason -> %{"error" => inspect({kind, reason})}
          end

        unit |> Map.put("alambique", %{"crashes" => crashes, "frozen" => frozen})

      _ ->
        unit
    end
  end

  defp write_report(state, report) do
    body = Jason.encode!(report)
    path = Path.join(state.pending, report["id"] <> ".json")
    File.write(path, body)

    # A report the store refuses stays in `pending`; `retry_pending/1` runs next and schedules the retry.
    case put_report(state, report, body) do
      :ok -> File.rm(path)
      {:error, reason} -> Logger.warning("atanor: could not store crash report #{report["id"]}: #{inspect(reason)}")
    end

    :telemetry.execute([:atanor, :crash, :detected], %{count: 1}, %{
      instance: state.config.name,
      node: report["node"],
      release: report["release"]["id"],
      id: report["id"],
      units: length(report["units"]),
      truncated: report["truncated"]
    })

    state
  end

  defp put_report(state, report, body) do
    Store.put(
      Store.handle(state.config.name),
      report_key(report["node"], report["id"]),
      body,
      :if_none_match
    )
    |> case do
      {:ok, _etag} -> :ok
      {:error, :precondition_failed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_pending(state) do
    if state.retry, do: Process.cancel_timer(state.retry)

    pending =
      case File.ls(state.pending) do
        {:ok, names} -> Enum.map(names, &Path.join(state.pending, &1))
        {:error, _} -> []
      end

    failed =
      Enum.reduce(pending, false, fn file, failed? ->
        case File.read(file) do
          {:ok, body} ->
            case decode(body) do
              {:ok, report} ->
                case put_report(state, report, body) do
                  :ok ->
                    File.rm(file)
                    failed?

                  {:error, _} ->
                    true
                end

              :error ->
                File.rm(file)
                failed?
            end

          {:error, _} ->
            true
        end
      end)

    if failed, do: schedule_retry(state, state.config.diagnostics.pending_retry_ms), else: state
  end

  defp schedule_retry(state, ms) do
    if state.retry, do: Process.cancel_timer(state.retry)
    %{state | retry: Process.send_after(self(), :retry, ms)}
  end

  # -- retention --------------------------------------------------------------

  defp schedule_cleanup(state) do
    if state.cleanup, do: Process.cancel_timer(state.cleanup)
    %{state | cleanup: Process.send_after(self(), :cleanup, state.config.diagnostics.cleanup_ms)}
  end

  defp cleanup(state) do
    cutoff = System.os_time(:millisecond) - state.config.diagnostics.retention_ms
    cleanup_store(Store.handle(state.config.name), nil, cutoff)
    :ok
  end

  defp cleanup_store(store, after_key, cutoff) do
    case Store.list(store, "crashes/", after_key, 1_000) do
      {:ok, keys, next} ->
        for key <- keys,
            {:ok, body, _etag, _meta} <- [Store.get(store, key)],
            {:ok, report} <- [decode(body)],
            is_integer(report["detected_at_ms"]),
            report["detected_at_ms"] < cutoff do
          Store.delete(store, key)
        end

        if next, do: cleanup_store(store, next, cutoff), else: :ok

      {:error, _} ->
        :ok
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :error
    end
  end
end
