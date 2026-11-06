defmodule Atanor.Alarms do
  @moduledoc """
  Alarms (design §7.4). A worker has at most one alarm per cell. The row in
  the cell's table `_atanor_alarms` is authoritative; the store holds an index
  entry `alarms/<minute>/<shard>/<at_ms>/<worker>/<cell-id>` so due alarms are
  found without waking cells.

  Writes put the index entry first, then the row, so a crash leaves at worst
  a stale entry. An entry fires only when the cell's row has the same time:
  a stale entry (the alarm was replaced, cancelled or already done) is deleted
  and does nothing, after a read of the row that checks the lease.

  Delivery is at least once. Firing claims the alarm in a cell transaction,
  which moves the row to a retry time, runs `handle_alarm/3` outside the
  transaction, and then deletes the row if it is still the claimed one. A
  failure schedules a retry with backoff, up to `:max_attempts`; a node that
  dies mid-handler leaves the retry in place. Two schedulers can therefore
  race for the same entry, but only the one whose claim commits runs it.

  The shard count is `:alarms`' `:shards` (64 by default). The shard is part of
  every index key, so the count is fixed for the life of an instance's data: the
  first start records it under `meta/alarms/shards` in the metadata store, and a
  later start with a different value refuses to start. An instance created
  before the record existed is adopted as 64. If the metadata store cannot
  answer at start, the node logs a warning and starts; a later start checks the
  record again. The page size, concurrency and backoff of a scan are `:alarms`
  options too.
  """

  alias Alambique.Tx
  alias Atanor.{Cell, Dispatch, Env, Registry, Store}

  require Logger

  @default_shards 64
  @shards_key "meta/alarms/shards"
  @table "_atanor_alarms"
  @jobs_worker "@jobs"

  @doc "The reserved worker name of the jobs wake-up row."
  def jobs_worker, do: @jobs_worker

  @doc "The reserved wake-up row is not a worker alarm."
  def jobs_worker?(@jobs_worker), do: true
  def jobs_worker?(_), do: false

  @doc false
  def table, do: @table

  @doc "The `:pg` group of the schedulers that share a prefix."
  def group(prefix), do: {__MODULE__, prefix}

  @doc "Which of `members` (scheduler pids) scans `shard`: rendezvous hashing."
  @spec owner([pid], non_neg_integer) :: pid
  def owner(members, shard), do: Enum.max_by(members, &:erlang.phash2({shard, identity(&1)}))

  # The hash of a pid differs between its node and the others, and every node
  # has to rank the members alike. The node and the local part of the pid
  # (`<N.id.serial>`, where N is relative to the viewer) are the same everywhere.
  defp identity(pid) do
    [_, local] = pid |> :erlang.pid_to_list() |> List.to_string() |> String.split(".", parts: 2)
    {node(pid), local}
  end

  @doc false
  def set(%Env{instance: instance} = env, cell, at_ms, payload) do
    worker = Env.worker(env)

    with {:ok, id} <- Cell.id(cell),
         :ok <- Cell.partitioned(instance, cell),
         store = Store.handle(instance),
         :ok <- put_index(store, config(instance), at_ms, worker, id),
         {:ok, previous} <-
           cleanup_on_error(store, config(instance), at_ms, worker, id, fn ->
             Cell.transaction(instance, cell, fn tx ->
               run!(
                 tx,
                 "CREATE TABLE IF NOT EXISTS #{@table} (worker TEXT PRIMARY KEY, at_ms INTEGER NOT NULL, payload BLOB NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)"
               )

               previous = first(run!(tx, "SELECT at_ms FROM #{@table} WHERE worker = ?", [worker]))

               run!(
                 tx,
                 "INSERT INTO #{@table} (worker, at_ms, payload, attempts) VALUES (?, ?, ?, 0) " <>
                   "ON CONFLICT (worker) DO UPDATE SET at_ms = excluded.at_ms, payload = excluded.payload, attempts = 0",
                 [worker, at_ms, {:blob, payload}]
               )

               previous
             end)
           end) do
      if previous != nil and previous != at_ms, do: delete_index(store, config(instance), previous, worker, id)
      :ok
    end
  end

  # The entry is written before the row (see `expire/3`). When the cell refuses the address for good the row
  # can never exist, so the entry goes at once; after any other error it stays and expires if the row is missing.
  defp cleanup_on_error(store, config, at_ms, worker, id, fun) do
    case fun.() do
      {:error, reason} = error ->
        if permanent?(reason), do: delete_index(store, config, at_ms, worker, id)
        error

      ok ->
        ok
    end
  end

  defp permanent?(:invalid_cell_id), do: true
  defp permanent?({:partition_required, _}), do: true
  defp permanent?(_), do: false

  @doc false
  def cancel(%Env{instance: instance} = env, cell) do
    worker = Env.worker(env)

    with {:ok, id} <- Cell.id(cell),
         {:ok, previous} <-
           Cell.transaction(instance, cell, fn tx ->
             case Tx.execute(tx, "DELETE FROM #{@table} WHERE worker = ? RETURNING at_ms", [worker]) do
               {:ok, result} -> first(result)
               {:error, reason} -> if no_table?(reason), do: nil, else: Tx.rollback(tx, reason)
             end
           end) do
      if previous != nil, do: delete_index(Store.handle(instance), config(instance), previous, worker, id)
      :ok
    end
  end

  @doc """
  Fires the alarms that are due in the shards `owns?` accepts. Returns the
  number of alarms whose handler ran to success. Called by the scheduler on
  every tick.
  """
  @spec run(atom, (non_neg_integer -> boolean)) :: non_neg_integer
  def run(instance, owns?) do
    config = Registry.config(instance)
    now = now_ms(config)
    page(instance, config, Store.handle(instance), minute(now), now, owns?, nil, 0)
  end

  @doc false
  # Records `:alarms`' `:shards` on the first start and refuses a different
  # count later: the shard is part of every index key.
  @spec ensure_shards(Atanor.Config.t()) :: :ok | {:error, term}
  def ensure_shards(config) do
    store = Store.handle(config.name)
    configured = config.alarms.shards

    case Store.get(store, @shards_key) do
      {:ok, body, _etag, _meta} ->
        check_shards(body, configured)

      {:error, :not_found} ->
        write_shards(store, configured)

      {:error, reason} ->
        Logger.warning("atanor: could not read the alarm shard record: #{inspect(reason)}")
        :ok
    end
  end

  defp write_shards(store, configured) do
    case Store.put(store, @shards_key, Integer.to_string(configured), :if_none_match) do
      {:ok, _etag} ->
        :ok

      {:error, :precondition_failed} ->
        case Store.get(store, @shards_key) do
          {:ok, body, _etag, _meta} ->
            check_shards(body, configured)

          {:error, reason} ->
            Logger.warning("atanor: could not read the alarm shard record: #{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("atanor: could not write the alarm shard record: #{inspect(reason)}")
        :ok
    end
  end

  defp check_shards(body, configured) do
    case Integer.parse(body) do
      {shards, ""} when shards > 0 and shards == configured ->
        :ok

      {shards, ""} when shards > 0 ->
        {:error, {:alarm_shards_changed, shards, configured}}

      _ ->
        {:error, {:alarm_shards_invalid, body}}
    end
  end

  @doc """
  One page of the index entries after the key `after_key` (`nil` for the
  first), in key order: the alarms set, plus claimed ones waiting for a retry
  and stale entries not yet removed. `next` is the key to pass for the
  following page, or `nil`.
  """
  @spec pending(atom, String.t() | nil, pos_integer) ::
          {:ok, %{alarms: [map], next: String.t() | nil}} | {:error, term}
  def pending(instance, after_key, limit) do
    with {:ok, keys, _} <- Store.list(Store.handle(instance), "alarms/", after_key, limit + 1) do
      {page, rest} = Enum.split(keys, limit)
      alarms = for key <- page, {:ok, entry} <- [parse(key)], entry.worker != @jobs_worker, do: entry
      {:ok, %{alarms: alarms, next: if(rest != [], do: List.last(page))}}
    end
  end

  defp page(instance, config, store, minute, now, owns?, after_key, fired) do
    case Store.list(store, "alarms/", after_key, config.alarms.page_size) do
      {:ok, [], _} ->
        fired

      {:ok, keys, _} ->
        {due, rest} = Enum.split_while(keys, &(minute_of(&1) <= minute))
        count = fire_all(instance, config, store, due, now, owns?)

        if rest == [] and length(keys) == config.alarms.page_size,
          do: page(instance, config, store, minute, now, owns?, List.last(keys), fired + count),
          else: fired + count

      {:error, reason} ->
        Logger.warning("atanor: could not list the alarm index: #{inspect(reason)}")
        fired
    end
  end

  defp fire_all(instance, config, store, keys, now, owns?) do
    entries = for key <- keys, {:ok, entry} <- [parse(key)], entry.at_ms <= now, owns?.(entry.shard), do: entry

    Atanor.Tasks.name(instance)
    |> Task.Supervisor.async_stream_nolink(entries, &fire(instance, config, store, &1),
      max_concurrency: config.alarms.concurrency,
      timeout: config.alarms.timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.zip(entries)
    |> Enum.count(fn
      {{:ok, :fired}, _} ->
        true

      {{:ok, _}, _} ->
        false

      {{:exit, reason}, entry} ->
        meta = %{worker: entry.worker, cell: entry.id, reason: reason, final: false}
        :telemetry.execute([:atanor, :alarm, :failed], %{duration: 0}, meta)
        false
    end)
  end

  # Returns :fired, :stale, :skipped, :failed or :lost (another scheduler won).
  defp fire(instance, config, store, entry) do
    with {:ok, cell} <- Cell.parse(entry.id) do
      if jobs_worker?(entry.worker) do
        fire_jobs(instance, config, store, cell, entry)
      else
        fire_worker(instance, config, store, cell, entry)
      end
    else
      _ -> :skipped
    end
  end

  defp fire_worker(instance, config, store, cell, entry) do
    with {:ok, deployment} <- Registry.deployment(instance, entry.worker),
         {:ok, row} <- read(instance, cell, entry.worker) do
      case row do
        [at_ms, _payload, attempts] when at_ms == entry.at_ms ->
          claim(instance, config, store, cell, entry, attempts + 1, fn claimed, payload, attempt ->
            handle(instance, config, store, deployment, cell, claimed, attempt, payload)
          end)

        _ ->
          unmatched(instance, config, store, cell, entry)
      end
    else
      # An address that can never hold the alarm (an entry an earlier `set_alarm` left behind) expires.
      {:error, reason} -> if permanent?(reason), do: expire(store, config, entry), else: :skipped
      _ -> :skipped
    end
  end

  defp fire_jobs(instance, config, store, cell, entry) do
    with {:ok, row} <- read(instance, cell, @jobs_worker) do
      case row do
        [at_ms, _payload, attempts] when at_ms == entry.at_ms ->
          claim(instance, config, store, cell, entry, attempts + 1, fn claimed, _payload, _attempt ->
            handle_jobs(instance, cell, claimed)
          end)

        _ ->
          unmatched(instance, config, store, cell, entry)
      end
    end
  end

  # An entry is dropped only on a read that cannot be stale: a node that lost the cell can answer from its
  # old copy for a while after a takeover (design §8.12), and the entry may be the only one of the real row.
  defp unmatched(instance, config, store, cell, entry) do
    case read(instance, cell, entry.worker, verify_lease: true) do
      {:ok, [at_ms | _]} when at_ms == entry.at_ms -> :skipped
      {:ok, _} -> expire(store, config, entry)
      {:error, _} -> :skipped
    end
  end

  # `set_alarm` writes the entry before the row, so a missing or different row
  # is stale only once the entry is older than `timeout_ms`, which bounds a
  # `set_alarm`. A scan that finds an entry earlier leaves it for the next one.
  defp expire(store, config, entry) do
    key = index_key(entry.at_ms, entry.worker, entry.id, config.alarms.shards, entry.nonce)

    case Store.get(store, key) do
      {:ok, body, _etag, _meta} ->
        written = with {ms, ""} <- Integer.parse(body), do: ms

        if is_integer(written) and now_ms(config) - written < config.alarms.timeout_ms do
          :skipped
        else
          delete_index(store, config, entry.at_ms, entry.worker, entry.id, entry.nonce)
          :stale
        end

      {:error, :not_found} ->
        :stale

      {:error, _} ->
        :skipped
    end
  end

  defp claim(instance, config, store, cell, entry, attempt, fun) do
    lease = now_ms(config) + config.alarms.timeout_ms + backoff(attempt, config)
    sql = "UPDATE #{@table} SET at_ms = ?, attempts = ? WHERE worker = ? AND at_ms = ? RETURNING payload"
    id = entry.id

    with :ok <- put_index(store, config, lease, entry.worker, id, entry.nonce),
         # Runs on the owner. A cell taken over before the old lease ended starts no handler yet
         # (design §8.13): the entry stays as it is and the next scan tries again.
         {:ok, claimed} <-
           Cell.transaction(instance, cell, fn tx ->
             if Atanor.Fence.held?(instance, id),
               do: :held,
               else: first(run!(tx, sql, [lease, attempt, entry.worker, entry.at_ms]))
           end) do
      case claimed do
        :held ->
          delete_index(store, config, lease, entry.worker, id, entry.nonce)
          :skipped

        nil ->
          delete_index(store, config, entry.at_ms, entry.worker, id, entry.nonce)
          :lost

        payload ->
          delete_index(store, config, entry.at_ms, entry.worker, id, entry.nonce)
          fun.(%{entry | at_ms: lease}, payload, attempt)
      end
    else
      _ -> :skipped
    end
  end

  defp handle_jobs(instance, cell, claimed) do
    case Atanor.Jobs.run(instance, cell, claimed.at_ms) do
      :ok ->
        :fired

      {:error, reason} ->
        Logger.warning("atanor: the job wake-up for #{claimed.id} failed: #{inspect(reason)}")
        :failed
    end
  end

  defp handle(instance, config, store, deployment, cell, claimed, attempt, payload) do
    started = System.monotonic_time()
    env = Env.new(instance, deployment)

    case outcome(Dispatch.execute(env, cell, {:alarm, cell, payload})) do
      :ok ->
        :ok = settle(instance, store, cell, claimed, attempt, nil)
        duration = System.monotonic_time() - started
        :telemetry.execute([:atanor, :alarm, :fired], %{duration: duration}, meta(deployment, claimed, attempt))
        :fired

      {:error, reason} ->
        final? = attempt >= config.alarms.max_attempts
        retry_at = if final?, do: nil, else: now_ms(config) + backoff(attempt, config)
        settle(instance, store, cell, claimed, attempt, retry_at)
        duration = System.monotonic_time() - started
        failed = Map.merge(meta(deployment, claimed, attempt), %{reason: reason, final: final?})
        :telemetry.execute([:atanor, :alarm, :failed], %{duration: duration}, failed)
        :failed
    end
  end

  defp outcome({:ok, :ok}), do: :ok
  defp outcome({:ok, {:error, reason}}), do: {:error, reason}
  defp outcome({:error, reason}), do: {:error, reason}

  # Deletes the claimed row (`retry_at` nil) or moves it to `retry_at`, only
  # while it is still the claimed one: a handler that set a new alarm wins.
  defp settle(instance, store, cell, claimed, attempt, retry_at) do
    if retry_at, do: put_index(store, config(instance), retry_at, claimed.worker, claimed.id)

    {sql, params} =
      if retry_at,
        do:
          {"UPDATE #{@table} SET at_ms = ? WHERE worker = ? AND at_ms = ? AND attempts = ?",
           [retry_at, claimed.worker, claimed.at_ms, attempt]},
        else:
          {"DELETE FROM #{@table} WHERE worker = ? AND at_ms = ? AND attempts = ?",
           [claimed.worker, claimed.at_ms, attempt]}

    with {:ok, _} <- Cell.transaction(instance, cell, fn tx -> run!(tx, sql, params) end) do
      delete_index(store, config(instance), claimed.at_ms, claimed.worker, claimed.id)
      :ok
    end
  end

  defp meta(deployment, entry, attempt),
    do: %{worker: entry.worker, deployment: deployment.id, cell: entry.id, attempt: attempt}

  defp read(instance, cell, worker, opts \\ []) do
    sql = "SELECT at_ms, payload, attempts FROM #{@table} WHERE worker = ?"

    case Cell.query(instance, cell, sql, [worker], opts) do
      {:ok, %{rows: [row]}} -> {:ok, row}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> if no_table?(reason), do: {:ok, nil}, else: {:error, reason}
    end
  end

  defp backoff(attempt, config),
    do: min(config.alarms.backoff_ms * Integer.pow(2, attempt - 1), config.alarms.max_backoff_ms)

  defp now_ms(config) do
    {clock, clock_config} = config.alarms.clock
    clock.now_ms(clock_config)
  end

  @doc false
  def now(config), do: now_ms(config)

  # The body is the time of writing: a due entry whose row is missing may be
  # an alarm that is still being committed, and is only stale after a while.
  @doc false
  def put_index(store, config, at_ms, worker, id, nonce \\ nil) do
    key = index_key(at_ms, worker, id, config.alarms.shards, nonce)
    with {:ok, _} <- Store.put(store, key, Integer.to_string(now_ms(config))), do: :ok
  end

  defp config(instance), do: Registry.config(instance)

  @doc false
  def delete_index(store, config, at_ms, worker, id, nonce \\ nil),
    do: Store.delete(store, index_key(at_ms, worker, id, config.alarms.shards, nonce))

  @doc false
  def index_key(at_ms, worker, id, shards \\ @default_shards, nonce \\ nil),
    do:
      "alarms/#{pad(minute(at_ms))}/#{shard(id, shards)}/#{at_ms}/#{worker}/#{id}" <>
        if(nonce, do: "/#{nonce}", else: "")

  defp parse(key) do
    with ["alarms", _minute, shard, at_ms, worker, id | rest] <- String.split(key, "/"),
         {at_ms, ""} <- Integer.parse(at_ms),
         {shard, ""} <- Integer.parse(shard) do
      {:ok, %{at_ms: at_ms, shard: shard, worker: worker, id: id, nonce: List.first(rest)}}
    else
      _ -> :error
    end
  end

  defp minute_of("alarms/" <> rest), do: rest |> String.split("/", parts: 2) |> hd() |> String.to_integer()
  defp minute(at_ms), do: div(at_ms, 60_000)
  defp pad(minute), do: minute |> Integer.to_string() |> String.pad_leading(10, "0")
  @doc false
  def shard(id, shards \\ @default_shards), do: :erlang.phash2(id, shards)

  defp first(%{rows: [[value] | _]}), do: value
  defp first(%{rows: []}), do: nil

  defp run!(tx, sql, params \\ []) do
    case Tx.execute(tx, sql, params) do
      {:ok, result} -> result
      {:error, reason} -> Tx.rollback(tx, reason)
    end
  end

  defp no_table?(message), do: is_binary(message) and String.contains?(message, "no such table")
end
