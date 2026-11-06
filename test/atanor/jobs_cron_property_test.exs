defmodule Atanor.Jobs.CronPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Jobs.Cron

  @minute 60_000
  @fields [{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}]

  # A field as `{text, values}`: the text written in the expression and the values it stands for.
  defp field({min, max}) do
    one_of([
      constant({"*", Enum.to_list(min..max)}),
      map(integer(min..max), &{"#{&1}", [&1]}),
      gen all(a <- integer(min..max), b <- integer(a..max)) do
        {"#{a}-#{b}", Enum.to_list(a..b)}
      end,
      gen all(step <- integer(1..(max + 1)), first <- integer(min..max)) do
        {"#{first}-#{max}/#{step}", Enum.take_every(first..max, step)}
      end,
      gen all(step <- integer(1..(max + 1))) do
        {"*/#{step}", Enum.take_every(min..max, step)}
      end,
      gen all(parts <- list_of(integer(min..max), min_length: 1, max_length: 4)) do
        {Enum.join(parts, ","), parts}
      end
    ])
  end

  defp expression do
    gen all(parts <- fixed_list(Enum.map(@fields, &field/1))) do
      {texts, values} = Enum.unzip(parts)
      {Enum.join(texts, " "), Enum.map(values, &MapSet.new/1), Enum.map(parts, &elem(&1, 0))}
    end
  end

  # Whether the minute of `ms` fires: day-of-month and day-of-week are or-ed when both are restricted
  # (a field with every value counts as unrestricted).
  defp fires?([minute, hour, dom, month, dow], ms) do
    %DateTime{year: y, month: mo, day: d, hour: h, minute: mi} = DateTime.from_unix!(div(ms, 1000))
    dow = MapSet.new(dow, &rem(&1, 7))
    dom? = d in dom
    dow? = rem(Date.day_of_week(Date.new!(y, mo, d)), 7) in dow

    day? =
      cond do
        MapSet.size(dom) == 31 and MapSet.size(dow) == 7 -> true
        MapSet.size(dom) == 31 -> dow?
        MapSet.size(dow) == 7 -> dom?
        true -> dom? or dow?
      end

    mi in minute and h in hour and mo in month and day?
  end

  defp instant, do: map(integer(0..4_000_000_000), &(&1 * 1000 + 17 * 1000))

  # Minute by minute from `from`, the first firing minute within `days` days.
  defp scan(sets, from, days) do
    start = div(from, @minute) * @minute + @minute

    Enum.find_value(0..(days * 1440), fn n -> if fires?(sets, start + n * @minute), do: start + n * @minute end)
  end

  describe "parse" do
    # Every field written with `*`, lists, ranges and steps stands for the values of the model.
    property "parse accepts what the five-field grammar writes" do
      check all({text, _sets, _} <- expression()) do
        assert {:ok, _} = Cron.parse(text)
      end
    end

    # A value outside the range of its field is refused, at any position.
    property "a value above the maximum of its field is refused" do
      check all(position <- integer(0..4), {text, _, _} <- expression()) do
        {_, max} = Enum.at(@fields, position)
        bad = text |> String.split(" ") |> List.replace_at(position, "#{max + 1}") |> Enum.join(" ")
        assert {:error, {_, _}} = Cron.parse(bad)
      end
    end

    # A step of zero, a reversed range and a wrong number of fields are refused.
    property "bad steps, reversed ranges and field counts are refused" do
      check all(count <- member_of([0, 1, 2, 3, 4, 6, 7]), {text, _, _} <- expression()) do
        fields = String.split(text, " ")
        assert {:error, {:field_count, ^count}} = Cron.parse(Enum.join(Enum.take(Stream.cycle(fields), count), " "))
      end

      assert {:error, {:minute, :bad_step}} = Cron.parse("*/0 * * * *")
      assert {:error, {:minute, :bad_range}} = Cron.parse("30-10 * * * *")
      assert {:error, {:hour, :out_of_range}} = Cron.parse("* 24 * * *")
      assert {:error, {:dom, :out_of_range}} = Cron.parse("* * 0 * *")
    end

    # Sunday is 0 or 7.
    property "day of week 7 is the same as 0" do
      check all(from <- instant()) do
        assert Cron.next_after("0 0 * * 7", from) == Cron.next_after("0 0 * * 0", from)
      end
    end
  end

  describe "next_after" do
    # The next time is the first minute after `from` that the expression fires, as a scan minute by minute finds it.
    property "the next time is the first firing minute after the instant" do
      check all({text, sets, _} <- expression(), from <- instant(), max_runs: 150) do
        result = Cron.next_after(text, from)

        case scan(sets, from, 8) do
          nil ->
            case result do
              {:ok, at} -> assert at > from + 8 * 1440 * @minute and fires?(sets, at)
              {:error, :no_match} -> :ok
            end

          expected ->
            assert result == {:ok, expected}
        end
      end
    end

    # The next time is strictly after the instant, on a minute boundary, and never moves back when the instant moves on.
    property "next_after is strictly later, aligned, and monotone" do
      check all({text, _, _} <- expression(), from <- instant(), delta <- integer(0..(3 * 86_400_000)), max_runs: 100) do
        with {:ok, a} <- Cron.next_after(text, from), {:ok, b} <- Cron.next_after(text, from + delta) do
          assert a > from and rem(a, @minute) == 0
          assert b >= a
          assert b > from + delta
          if from + delta < a, do: assert(b == a)
        end
      end
    end

    # Asking from a firing time gives the following firing, never the same time again.
    property "from a firing time the next one is later" do
      check all({text, _, _} <- expression(), from <- instant(), max_runs: 100) do
        with {:ok, a} <- Cron.next_after(text, from), {:ok, b} <- Cron.next_after(text, a) do
          assert b > a
        end
      end
    end
  end
end
