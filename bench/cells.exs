# Thousands of cells on one node, through Atanor (design §12.3).
#
#   mise run bench:cells            # 5 000 cells
#   mise run bench:cells -- 20000   # another count
#   mise run bench:cells -- 20000 120   # and an idle timeout in seconds
#
# Wakes N cells with one HTTP request each (a counter worker appends a row),
# then sends the same requests again to the awake cells, then waits for the
# idle timeout (20 s unless given) to put them to sleep. A wake that takes
# longer than the timeout finds cells asleep again, so give a longer one. Same method as Alambique's own
# `mise run bench:cells` (in the alambique repository), which wakes cells with
# `Alambique.execute/5` directly, so the difference is Atanor's cost: the HTTP
# layer, routing and the namespace check.

Code.require_file("load.exs", __DIR__)

defmodule Bench do
  alias Atanor.Bench.Load
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @clients 256

  def run(count, idle_ms) do
    dir = Path.join(System.tmp_dir!(), "atanor-bench-cells-#{System.unique_integer([:positive])}")
    node = Node.start(data_dir: dir, alambique: [idle_timeout_ms: idle_ms, lease_ttl_ms: 60_000])

    try do
      {:ok, _} = Node.deploy(node, Manifests.counter("counter"))
      cells = Module.concat(node.name, Cells)
      IO.puts("machine: #{Load.machine()}\ncells: #{count}, #{@clients} clients, one request each\n")

      baseline = snapshot("baseline", cells)
      request = fn i -> {"POST", "/c/cell-#{i}", [], "#{i}"} end

      {cpu0, _} = :erlang.statistics(:runtime)
      cold = Load.run(node.port, @clients, {:requests, count}, request)
      {cpu1, _} = :erlang.statistics(:runtime)
      awake = snapshot("awake", cells)

      warm = Load.run(node.port, @clients, {:requests, count}, request)

      await_hibernation(cells)
      asleep = snapshot("asleep", cells)

      IO.puts(Load.row("wake #{count} cells (cold)", cold))
      IO.puts("wake rate: #{round(count / cold.seconds)} cells/s, cpu #{Float.round((cpu1 - cpu0) / 1000, 2)} s in all threads")
      IO.puts(Load.row("second pass (cells awake)", warm))
      IO.puts("\nphase      awake cells  processes  open fds  BEAM MB  RSS MB")

      for s <- [baseline, awake, asleep],
          do: IO.puts(:io_lib.format("~-10s ~11B  ~9B  ~8B  ~7.1f  ~6.1f", [s.label, s.awake, s.processes, s.fds, s.beam_mb, s.rss_mb]))

      IO.puts("\nper awake cell: #{Float.round((awake.beam_mb - baseline.beam_mb) * 1024 / max(awake.awake, 1), 1)} KB of BEAM memory, " <>
                "#{Float.round((awake.rss_mb - baseline.rss_mb) * 1024 / max(awake.awake, 1), 1)} KB of RSS")
    after
      Node.stop(node)
    end
  end

  defp await_hibernation(cells) do
    if awake(cells) > 0 do
      Process.sleep(500)
      await_hibernation(cells)
    end
  end

  defp awake(cells), do: Alambique.cells(cells, limit: 1).count

  defp snapshot(label, cells) do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)

    %{
      label: label,
      awake: awake(cells),
      processes: :erlang.system_info(:process_count),
      fds: length(File.ls!("/proc/self/fd")),
      beam_mb: :erlang.memory(:total) / 1_048_576,
      rss_mb: rss_kb() / 1024
    }
  end

  defp rss_kb do
    [_, kb] = Regex.run(~r/VmRSS:\s+(\d+) kB/, File.read!("/proc/self/status"))
    String.to_integer(kb)
  end
end

{count, idle_s} =
  case System.argv() do
    [count, idle_s | _] -> {count, idle_s}
    [count] -> {count, "20"}
    [] -> {"5000", "20"}
  end

Bench.run(String.to_integer(count), String.to_integer(idle_s) * 1000)
