defmodule Atanor.Takeover.Throttle do
  @moduledoc """
  Bounds the `:no_quorum` takeover events (design §8.10): the first refusal is admitted, the following ones
  within `interval_ms` are counted, and the next admitted one reports the count. The state is one row of a
  public ETS table, replaced atomically, so concurrent requests need no process hop.
  """

  @key :no_quorum

  @doc """
  Admits or suppresses a refusal at `now_ms` (any monotonic clock, in milliseconds). `{:emit, suppressed}`
  carries the refusals suppressed since the last event.
  """
  @spec admit(:ets.table(), integer, pos_integer) :: {:emit, non_neg_integer} | :suppress
  def admit(table, now_ms, interval_ms) do
    :ets.insert_new(table, {@key, nil, 0})
    [{@key, last, suppressed} = old] = :ets.lookup(table, @key)

    {result, new} =
      if is_nil(last) or now_ms - last >= interval_ms,
        do: {{:emit, suppressed}, {@key, now_ms, 0}},
        else: {:suppress, {@key, last, suppressed + 1}}

    if :ets.select_replace(table, [{old, [], [{:const, new}]}]) == 1,
      do: result,
      else: admit(table, now_ms, interval_ms)
  end

  @doc "Refusals suppressed since the last event."
  @spec pending(:ets.table()) :: non_neg_integer
  def pending(table) do
    case :ets.lookup(table, @key) do
      [{@key, _, suppressed}] -> suppressed
      [] -> 0
    end
  end
end
