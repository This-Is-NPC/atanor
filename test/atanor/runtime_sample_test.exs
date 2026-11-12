defmodule Atanor.RuntimeSampleTest do
  use ExUnit.Case, async: true

  alias Atanor.RuntimeSample

  test "the top processes are filled past processes that died after the scan" do
    pids = for _ <- 1..15, do: spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)

    # The scan saw the first five with the largest queues; they die before the lookup.
    infos = for {pid, rank} <- Enum.with_index(pids), do: {pid, %{message_queue_len: 100 - rank, memory: 1}}
    dead = Enum.take(pids, 5)

    for pid <- dead do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
    end

    top = RuntimeSample.top(infos, :message_queue_len)
    assert length(top) == 10
    assert Enum.all?(top, &(&1.pid not in Enum.map(dead, fn pid -> inspect(pid) end)))
  end
end
