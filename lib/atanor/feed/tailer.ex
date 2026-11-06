defmodule Atanor.Feed.Tailer do
  @moduledoc false
  # One tailer per instance and node (design §16.2). It polls the change feed,
  # catches each subscriber up from its own position and fans changes out to
  # the processes that subscribed, filtered by namespace.

  use GenServer

  require Logger

  alias Atanor.Feed

  def child_spec({instance, position}) do
    %{
      id: {__MODULE__, instance},
      start: {__MODULE__, :start_link, [{instance, position}]},
      restart: :temporary
    }
  end

  def start_link({instance, position}) do
    GenServer.start_link(__MODULE__, {instance, position}, name: name(instance))
  end

  @doc "The registered name of the instance's feed tailer."
  def name(instance), do: Module.concat(instance, FeedTailer)

  @impl true
  def init({instance, position}) do
    config = Atanor.Registry.config(instance)

    state = %{
      instance: instance,
      config: config,
      position: position,
      subscribers: %{},
      backoff_ms: config.feed.retry_ms,
      rejected_warned_at: nil,
      rejected_unwarned: 0
    }

    Process.send_after(self(), :poll, config.feed.poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid, namespace, ref, from, now_ms}, _from, state) do
    monitor = Process.monitor(pid)

    {status, cursor, min_at, last_position} =
      case from do
        :now -> {:live, nil, now_ms, state.position}
        position -> {:pending, position, nil, position}
      end

    subscriber = %{
      ref: ref,
      pid: pid,
      monitor: monitor,
      namespace: namespace,
      status: status,
      cursor: cursor,
      min_at: min_at,
      last_position: last_position
    }

    {:reply, {:ok, ref}, put_in(state.subscribers[ref], subscriber)}
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    case Map.pop(state.subscribers, ref) do
      {nil, _subscribers} ->
        {:reply, :ok, state}

      {subscriber, subscribers} ->
        Process.demonitor(subscriber.monitor, [:flush])
        state = %{state | subscribers: subscribers}

        if map_size(subscribers) == 0,
          do: {:stop, :normal, :ok, state},
          else: {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:poll, %{subscribers: subscribers} = state) when map_size(subscribers) == 0,
    do: {:stop, :normal, state}

  def handle_info(:poll, state) do
    {state, failure, more?} = poll(state)
    retry_ms = state.backoff_ms

    delay =
      case failure do
        # The feed moved on, or a subscriber is still catching up: the next page is read at once, so a backlog
        # drains at the speed of the store and not at one page per `poll_ms`.
        nil when more? ->
          0

        nil ->
          state.config.feed.poll_ms

        reason ->
          Feed.emit_error(state.instance, reason, retry_ms)
          Logger.warning("atanor: change feed read failed: #{inspect(reason)}; retrying in #{retry_ms} ms")
          retry_ms
      end

    state = %{state | backoff_ms: next_backoff(state, failure)}
    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.subscribers, fn {_ref, subscriber} -> subscriber.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {ref, _subscriber} ->
        subscribers = Map.delete(state.subscribers, ref)
        state = %{state | subscribers: subscribers}

        if map_size(subscribers) == 0,
          do: {:stop, :normal, state},
          else: {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp poll(state) do
    {state, pending_failure} = catch_up(state)

    case read_live(state) do
      {:ok, state, moved?} ->
        {state, pending_failure, moved? or Enum.any?(state.subscribers, fn {_ref, s} -> s.status == :pending end)}

      {:error, reason, state} ->
        {state, reason, false}
    end
  end

  # A subscriber that starts behind the tailer reads its own pages until it
  # reaches the end of the feed; then it receives the shared stream.
  defp catch_up(state) do
    state.subscribers
    |> Map.values()
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.reduce({state, nil}, fn subscriber, {acc, failure} ->
      case Feed.read_page(acc.instance, subscriber.namespace, subscriber.cursor, acc.config.feed.page_size) do
        {:ok, changes, rejected, next} ->
          acc = acc |> warn_rejected(rejected) |> send_changes(subscriber.ref, changes, next)
          {advance(acc, subscriber.ref, next), failure}

        {:error, reason} ->
          {acc, failure || reason}
      end
    end)
  end

  defp advance(state, ref, next) do
    case state.subscribers[ref] do
      nil ->
        state

      %{cursor: cursor} = subscriber ->
        status = if next == cursor, do: :live, else: :pending
        put_in(state.subscribers[ref], %{subscriber | cursor: next, status: status})
    end
  end

  defp read_live(state) do
    started = System.monotonic_time()

    case Feed.read_records(state.instance, state.position, state.config.feed.page_size) do
      {:ok, records, next} ->
        rejected = Feed.report_rejected(state.instance, nil, records)
        Feed.emit_read(state.instance, nil, :ok, length(records), Feed.kept_count(records), started, length(rejected))
        state = warn_rejected(state, rejected)

        {:ok, fanout(%{state | position: next}, records, next), next != state.position}

      {:error, reason} ->
        Feed.emit_read(state.instance, nil, {:error, reason}, 0, 0, started)
        {:error, reason, state}
    end
  end

  # At most one warning per `feed.max_backoff_ms`, the slowest rate of the read-failure warnings; the
  # telemetry event counts every object.
  defp warn_rejected(state, []), do: state

  defp warn_rejected(state, rejected) do
    now = System.monotonic_time(:millisecond)
    count = state.rejected_unwarned + length(rejected)

    if state.rejected_warned_at == nil or now - state.rejected_warned_at >= state.config.feed.max_backoff_ms do
      last = List.last(rejected)

      Logger.warning(
        "atanor: change feed skipped #{count} object(s) it could not read; " <>
          "the last is #{inspect(last.key)}: #{inspect(last.reason)}"
      )

      %{state | rejected_warned_at: now, rejected_unwarned: 0}
    else
      %{state | rejected_unwarned: count}
    end
  end

  defp fanout(state, records, next) do
    Enum.reduce(Map.keys(state.subscribers), state, fn ref, acc ->
      case acc.subscribers[ref] do
        %{status: :live} = subscriber -> deliver(acc, subscriber, records, next)
        _pending -> acc
      end
    end)
  end

  defp deliver(state, subscriber, records, next) do
    changes = Feed.keep(records, subscriber.namespace)

    changes =
      if subscriber.min_at,
        do: Enum.filter(changes, &(&1.at >= subscriber.min_at)),
        else: changes

    send_changes(state, subscriber.ref, changes, next)
  end

  defp send_changes(state, ref, changes, next) do
    case state.subscribers[ref] do
      nil ->
        state

      subscriber ->
        if changes != [], do: send(subscriber.pid, {:atanor_changes, ref, changes, next})
        state = put_in(state.subscribers[ref].last_position, next)
        check_backlog(state, ref)
    end
  end

  defp check_backlog(state, ref) do
    case state.subscribers[ref] do
      nil ->
        state

      subscriber ->
        case Process.info(subscriber.pid, :message_queue_len) do
          {:message_queue_len, queue} when queue > state.config.feed.max_backlog ->
            :telemetry.execute(
              [:atanor, :feed, :subscriber, :dropped],
              %{count: 1, backlog: queue},
              %{instance: state.instance, namespace: subscriber.namespace, reason: :backlog}
            )

            Logger.warning("atanor: dropping change feed subscriber #{inspect(ref)}: #{queue} messages waiting")

            send(subscriber.pid, {:atanor_feed_dropped, ref, subscriber.last_position})
            Process.demonitor(subscriber.monitor, [:flush])
            %{state | subscribers: Map.delete(state.subscribers, ref)}

          _ ->
            state
        end
    end
  end

  defp next_backoff(state, nil), do: state.config.feed.retry_ms

  defp next_backoff(state, _failure),
    do: min(state.backoff_ms * 2, state.config.feed.max_backoff_ms)
end
