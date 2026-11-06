defmodule Atanor.Cluster.RollingRestartTest do
  @moduledoc """
  A rolling restart (design §2.1, §8.11): the nodes stop gracefully and start
  again one after another under continuous load through the others. A node
  joins the cluster only after it applied the active deployments, so no
  request is sent to a node that cannot serve it.

  Required of the clients, in every phase, the stop of each node included
  (its peers keep sending idempotent calls to it while it hands its cells off):

    * GET (idempotent): no error, whatever the cell is.
    * POST: 200, or 503 for a call that did not run or whose outcome is
      unknown. Never `owner_unreachable`, the answer for a node that has not
      applied the worker, and never another status.

  And of every node: `/health/ready` says 503 while it loads and then 200, and
  no cell wakes on it before its deployments are loaded.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Manifests, Rolling}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 240_000

  test "restarting every node under load answers no GET with an error and routes nothing to a node before it is ready" do
    cluster = start_cluster(names: [:n1, :n2, :n3], workers: [Manifests.counter("counter")])
    old = for i <- 1..30, do: "old#{i}"
    for cell <- old, do: {200, _} = write(cluster, :n1, cell, 0)

    outcomes =
      for leaving <- [:n1, :n2, :n3] do
        load = Rolling.start_load(cluster, leaving, old)
        Process.sleep(500)
        %{health: health, started: started} = Rolling.restart(cluster, leaving)

        # The node serves: it takes cells again.
        Rolling.serving(cluster, leaving)
        Process.sleep(500)
        results = Rolling.stop_load(load)

        # Not ready, then ready.
        assert 503 in health and List.last(health) == 200, "health of #{leaving}: #{inspect(health)}"

        events = Cluster.events(cluster)

        [loaded] =
          for e <- events, e.event == [:atanor, :deployments, :loaded], e.node == leaving, e.at > started, do: e

        [ready] = for e <- events, e.event == [:atanor, :node, :ready], e.node == leaving, e.at > started, do: e
        assert loaded.at < ready.at

        woken =
          for e <- events,
              e.event == [:alambique, :cell, :wake],
              e.node == leaving,
              e.at > started,
              e.at < loaded.at,
              do: e

        assert length(results) > 100, "the load through the others of #{leaving} was too small"

        {Enum.map(results, &elem(&1, 0)), Enum.map(woken, &{leaving, &1.meta[:cell]})}
      end

    results = Enum.flat_map(outcomes, &elem(&1, 0))
    woken = Enum.flat_map(outcomes, &elem(&1, 1))
    IO.puts("rolling restart: #{length(results)} requests, #{inspect(Enum.frequencies(results))}")

    assert {[], []} = Rolling.failures(results)

    assert woken == [], "cells woke on a node before it applied its deployments: #{inspect(woken)}"
  end
end
