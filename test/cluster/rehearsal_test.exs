defmodule Atanor.Cluster.RehearsalTest do
  @moduledoc """
  Migration rehearsals across nodes (design §17.3): the report lives in the
  store, so every node reads it; a node that dies leaves the record
  `running`, which then reads as `stale`; a store the node cannot reach never
  produces a report that looks complete.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 300_000

  @notes [[1, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"]]
  # Runs until the cell's time budget interrupts it.
  @spin "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000000000) SELECT count(*) FROM c"

  defp manifest(migrations),
    do: Manifests.probe("notes", cells: %{"notes" => migrations}, routes: [{"127.0.0.1", "/n"}])

  defp start do
    start_cluster(
      names: [:n1, :n2],
      ttl_ms: 3_000,
      skew_margin_ms: 400,
      workers: [manifest(@notes)],
      atanor: [rehearsal: [stale_ms: 4_000, timeout_ms: 2_000, concurrency: 1], poll_interval_ms: 200]
    )
  end

  # Cells with data, asleep in the store.
  defp seed(cluster, keys) do
    instance = Cluster.instance(cluster)

    for key <- keys do
      {:ok, {:ok, _}} =
        Cluster.call(cluster, :n1, Atanor.Cell, :execute, [
          instance,
          {"notes", key},
          "INSERT INTO notes (body) VALUES ('a')"
        ])

      {:ok, :ok} = Cluster.call(cluster, :n1, Alambique, :hibernate, [Module.concat(instance, Cells), "notes." <> key])
    end
  end

  defp candidate(cluster, extra) do
    {:ok, id} = Cluster.publish(cluster, manifest(@notes ++ [[2, extra]]))
    id
  end

  defp api(cluster, via, method, path, body \\ nil) do
    response =
      Req.request!(
        method: method,
        url: Cluster.admin_url(cluster, via) <> path,
        headers: [{"authorization", "Bearer " <> Cluster.admin_token()}, {"content-type", "application/json"}],
        body: body && Jason.encode!(body),
        retry: false,
        decode_body: false
      )

    {response.status, Jason.decode!(response.body)}
  end

  defp start_rehearsal(cluster, via, package),
    do: api(cluster, via, :post, "/rehearsals", %{"worker" => "notes", "id" => package})

  defp record(cluster, via, id) do
    {200, record} = api(cluster, via, :get, "/rehearsals/" <> id)
    record
  end

  test "another node reads the report from the store" do
    cluster = start()
    seed(cluster, ["a", "b"])

    assert {202, %{"id" => id}} =
             start_rehearsal(cluster, :n1, candidate(cluster, "ALTER TABLE notes ADD COLUMN tag TEXT"))

    report = Await.until(fn -> (r = record(cluster, :n2, id)) && r["state"] != "running" && r end, 60_000)

    assert %{"state" => "done", "node" => node, "summary" => %{"sampled" => 2, "ok" => 2}} = report
    assert node == Atom.to_string(Cluster.node(cluster, :n1))
    assert record(cluster, :n1, id) == report
    assert {200, %{"rehearsals" => [%{"id" => ^id}]}} = api(cluster, :n2, :get, "/rehearsals")
  end

  test "a node killed during a rehearsal leaves it running, then stale, and a new one can start" do
    cluster = start()
    seed(cluster, Enum.map(1..6, &"c#{&1}"))

    assert {202, %{"id" => id}} = start_rehearsal(cluster, :n1, candidate(cluster, @spin))
    Await.until(fn -> record(cluster, :n2, id)["progress"]["total"] == 6 end, 60_000)
    assert %{"state" => "running"} = record(cluster, :n2, id)

    :ok = Cluster.kill(cluster, :n1)

    assert %{"state" => "stale", "cells" => []} =
             Await.until(fn -> (r = record(cluster, :n2, id)) && r["state"] == "stale" && r end, 30_000)

    assert {409, %{"error" => "invalid_state"}} = api(cluster, :n2, :post, "/rehearsals/#{id}/cancel")

    assert {202, %{"id" => next}} =
             start_rehearsal(cluster, :n2, candidate(cluster, "ALTER TABLE notes ADD COLUMN tag TEXT"))

    assert %{"state" => "done"} =
             Await.until(fn -> (r = record(cluster, :n2, next)) && r["state"] != "running" && r end, 60_000)
  end

  test "a node cut off from the store never reports a rehearsal as done, and recovers when healed" do
    cluster = start()
    seed(cluster, ["a", "b", "c"])
    package = candidate(cluster, @spin)

    assert {202, %{"id" => id}} = start_rehearsal(cluster, :n1, package)
    :ok = Cluster.partition_store(cluster, :n1)

    assert {503, %{"error" => "store_unavailable"}} = start_rehearsal(cluster, :n1, package)
    assert {503, _} = api(cluster, :n1, :get, "/rehearsals/" <> id)

    stale = Await.until(fn -> (r = record(cluster, :n2, id)) && r["state"] == "stale" && r end, 60_000)
    assert stale["summary"] == nil

    :ok = Cluster.heal_store(cluster, :n1)

    # After the heal Alambique's store breaker stays open for its cool-down, and only a request that reaches the
    # store closes it. A rehearsal started before that fails at sampling with `store_unavailable`, so wait until
    # the listing that sampling makes answers.
    cells = Module.concat(Cluster.instance(cluster), Cells)

    Await.until(
      fn ->
        match?({:ok, {:ok, _}}, Cluster.call(cluster, :n1, Alambique, :list_cells, [cells, [prefix: "notes."]]))
      end,
      30_000
    )

    assert {202, %{"id" => next}} =
             start_rehearsal(cluster, :n1, candidate(cluster, "ALTER TABLE notes ADD COLUMN tag TEXT"))

    assert %{"state" => "done"} =
             Await.until(fn -> (r = record(cluster, :n1, next)) && r["state"] != "running" && r end, 60_000)
  end
end
