defmodule Atanor.Cluster.FeedTest do
  @moduledoc "The change feed is in the store, so a write on one node reaches a subscriber on another."
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Change
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  test "a write on one node reaches a subscriber on another" do
    cluster =
      start_cluster(
        workers: [Manifests.probe("feed", cells: %{"notes" => Manifests.notes_migrations()})],
        skew_margin_ms: 0,
        op_timeout_ms: 10,
        atanor: [
          feed: [poll_ms: 50, page_size: 100, retry_ms: 20, max_backoff_ms: 100],
          alambique: [feed: [window_ms: 1, linger_ms: 0]]
        ]
      )

    instance = Cluster.instance(cluster)
    test_pid = self()
    started = System.monotonic_time(:millisecond)

    {:ok, _pid} =
      Cluster.call(cluster, :n2, Atanor.Test.FeedSubscriber, :start, [instance, "feed", "notes", test_pid])

    assert_receive {:feed_subscribed, _pid, _ref}, 5_000

    {:ok, _result} =
      Cluster.call(cluster, :n1, Atanor.Cell, :execute, [
        instance,
        {"notes", "a"},
        "INSERT INTO notes (body) VALUES (?)",
        ["hi"]
      ])

    assert_receive {:feed_changes, changes, position}, 10_000
    elapsed = System.monotonic_time(:millisecond) - started
    assert Enum.any?(changes, &match?(%Change{cell: "a", namespace: "notes"}, &1))
    assert is_binary(position)

    # poll_ms (50) + the Alambique settle time (window 1 + op_timeout 10) with slack.
    assert elapsed < 2_000
  end
end
