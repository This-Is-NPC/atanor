defmodule Atanor.AdmissionPropertyTest do
  @moduledoc """
  Admission (design §7.1) over random sequences of samples, enters and leaves, checked against a model: it
  never admits at or over the thresholds, never refuses below both, the memory gate has hysteresis, and the
  requests in flight never go negative and return to 0.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Admission

  @limit 1_000
  @fraction 0.8
  @max 5
  @refuse_at @limit * @fraction
  @resume_at @limit * (@fraction - 0.05)

  defp events do
    one_of([
      map(integer(0..1_200), &{:sample, &1}),
      constant(:enter),
      constant(:leave)
    ])
    |> list_of(max_length: 120)
  end

  # Runs the events, checking each decision against the model: `{refusing, in_flight, last sample}`.
  defp run(events) do
    Enum.reduce(events, {Admission.new(@limit, @fraction, @max), {false, 0, 0}}, fn event, {state, model} ->
      {decision, state} = Admission.step(state, event)
      {state, check(event, decision, state, model)}
    end)
  end

  defp check({:sample, bytes}, :ok, state, {refusing, in_flight, _}) do
    refusing =
      cond do
        bytes >= @refuse_at -> true
        bytes < @resume_at -> false
        true -> refusing
      end

    assert state.refusing == refusing
    {refusing, in_flight, bytes}
  end

  defp check(:enter, decision, state, {refusing, in_flight, sample}) do
    case decision do
      :admit ->
        refute refusing
        assert sample < @refuse_at
        assert in_flight < @max
        assert state.in_flight == in_flight + 1
        {refusing, in_flight + 1, sample}

      {:refuse, :memory} ->
        assert refusing
        assert state.in_flight == in_flight
        {refusing, in_flight, sample}

      {:refuse, :in_flight} ->
        refute refusing
        assert in_flight >= @max
        assert state.in_flight == in_flight
        {refusing, in_flight, sample}
    end
  end

  defp check(:leave, :ok, state, {refusing, in_flight, sample}) do
    assert state.in_flight >= 0
    {refusing, max(in_flight - 1, 0), sample}
  end

  property "the decisions follow the model" do
    check all(events <- events()) do
      {state, {refusing, in_flight, _}} = run(events)
      assert state.refusing == refusing
      assert state.in_flight == in_flight
    end
  end

  property "never admits at or over the refuse mark, never refuses below both marks" do
    check all(events <- events(), bytes <- integer(0..1_200)) do
      {state, _} = run(events)

      {_, state} = Admission.step(state, {:sample, bytes})
      {decision, _} = Admission.step(state, :enter)

      if bytes >= @refuse_at, do: assert(match?({:refuse, _}, decision))

      if bytes < @resume_at and state.in_flight < @max, do: assert(decision == :admit)
    end
  end

  property "hysteresis: between the marks the verdict does not change" do
    check all(events <- events(), bytes <- integer(ceil(@resume_at)..(ceil(@refuse_at) - 1))) do
      {state, _} = run(events)
      {:ok, next} = Admission.step(state, {:sample, bytes})
      assert next.refusing == state.refusing
    end
  end

  property "in flight never goes negative and returns to 0 after every leave" do
    check all(events <- events()) do
      {state, _} = run(events)
      assert state.in_flight in 0..@max

      state = Enum.reduce(1..@max, state, fn _, state -> elem(Admission.step(state, :leave), 1) end)
      assert state.in_flight == 0
    end
  end

  property "a node with no limit never refuses by memory" do
    check all(events <- events()) do
      Enum.reduce(events, Admission.new(nil, 0.85, @max), fn event, state ->
        {decision, state} = Admission.step(state, event)
        refute decision == {:refuse, :memory}
        state
      end)
    end
  end
end
