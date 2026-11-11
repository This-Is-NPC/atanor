defmodule Atanor.Admin.Throttle do
  @moduledoc false
  # Limits the failed token attempts of the admin and dashboard listeners per client address.
  #
  # An address gets `max_failures` failures in a window of `failure_window_ms`, which opens at its first attempt
  # after the previous window ended. Past that it is refused, whatever it sends, until the window ends.
  # An attempt reserves a place before the token is compared, so parallel guesses cannot exceed the limit,
  # and gives it back when the token is right. A request without a bearer token is not a guess and is
  # not counted. The address is the peer of the connection: `X-Forwarded-For` is never read, so behind a
  # proxy every client shares the proxy's address. IPv6 clients are tracked by their /64.
  alias Atanor.Registry

  @type limits :: %{
          :max_failures => pos_integer,
          :failure_window_ms => pos_integer,
          :tracked_addresses => pos_integer,
          optional(atom) => term
        }

  @doc """
  Runs `attempt` unless `ip` is locked out. `attempt` answers `{:ok, _}` for a right token and
  `{:error, :unauthorized}` for a wrong one; anything else is not counted as a failure.
  """
  @spec run(atom, atom, :inet.ip_address(), limits, (-> result)) :: result | {:error, {:throttled, pos_integer}}
        when result: term
  def run(name, listener, ip, limits, attempt) do
    table = Registry.attempts(name)
    key = {listener, subject(ip)}

    case admit(table, key, limits, now()) do
      {:ok, window} ->
        result = attempt.()
        if result != {:error, :unauthorized}, do: release(table, key, window)
        result

      {:refused, retry_ms} ->
        {:error, {:throttled, max(div(retry_ms + 999, 1000), 1)}}
    end
  end

  @doc false
  @spec admit(:ets.table(), term, limits, integer) :: {:ok, integer} | {:refused, pos_integer}
  def admit(table, key, %{max_failures: max, failure_window_ms: window, tracked_addresses: tracked} = limits, now) do
    case :ets.lookup(table, key) do
      [] ->
        if :ets.info(table, :size) >= tracked, do: Registry.evict(table, max(div(tracked, 16), 1))
        if :ets.insert_new(table, {key, now, 1}), do: {:ok, now}, else: admit(table, key, limits, now)

      [{_, start, _} = old] when now - start >= window ->
        replaced = :ets.select_replace(table, [{old, [], [{:const, {key, now, 1}}]}])
        if replaced == 1, do: {:ok, now}, else: admit(table, key, limits, now)

      [{_, start, _}] ->
        count = :ets.update_counter(table, key, {3, 1}, {key, start, 0})
        if count > max, do: {:refused, start + window - now}, else: {:ok, start}
    end
  end

  @doc false
  @spec release(:ets.table(), term, integer) :: :ok
  def release(table, key, window) do
    :ets.select_replace(table, [{{key, window, :"$1"}, [{:>, :"$1", 0}], [{{{:const, key}, window, {:-, :"$1", 1}}}]}])
    :ok
  end

  defp subject({a, b, c, d, _, _, _, _}), do: {a, b, c, d}
  defp subject(ip), do: ip

  defp now, do: System.monotonic_time(:millisecond)
end
