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

  test "a write that finds the disk full is a 503 overloaded with Retry-After" do
    migrations = CounterWorker.migrations() ++ [[2, "PRAGMA max_page_count = 3"]]
    node = Node.start(workers: [Manifests.counter("w", cells: %{"log" => migrations})])
    on_exit(fn -> Node.stop(node) end)

    statuses =
      for _ <- 1..1_500 do
        %{status: status, headers: headers, body: body} =
          Req.post!(node.url <> "/c/full", body: "1", retry: false)

        {status, headers["retry-after"], body}
      end

    assert {200, _, _} = hd(statuses)
    refused = Enum.filter(statuses, &(elem(&1, 0) != 200))
    assert refused != []
    assert Enum.all?(refused, &match?({503, ["1"], %{"error" => "overloaded"}}, &1))
  end
end
