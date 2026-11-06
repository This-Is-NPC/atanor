# Failure detection between peer nodes (design §12.7).
#
#   mise run bench:detector        # 3 repetitions of each case
#   mise run bench:detector -- 5
#
# Three peer nodes on this machine over one in-memory store, a counter worker,
# lease ttl 5 s and the default detector settings. Each case wakes a cell on
# the victim, then breaks the victim and times, from the moment of the fault,
# when a survivor marks it down and when a write to the cell succeeds through
# a survivor. "No takeover" turns off the early takeover (the cell then waits
# for its lease); "no detector" sets phi_threshold so high that phi never fires:
# forwarded calls then wait for the distribution ticker (net_ticktime, 60 s).
# The graceful stop is also measured under load, and the heartbeat cost on an
# idle cluster of 3 and of 6 nodes.

Code.put_compiler_option(:ignore_module_conflict, true)

defmodule Bench do
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Cluster

  @ttl_ms 5_000
  @skew_ms 1_000

  def run(repetitions) do
    IO.puts("machine: #{System.schedulers_online()} schedulers, lease ttl #{@ttl_ms} ms, skew margin #{@skew_ms} ms\n")
    IO.puts("case                          detector     down (ms)   served again (ms)")

    for {label, fault, detector} <- [
          {"SIGKILL", :sigkill, :default},
          {"SIGSTOP", :sigstop, :default},
          {"platform hint (SIGSTOP)", :hint, :default},
          {"graceful stop", :graceful, :default},
          {"SIGSTOP", :sigstop, :no_takeover},
          {"SIGSTOP", :sigstop, :off}
        ],
        _ <- 1..repetitions do
      {down, served} = scenario(fault, detector)

      IO.puts(
        String.pad_trailing(label, 30) <>
          String.pad_trailing(to_string(detector), 13) <> String.pad_trailing(to_string(down), 12) <> to_string(served)
      )
    end

    IO.puts("\ngraceful stop under load (GET and POST through the two other nodes, 60 cells)")
    for _ <- 1..repetitions, do: IO.puts(graceful())

    IO.puts("\nheartbeat cost, idle cluster, default interval (1 s)")
    for nodes <- [3, 6], do: IO.puts(cost(nodes))
  end

  defp start(detector, names) do
    opts =
      case detector do
        :off -> [detector: [phi_threshold: 1_000_000]]
        :no_takeover -> [takeover: [enabled: false]]
        # Heartbeats so rare that they do not count: the rest of the cluster's traffic.
        :silent -> [detector: [interval_ms: 3_600_000]]
        :default -> []
      end

    {:ok, cluster} =
      Cluster.start_link(
        names: names,
        ttl_ms: @ttl_ms,
        skew_margin_ms: @skew_ms,
        atanor: opts,
        workers: [Manifests.counter("counter")]
      )

    cluster
  end

  defp scenario(fault, detector) do
    cluster = start(detector, [:n1, :n2, :n3])

    try do
      # The detector discovers its peers within a tick.
      Process.sleep(2_500)
      {cell, victim} = owned_cell(cluster)
      survivor = Enum.find(Cluster.names(cluster), &(&1 not in [victim]))
      t0 = System.os_time(:microsecond)
      inject(cluster, fault, victim, survivor)
      down = await_down(cluster, survivor, victim, t0)
      {down, served(cluster, survivor, cell, t0)}
    after
      Process.unlink(cluster)
      Cluster.stop(cluster)
    end
  end

  defp inject(cluster, :sigkill, victim, _), do: Cluster.kill_process(cluster, victim)
  defp inject(cluster, :sigstop, victim, _), do: Cluster.pause(cluster, victim)

  defp inject(cluster, :hint, victim, survivor) do
    Cluster.pause(cluster, victim)
    url = Cluster.admin_url(cluster, survivor) <> "/nodes/#{Cluster.node(cluster, victim)}/gone"
    Req.post!(url, headers: [{"authorization", "Bearer " <> Cluster.admin_token()}], retry: false)
  end

  defp inject(cluster, :graceful, victim, _),
    do: Cluster.call(cluster, victim, Supervisor, :stop, [Module.concat(Cluster.instance(cluster), Supervisor)])

  # Without a detector nobody marks the node down: report the time to the first sign, or "-".
  defp await_down(cluster, survivor, victim, t0) do
    node = Cluster.node(cluster, victim)
    deadline = System.monotonic_time(:millisecond) + 20_000

    Enum.find_value(Stream.repeatedly(fn -> Process.sleep(20) end), "-", fn _ ->
      event =
        Enum.find(
          Cluster.events(cluster),
          &(&1.node == survivor and &1.event == [:atanor, :node, :down] and &1.meta.node == node)
        )

      cond do
        event -> div(event.at - t0, 1_000)
        System.monotonic_time(:millisecond) > deadline -> "-"
        true -> nil
      end
    end)
  end

  defp served(cluster, via, cell, t0) do
    Enum.find_value(Stream.repeatedly(fn -> Process.sleep(50) end), fn _ ->
      case Req.post(Cluster.url(cluster, via) <> "/c/#{cell}",
             body: "#{System.unique_integer([:positive])}",
             retry: false,
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200}} -> div(System.os_time(:microsecond) - t0, 1_000)
        _ -> nil
      end
    end)
  end

  defp owned_cell(cluster) do
    Enum.find_value(1..40, fn i ->
      cell = "b#{i}"
      {:ok, %{status: 200}} = Req.post(Cluster.url(cluster, :n1) <> "/c/#{cell}", body: "0", retry: false)

      {:ok, {:ok, node}} =
        Cluster.call(cluster, :n1, Alambique, :owner, [Module.concat(Cluster.instance(cluster), Cells), "log." <> cell])

      name = Enum.find(Cluster.names(cluster), &(Cluster.node(cluster, &1) == node))
      if name != :n1, do: {cell, name}
    end)
  end

  # One node stops while clients keep sending GET and POST through the others.
  defp graceful do
    cluster = start(:default, [:n1, :n2, :n3])

    try do
      Process.sleep(2_500)
      cells = for i <- 1..60, do: "g#{i}"
      for cell <- cells, do: post(cluster, cell)
      mine = for cell <- cells, owner(cluster, cell) == :n2, do: cell
      stop_at = System.monotonic_time(:millisecond) + 5_000

      loaders =
        for via <- [:n1, :n3], kind <- [:get, :post] do
          Task.async(fn -> load(cluster, via, kind, mine, stop_at) end)
        end

      Process.sleep(1_000)
      t0 = System.monotonic_time(:millisecond)
      supervisor = Module.concat(Cluster.instance(cluster), Supervisor)
      {:ok, :ok} = Cluster.call(cluster, :n2, Supervisor, :stop, [supervisor])
      took = System.monotonic_time(:millisecond) - t0
      [g1, p1, g3, p3] = Task.await_many(loaders, 30_000)
      errors = fn list -> Enum.count(list, &(&1 != 200)) end

      drain =
        Enum.find(Cluster.events(cluster), &(&1.event == [:atanor, :node, :drain]))

      "n2 owned #{length(mine)} cells, stop took #{took} ms (drain #{div(drain.measurements.duration, 1_000_000)} ms, " <>
        "#{drain.measurements.hibernated} hibernated, #{drain.measurements.errors} errors); " <>
        "GET #{length(g1 ++ g3)} requests, #{errors.(g1 ++ g3)} errors; POST #{length(p1 ++ p3)} requests, #{errors.(p1 ++ p3)} errors"
    after
      Process.unlink(cluster)
      Cluster.stop(cluster)
    end
  end

  defp post(cluster, cell) do
    Req.post(Cluster.url(cluster, :n1) <> "/c/#{cell}", body: "0", retry: false)
  end

  defp owner(cluster, cell) do
    {:ok, {:ok, node}} =
      Cluster.call(cluster, :n1, Alambique, :owner, [Module.concat(Cluster.instance(cluster), Cells), "log." <> cell])

    Enum.find(Cluster.names(cluster), &(Cluster.node(cluster, &1) == node))
  end

  defp load(cluster, via, kind, cells, stop_at) do
    url = Cluster.url(cluster, via)

    Stream.repeatedly(fn -> Enum.random(cells) end)
    |> Enum.reduce_while([], fn cell, acc ->
      if System.monotonic_time(:millisecond) > stop_at do
        {:halt, acc}
      else
        result =
          case kind do
            :get -> Req.get(url <> "/c/#{cell}", retry: false)
            :post -> Req.post(url <> "/c/#{cell}", body: "#{System.unique_integer([:positive])}", retry: false)
          end

        Process.sleep(10)
        {:cont, [(match?({:ok, _}, result) && elem(result, 1).status) || :error | acc]}
      end
    end)
  end

  # What the detector adds per node on an idle cluster: the difference in
  # packets and bytes sent over the distribution sockets between the default
  # interval and one that never fires, and the detector process's reductions.
  defp cost(count) do
    names = for i <- 1..count, do: :"n#{i}"
    with_detector = idle(:default, names)
    without = idle(:silent, names)
    diff = fn key -> with_detector[key] - without[key] end

    "#{count} nodes (#{count - 1} peers): +#{Float.round(diff.(:send_cnt), 1)} packets/s, +#{round(diff.(:send_oct))} bytes/s sent per node, " <>
      "detector process #{round(with_detector.detector_reductions)} reductions/s"
  end

  defp idle(detector, names) do
    cluster = start(detector, names)

    try do
      Process.sleep(3_000)
      :ok = load_stats(cluster)
      before = Map.new(names, &{&1, stats(cluster, &1)})
      Process.sleep(20_000)
      after_ = Map.new(names, &{&1, stats(cluster, &1)})
      average = fn key -> Enum.sum(for n <- names, do: (after_[n][key] - before[n][key]) / 20) / length(names) end
      Map.new([:send_cnt, :send_oct, :detector_reductions], &{&1, average.(&1)})
    after
      Process.unlink(cluster)
      Cluster.stop(cluster)
    end
  end

  defp load_stats(cluster) do
    [{mod, bin}] =
      Code.compile_string("""
      defmodule Atanor.Bench.Stats do
        def read(detector, test_node) do
          sockets = for {node, ctrl} <- :erlang.system_info(:dist_ctrl), node != test_node, is_port(ctrl), do: ctrl
          io = for p <- sockets, {:ok, s} <- [:inet.getstat(p, [:send_cnt, :send_oct])], do: s
          {:reductions, detector_reductions} = Process.info(Process.whereis(detector), :reductions)

          %{
            send_cnt: io |> Enum.map(& &1[:send_cnt]) |> Enum.sum(),
            send_oct: io |> Enum.map(& &1[:send_oct]) |> Enum.sum(),
            reductions: elem(:erlang.statistics(:reductions), 0),
            detector_reductions: detector_reductions
          }
        end
      end
      """)

    for name <- Cluster.names(cluster),
        do: {:module, ^mod} = :erpc.call(Cluster.node(cluster, name), :code, :load_binary, [mod, ~c"bench", bin])

    :ok
  end

  defp stats(cluster, name) do
    {:ok, stats} =
      Cluster.call(cluster, name, Atanor.Bench.Stats, :read, [
        Module.concat(Cluster.instance(cluster), Detector),
        node()
      ])

    stats
  end
end

Bench.run(
  case System.argv() do
    [n] -> String.to_integer(n)
    _ -> 3
  end
)
