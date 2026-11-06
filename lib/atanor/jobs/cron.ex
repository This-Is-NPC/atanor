defmodule Atanor.Jobs.Cron do
  @moduledoc false
  # A small five-field cron parser: minute hour day-of-month month day-of-week.
  # It supports `*`, lists, ranges, steps and the usual `@...` macros. Times
  # are UTC and there is no time-zone dependency (design §15.4).

  @macros %{
    "@hourly" => "0 * * * *",
    "@daily" => "0 0 * * *",
    "@midnight" => "0 0 * * *",
    "@weekly" => "0 0 * * 0",
    "@monthly" => "0 0 1 * *",
    "@yearly" => "0 0 1 1 *",
    "@annually" => "0 0 1 1 *"
  }

  @unix_epoch :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

  @fields [
    {:minute, 0, 59},
    {:hour, 0, 23},
    {:dom, 1, 31},
    {:month, 1, 12},
    {:dow, 0, 7}
  ]

  @type spec :: %{
          minute: MapSet.t(),
          hour: MapSet.t(),
          dom: MapSet.t(),
          month: MapSet.t(),
          dow: MapSet.t(),
          dom_any: boolean,
          dow_any: boolean
        }

  @doc "Parses `expression`; `{:error, reason}` names the first bad field."
  @spec parse(term) :: {:ok, spec} | {:error, term}
  def parse(expression) when is_binary(expression) do
    expression = @macros |> Map.get(String.downcase(expression), expression) |> String.trim()
    parts = String.split(expression, ~r/\s+/, trim: true)

    if length(parts) == 5 do
      with {:ok, sets} <- parse_fields(Enum.zip(@fields, parts)) do
        {:ok,
         Map.merge(Map.new(sets), %{
           dom_any: MapSet.size(Map.fetch!(sets, :dom)) == 31,
           dow_any: MapSet.size(Map.fetch!(sets, :dow)) == 7
         })}
      end
    else
      {:error, {:field_count, length(parts)}}
    end
  end

  def parse(_), do: {:error, :not_a_string}

  @doc "The first time strictly after `from_ms`, in UTC, that `expression` fires."
  @spec next_after(spec | String.t(), integer) :: {:ok, integer} | {:error, term}
  def next_after(expression, from_ms) when is_binary(expression) do
    with {:ok, spec} <- parse(expression), do: next_after(spec, from_ms)
  end

  def next_after(spec, from_ms) when is_integer(from_ms) do
    start = div(from_ms, 60_000) * 60_000 + 60_000
    search(spec, start, start + 5 * 366 * 24 * 60 * 60_000)
  end

  # Steps by the largest field that does not match: a month, a day, an hour or a minute.
  defp search(_spec, ms, limit) when ms > limit, do: {:error, :no_match}

  defp search(spec, ms, limit) do
    {{year, month, day}, {hour, minute, _second}} = :calendar.system_time_to_universal_time(div(ms, 1000), :second)

    cond do
      not MapSet.member?(spec.month, month) ->
        {next_year, next_month} = if month == 12, do: {year + 1, 1}, else: {year, month + 1}
        search(spec, seconds({next_year, next_month, 1}, {0, 0, 0}) * 1000, limit)

      not day?(spec, year, month, day) ->
        search(spec, seconds({year, month, day}, {0, 0, 0}) * 1000 + 86_400_000, limit)

      not MapSet.member?(spec.hour, hour) ->
        search(spec, seconds({year, month, day}, {hour, 0, 0}) * 1000 + 3_600_000, limit)

      MapSet.member?(spec.minute, minute) ->
        {:ok, ms}

      true ->
        search(spec, ms + 60_000, limit)
    end
  end

  defp seconds(date, time), do: :calendar.datetime_to_gregorian_seconds({date, time}) - @unix_epoch

  defp day?(spec, year, month, day) do
    # :calendar Monday is 1; cron Sunday is 0.
    dow = rem(:calendar.day_of_the_week({year, month, day}), 7)
    dom? = MapSet.member?(spec.dom, day)
    dow? = MapSet.member?(spec.dow, dow)

    cond do
      spec.dom_any and spec.dow_any -> true
      spec.dom_any -> dow?
      spec.dow_any -> dom?
      true -> dom? or dow?
    end
  end

  defp parse_fields(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {{name, min, max}, text}, {:ok, acc} ->
      case field(text, min, max) do
        {:ok, set} -> {:cont, {:ok, Map.put(acc, name, normalize(name, set))}}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  defp normalize(:dow, set),
    do:
      MapSet.new(set, fn
        7 -> 0
        day -> day
      end)

  defp normalize(_, set), do: set

  defp field("*", min, max), do: {:ok, MapSet.new(min..max//1)}

  defp field(text, min, max) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case part(part, min, max) do
        {:ok, set} -> {:cont, {:ok, MapSet.union(acc, set)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp part(part, min, max) do
    {range, step} =
      case String.split(part, "/", parts: 2) do
        [range] -> {range, 1}
        [range, step] -> {range, parse_int(step)}
        _ -> {nil, 1}
      end

    with true <- is_integer(step) and step > 0,
         {:ok, first, last} <- bounds(range, min, max) do
      {:ok, MapSet.new(Enum.take_every(first..last//1, step))}
    else
      false -> {:error, :bad_step}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounds("*", min, max), do: {:ok, min, max}

  defp bounds(text, min, max) do
    case String.split(text, "-", parts: 2) do
      [single] ->
        case parse_int(single) do
          value when is_integer(value) and value in min..max//1 -> {:ok, value, value}
          _ -> {:error, :out_of_range}
        end

      [first, last] ->
        with first when is_integer(first) and first in min..max//1 <- parse_int(first),
             last when is_integer(last) and last in min..max//1 <- parse_int(last),
             true <- first <= last do
          {:ok, first, last}
        else
          _ -> {:error, :bad_range}
        end
    end
  end

  defp parse_int(text) do
    case Integer.parse(text) do
      {value, ""} -> value
      _ -> nil
    end
  end
end
