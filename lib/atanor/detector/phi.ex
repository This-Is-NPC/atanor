defmodule Atanor.Detector.Phi do
  @moduledoc false
  # The accrual failure detector of Hayashi et al. for one peer (design §8.7).
  # It keeps a sliding window of the intervals between heartbeats, models them
  # as a normal distribution and returns phi = -log10(P(a heartbeat arrives
  # later than now)). Phi grows with the time since the last heartbeat, and
  # more slowly on a jittery link. Times are in microseconds.

  @max_phi 300.0
  # Largest standardized distance the logistic approximation of the normal tail is evaluated at.
  @min_y -10.0

  defstruct [:size, :last, intervals: :queue.new(), count: 0, sum: 0, sum_sq: 0]

  @type t :: %__MODULE__{}

  @doc "A window seeded with two intervals around the expected one (`spread_ratio` of it apart), so that phi means something at once."
  @spec new(integer, pos_integer, pos_integer, number) :: t
  def new(now, interval, size, spread_ratio) do
    spread = round(interval * spread_ratio)
    %__MODULE__{size: size, last: now} |> add(interval - spread) |> add(interval + spread)
  end

  @doc "Records a heartbeat that arrived at `now`."
  @spec heartbeat(t, integer) :: t
  def heartbeat(%__MODULE__{last: last} = phi, now), do: %{add(phi, max(now - last, 0)) | last: now}

  @doc "Forgets the time since the last heartbeat without recording it as an interval."
  @spec touch(t, integer) :: t
  def touch(%__MODULE__{} = phi, now), do: %{phi | last: now}

  @doc "Microseconds since the last heartbeat."
  @spec elapsed(t, integer) :: integer
  def elapsed(%__MODULE__{last: last}, now), do: max(now - last, 0)

  @doc """
  Phi at `now`. `min_std` bounds the deviation from below (a very regular
  link would otherwise make every small delay suspect) and `pause` is added to
  the mean (the delay that is expected and acceptable).
  """
  @spec phi(t, integer, pos_integer, non_neg_integer) :: float
  def phi(%__MODULE__{count: count, sum: sum, sum_sq: sum_sq} = phi, now, min_std, pause) do
    mean = sum / count
    std = max(:math.sqrt(max(sum_sq / count - mean * mean, 0.0)), min_std)
    y = max((elapsed(phi, now) - (mean + pause)) / std, @min_y)
    e = :math.exp(-y * (1.5976 + 0.070566 * y * y))
    p = if y > 0, do: e / (1.0 + e), else: 1.0 - 1.0 / (1.0 + e)
    min(max(-:math.log10(max(p, 1.0e-300)), 0.0), @max_phi)
  end

  defp add(%__MODULE__{} = phi, interval) do
    phi = %{
      phi
      | intervals: :queue.in(interval, phi.intervals),
        count: phi.count + 1,
        sum: phi.sum + interval,
        sum_sq: phi.sum_sq + interval * interval
    }

    if phi.count > phi.size do
      {{:value, old}, rest} = :queue.out(phi.intervals)
      %{phi | intervals: rest, count: phi.count - 1, sum: phi.sum - old, sum_sq: phi.sum_sq - old * old}
    else
      phi
    end
  end
end
