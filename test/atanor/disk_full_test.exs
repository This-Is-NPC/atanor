defmodule Atanor.DiskFullTest do
  @moduledoc """
  A write that SQLite refuses because the disk is full is a 503 `overloaded`, never a 500 (design §4.4).
  The full disk is injected with `PRAGMA max_page_count`, which makes SQLite fail the write that needs
  another page with the same `SQLITE_FULL` that an `ENOSPC` on the database or the WAL gives.
  """
  use ExUnit.Case, async: true

  alias Atanor.Test.{CounterWorker, Manifests}
  alias AtanorTestkit.Node

  @moduletag :tmp_dir

  @tag timeout: 180_000
  test "a write that finds the disk full is a 503 overloaded with Retry-After" do
    migrations = CounterWorker.migrations() ++ [[2, "PRAGMA max_page_count = 3"]]
    node = Node.start(workers: [Manifests.counter("w", cells: %{"log" => migrations})])
    on_exit(fn -> Node.stop(node) end)

    # Writes go on until one is refused for the full disk. Under CPU load a write can also be refused
    # before it ran (`queue_timeout`) or time out in flight (`unknown_outcome`): neither says anything
    # about the disk, so the loop goes on past them.
    answers = write_until_disk_full(node, [], System.monotonic_time(:millisecond) + 120_000)

    assert {200, _, _} = Enum.find(answers, &(elem(&1, 0) == 200))
    refute Enum.any?(answers, &(elem(&1, 0) == 500))
    assert {503, ["1"], %{"error" => "overloaded"}} = List.last(answers)
  end

  defp write_until_disk_full(node, answers, deadline) do
    %{status: status, headers: headers, body: body} = Req.post!(node.url <> "/c/full", body: "1", retry: false)
    answers = [{status, headers["retry-after"], body} | answers]

    cond do
      disk_full?(status, body) -> Enum.reverse(answers)
      System.monotonic_time(:millisecond) > deadline -> flunk("the disk never filled: #{inspect(hd(answers))}")
      true -> write_until_disk_full(node, answers, deadline)
    end
  end

  # The disk-full refusal names the gate `overloaded`; the others carry their own reason.
  defp disk_full?(503, %{"error" => "overloaded", "reason" => "overloaded"}), do: true
  defp disk_full?(_status, _body), do: false
end
