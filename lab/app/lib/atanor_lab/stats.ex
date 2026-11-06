defmodule AtanorLab.Stats do
  @moduledoc """
  Counters of the distribution sockets and of the detector, for the heartbeat cost (design §12.8), and of the
  bounded reads of this node by who answered: a local replica or the owner (design §19).
  """

  @counters {__MODULE__, :replica_reads}

  @doc false
  def replica_read(_event, _measurements, meta, _config) do
    ref = :persistent_term.get(@counters, nil) || start_counters()
    :counters.add(ref, if(meta.source == :replica, do: 1, else: 2), 1)
  end

  defp start_counters do
    ref = :counters.new(2, [:write_concurrency])
    :persistent_term.put(@counters, ref)
    ref
  end

  def read do
    io =
      for {_node, ctrl} <- :erlang.system_info(:dist_ctrl),
          is_port(ctrl),
          {:ok, s} <- [:inet.getstat(ctrl, [:send_cnt, :send_oct])],
          do: s

    {:reductions, reductions} =
      Process.info(Process.whereis(AtanorLab.Atanor.Detector), :reductions)

    replica_reads = :persistent_term.get(@counters, nil)

    %{
      replica_reads: replica_reads && :counters.get(replica_reads, 1),
      owner_reads: replica_reads && :counters.get(replica_reads, 2),
      send_cnt: io |> Enum.map(& &1[:send_cnt]) |> Enum.sum(),
      send_oct: io |> Enum.map(& &1[:send_oct]) |> Enum.sum(),
      detector_reductions: reductions
    }
  end
end
