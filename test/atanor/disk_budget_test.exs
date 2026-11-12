defmodule Atanor.DiskBudgetTest do
  @moduledoc """
  A node with a small disk budget keeps `data_dir` under it while 20 awake cells take continuous writes
  (design §4.4). Without the budget the `-wal` of each awake cell grows to Alambique's 64 MiB checkpoint
  mark, so the files pass any disk.
  """
  use ExUnit.Case, async: false

  alias Atanor.Disk
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Node

  @moduletag :tmp_dir
  @mib 1_048_576
  @cells 20
  @loops 12
  @run_ms 8_000
  # A sample is up to `sample_ms` old, and a write in flight lands after the verdict.
  @margin 0.15

  defp start(opts) do
    node = Node.start([workers: [Manifests.counter("w")], alambique: [awake: [max_cells: @cells]]] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  # `@loops` writers post to the cells in turn until the deadline; the test process samples the use of
  # `data_dir` meanwhile. Returns the statuses by count and the highest use.
  defp write_for(node, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    writers = for loop <- 1..@loops, do: Task.async(fn -> writer(node, loop, deadline, %{}, 0) end)
    peak = watch(node, deadline, 0)

    statuses =
      writers
      |> Task.await_many(30_000)
      |> Enum.reduce(%{}, &Map.merge(&1, &2, fn _, a, b -> a + b end))

    {statuses, peak}
  end

  defp writer(node, loop, deadline, statuses, n) do
    if System.monotonic_time(:millisecond) >= deadline do
      statuses
    else
      cell = "c#{rem(loop + n, @cells)}"

      status =
        case Req.post(node.url <> "/c/#{cell}", body: "1", retry: false, receive_timeout: 20_000) do
          {:ok, %{status: status}} -> status
          {:error, _} -> :error
        end

      writer(node, loop, deadline, Map.update(statuses, status, 1, &(&1 + 1)), n + 1)
    end
  end

  defp watch(node, deadline, peak) do
    {used, _} = Disk.usage(node.data_dir)
    Process.sleep(50)

    if System.monotonic_time(:millisecond) >= deadline,
      do: max(peak, used),
      else: watch(node, deadline, max(peak, used))
  end

  # The checkpoint mark alone (1 MiB of WAL per cell, 20 MiB) keeps 20 cells within this budget.
  test "20 cells under continuous writes stay within the budget, and answer 200 or 503, never 500" do
    budget = 32 * @mib
    node = start(disk: [max_bytes: budget, sample_ms: 20])

    {statuses, peak} = write_for(node, @run_ms)

    assert Map.keys(statuses) -- [200, 503] == [], "statuses: #{inspect(statuses)}"
    assert statuses[200] > 0
    assert peak <= budget * (1 + @margin), "peak #{peak} bytes against a budget of #{budget}: #{inspect(statuses)}"
  end

  # The WAL marks of 20 cells (20 MiB) do not fit in 16 MiB: the monitor hibernates idle cells at 70% and the
  # ingress refuses at 95%.
  test "a budget below the WAL marks is held by the monitor" do
    budget = 16 * @mib
    node = start(disk: [max_bytes: budget, sample_ms: 20])
    test = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(handler, [:atanor, :disk, :reclaim], &__MODULE__.reclaimed/4, test)

    on_exit(fn -> :telemetry.detach(handler) end)

    {statuses, peak} = write_for(node, @run_ms)

    assert Map.keys(statuses) -- [200, 503] == [], "statuses: #{inspect(statuses)}"
    assert statuses[200] > 0
    assert peak <= budget * (1 + @margin), "peak #{peak} bytes against a budget of #{budget}: #{inspect(statuses)}"
    assert hibernated(node.name, 0) > 0
  end

  def reclaimed(_event, measures, %{instance: name}, test), do: send(test, {:reclaim, name, measures})

  defp hibernated(name, total) do
    receive do
      {:reclaim, ^name, %{hibernated: n}} -> hibernated(name, total + n)
    after
      0 -> total
    end
  end

  test "the node answers again once the writes stop" do
    node = start(disk: [max_bytes: 12 * @mib, sample_ms: 100])
    write_for(node, 3_000)

    Await.until(fn -> match?({_, :ok}, Disk.status(node.name)) end, 15_000)
    assert %{status: 200} = Req.post!(node.url <> "/c/c0", body: "1", retry: false)
  end
end
