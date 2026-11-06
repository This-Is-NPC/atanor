defmodule Atanor.Feed do
  @moduledoc false
  # Reads the change feed for one namespace and manages the per-instance
  # tailer (design §16).

  alias Atanor.{Change, Feed.Supervisor, Feed.Tailer}

  @type position :: String.t() | nil
  @type from :: position | :now

  @doc """
  The feed position at `:now` and the clock's time in milliseconds, both moved
  back by the Alambique skew margin so a publisher whose clock is behind is
  not skipped.
  """
  @spec now(atom) :: {position, integer}
  def now(instance) do
    config = Atanor.Registry.config(instance)
    ctx = Alambique.Feed.ctx(config.alambique)
    {clock, clock_config} = ctx.clock
    at_ms = max(0, clock.now_ms(clock_config) - Atanor.Config.skew_margin_ms(config))
    {Alambique.Feed.position_at(ctx, at_ms), at_ms}
  end

  @doc """
  Reads a page and keeps the changes of `namespace`. Atanor's own `_atanor_` tables are not in
  the feed (`Atanor.Config` lists them as internal).
  Emits `[:atanor, :feed, :read]` and `[:atanor, :feed, :rejected]` for each object it could not decode.
  """
  @spec read_changes(atom, String.t(), position, pos_integer) ::
          {:ok, [Change.t() | Change.Rewind.t()], position} | {:error, term}
  def read_changes(instance, namespace, position, limit) do
    with {:ok, changes, _rejected, next} <- read_page(instance, namespace, position, limit), do: {:ok, changes, next}
  end

  @doc false
  # `read_changes/4` with the rejected objects of the page, for the tailer to warn about.
  @spec read_page(atom, String.t(), position, pos_integer) ::
          {:ok, [Change.t() | Change.Rewind.t()], [Alambique.Feed.Rejected.t()], position} | {:error, term}
  def read_page(instance, namespace, position, limit) do
    started = System.monotonic_time()

    case read_records(instance, position, limit) do
      {:ok, records, next} ->
        changes = keep(records, namespace)
        rejected = report_rejected(instance, namespace, records)
        emit_read(instance, namespace, :ok, length(records), length(changes), started, length(rejected))
        {:ok, changes, rejected, next}

      {:error, reason} ->
        emit_read(instance, namespace, {:error, reason}, 0, 0, started)
        {:error, reason}
    end
  end

  @doc "Reads up to `limit` feed records after `position` without filtering."
  @spec read_records(atom, position, pos_integer) ::
          {:ok, [Alambique.Feed.Record.t() | Alambique.Feed.Rewind.t() | Alambique.Feed.Rejected.t()], position}
          | {:error, term}
  def read_records(instance, position, limit) do
    ctx = Alambique.Feed.ctx(Atanor.Registry.config(instance).alambique)
    Alambique.Feed.read(ctx, position, limit)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  The changes and rewind markers of `namespace` in `records`. An `Alambique.Feed.Rejected` (an object that
  could not be decoded) belongs to no namespace and is left out; `report_rejected/3` makes it visible
  (design §16.1).
  """
  @spec keep([Alambique.Feed.Record.t() | Alambique.Feed.Rewind.t() | Alambique.Feed.Rejected.t()], String.t()) ::
          [Change.t() | Change.Rewind.t()]
  def keep(records, namespace) do
    Enum.flat_map(records, fn
      %Alambique.Feed.Rejected{} ->
        []

      record ->
        with {:ok, {^namespace, _}} <- Atanor.Cell.parse(record.cell),
             {:ok, change} <- Change.from_record(record) do
          [change]
        else
          _ -> []
        end
    end)
  end

  @doc "How many `records` belong to a worker namespace."
  @spec kept_count([Alambique.Feed.Record.t() | Alambique.Feed.Rewind.t() | Alambique.Feed.Rejected.t()]) ::
          non_neg_integer
  def kept_count(records), do: Enum.count(records, &(not match?(%Alambique.Feed.Rejected{}, &1) and worker_cell?(&1)))

  @doc """
  Emits `[:atanor, :feed, :rejected]` for each object of `records` that Alambique could not decode and returns
  them (design §16.4). `namespace` is the reader's, `nil` for the tailer's shared stream.
  """
  @spec report_rejected(atom, String.t() | nil, [term]) :: [Alambique.Feed.Rejected.t()]
  def report_rejected(instance, namespace, records) do
    rejected = Enum.filter(records, &match?(%Alambique.Feed.Rejected{}, &1))

    for %{key: key, reason: reason} <- rejected do
      :telemetry.execute(
        [:atanor, :feed, :rejected],
        %{count: 1},
        %{instance: instance, namespace: namespace, reason: reason, key: key}
      )
    end

    rejected
  end

  defp worker_cell?(record), do: match?({:ok, _}, Atanor.Cell.parse(record.cell))

  @doc "Subscribes the calling process to `namespace` from `from`."
  @spec subscribe(atom, String.t(), from) :: {:ok, reference} | {:error, term}
  def subscribe(instance, namespace, from) do
    with :ok <- validate_from(instance, from) do
      {initial, now_ms} = now(instance)
      ref = make_ref()
      message = {:subscribe, self(), namespace, ref, from, now_ms}

      with {:ok, _pid} <- call(instance, initial, message) do
        {:ok, ref}
      end
    end
  end

  @doc "Removes a subscription; `:ok` also when the tailer or the subscription is gone."
  @spec unsubscribe(atom, reference) :: :ok
  def unsubscribe(instance, ref) do
    case Process.whereis(Tailer.name(instance)) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.call(pid, {:unsubscribe, ref})
        catch
          :exit, _ -> :ok
        end
    end
  end

  @doc false
  def emit_read(instance, namespace, result, records, kept, started, rejected \\ 0) do
    meta = %{instance: instance, namespace: namespace}

    meta =
      case result do
        :ok -> Map.put(meta, :result, :ok)
        {:error, reason} -> Map.merge(meta, %{result: :error, reason: reason})
      end

    :telemetry.execute(
      [:atanor, :feed, :read],
      %{duration: System.monotonic_time() - started, records: records, kept: kept, rejected: rejected},
      meta
    )
  end

  @doc false
  def emit_error(instance, reason, retry_ms) do
    :telemetry.execute(
      [:atanor, :feed, :error],
      %{count: 1, retry_ms: retry_ms},
      %{instance: instance, reason: reason}
    )
  end

  # A feed position is opaque; only Alambique can say whether it decodes.
  defp validate_from(_instance, :now), do: :ok
  defp validate_from(_instance, nil), do: :ok

  defp validate_from(instance, from) when is_binary(from) do
    case read_records(instance, from, 1) do
      {:ok, _records, _next} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_from(_instance, _from), do: {:error, {:invalid_option, :from}}

  defp call(instance, initial, message, attempts \\ 3) do
    case Supervisor.start_tailer(instance, initial) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, message)
        catch
          :exit, {:noproc, _} when attempts > 1 ->
            call(instance, initial, message, attempts - 1)

          :exit, {reason, _} when reason in [:normal, :shutdown] and attempts > 1 ->
            call(instance, initial, message, attempts - 1)

          :exit, reason when reason in [:normal, :shutdown] and attempts > 1 ->
            call(instance, initial, message, attempts - 1)

          :exit, reason ->
            {:error, {:tailer, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
