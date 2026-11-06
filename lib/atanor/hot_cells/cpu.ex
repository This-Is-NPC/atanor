defmodule Atanor.HotCells.Cpu do
  @moduledoc false
  # How busy the node is, from 0 to 100, as the larger of two views:
  #
  #   * the VM's schedulers: the busy time of the normal and dirty CPU schedulers between two samples, as a share
  #     of the normal schedulers (one core each). A busy dirty scheduler counts, since Alambique runs SQLite
  #     there. Dirty IO schedulers wait on disks and are left out;
  #   * the machine, where `/proc/stat` exists (Linux): the share of the time all its CPUs were busy, which sees
  #     what the VM does not, such as another process taking the cores or a hypervisor taking them back.
  #
  # The first alone missed a node whose cores were taken by other processes: its schedulers looked as idle as before.

  @type sample :: %{
          schedulers: [{pos_integer, non_neg_integer, non_neg_integer}],
          os: {non_neg_integer, non_neg_integer} | nil
        }
  @type usage :: %{cpu: float, scheduler: float, os: float | nil}

  @doc "Turns on the wall time accounting of the VM (a few percent of a scheduler's overhead; global)."
  @spec enable :: :ok
  def enable do
    :erlang.system_flag(:scheduler_wall_time, true)
    :ok
  end

  @doc "A sample; the machine's is left out with `os?` false (`hot_cells: [os_cpu: false]`)."
  @spec sample(boolean) :: sample
  def sample(os?) do
    %{schedulers: :scheduler_wall_time_all |> :erlang.statistics() |> Enum.sort(), os: os? && os_sample("/proc/stat")}
  end

  @doc "The use between two samples, with the schedulers counted by `{normal, dirty_cpu}`."
  @spec utilization(sample, sample, {pos_integer, non_neg_integer}) :: usage
  def utilization(previous, current, {normal, dirty_cpu}) do
    scheduler = scheduler_use(previous.schedulers, current.schedulers, normal, dirty_cpu)
    os = os_use(previous.os, current.os)
    %{cpu: max(scheduler, os || 0.0), scheduler: scheduler, os: os}
  end

  defp scheduler_use(previous, current, normal, dirty_cpu) do
    busy =
      for {{id, active0, total0}, {id, active1, total1}} <- Enum.zip(previous, current),
          id <= normal + dirty_cpu,
          total1 > total0,
          reduce: 0.0 do
        busy -> busy + (active1 - active0) / (total1 - total0)
      end

    min(100.0, 100.0 * busy / normal)
  end

  defp os_use({busy0, total0}, {busy1, total1}) when total1 > total0, do: 100.0 * (busy1 - busy0) / (total1 - total0)
  defp os_use(_, _), do: nil

  defp os_sample(path) do
    with {:ok, text} <- File.read(path), [line | _] <- String.split(text, "\n"), do: parse_stat(line)
  end

  @doc false
  # The first line of `/proc/stat`: user nice system idle iowait irq softirq steal ... in clock ticks. Steal counts
  # as busy: the cores were taken from this machine.
  @spec parse_stat(String.t()) :: {non_neg_integer, non_neg_integer} | nil
  def parse_stat("cpu " <> rest) do
    case rest |> String.split(" ", trim: true) |> Enum.take(8) |> Enum.map(&Integer.parse/1) do
      [{user, _}, {nice, _}, {system, _}, {idle, _}, {iowait, _}, {irq, _}, {softirq, _}, {steal, _}] ->
        {user + nice + system + irq + softirq + steal, user + nice + system + idle + iowait + irq + softirq + steal}

      _ ->
        nil
    end
  end

  def parse_stat(_), do: nil

  @doc "The number of normal and dirty CPU schedulers of this VM."
  @spec schedulers :: {pos_integer, non_neg_integer}
  def schedulers, do: {:erlang.system_info(:schedulers), :erlang.system_info(:dirty_cpu_schedulers)}
end
