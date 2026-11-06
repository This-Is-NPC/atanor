defmodule Atanor.Cluster.JobsTest do
  @moduledoc """
  Jobs across nodes (design §7.5, §8): a job runs on the owner of its cell,
  survives the loss of that owner with the same idempotency key, and a sweep's
  driver is taken over after a node loss without losing or duplicating cells.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.{Cell, Jobs, Sweeps}
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 600_000

  @names [:n1, :n2, :n3]

  defp start(opts \\ []) do
    atanor =
      [
        alarms: [tick_ms: 100, timeout_ms: 1_000, max_attempts: 5],
        jobs: [
          claim_ms: 2_000,
          timeout_ms: 1_000,
          backoff_ms: 100,
          max_backoff_ms: 100,
          concurrency: 8,
          worker_concurrency: 8,
          cell_concurrency: 1
        ],
        sweeps: [
          poll_ms: 100,
          lease_ttl_ms: 3_000,
          renew_ms: 500,
          cell_timeout_ms: 2_000,
          page_size: 5,
          rate_per_s: 100,
          concurrency: 4,
          max_active: 2,
          cell_attempts: 2,
          retry_ms: 100,
          canary_window_ms: 500,
          canary_timeout_ms: 5_000,
          guard_poll_ms: 100
        ],
        poll_interval_ms: 200
      ] ++ Keyword.get(opts, :atanor, [])

    start_cluster(
      [
        names: @names,
        ttl_ms: 3_000,
        skew_margin_ms: 400,
        workers: [Manifests.jobs("jobs")],
        atanor: atanor
      ] ++ Keyword.delete(opts, :atanor)
    )
  end

  defp wake(cluster, key) do
    Await.until(fn ->
      match?({:ok, _}, Cluster.call(cluster, :n1, Cell, :query, [Cluster.instance(cluster), {"jobs", key}, "SELECT 1"]))
    end)
  end

  defp enqueue(cluster, via, key, payload) do
    Cluster.call(cluster, via, Jobs, :enqueue_direct, [
      Cluster.instance(cluster),
      "jobs",
      {"jobs", key},
      %{kind: "test", payload: payload}
    ])
  end

  defp rows(cluster, via, key, sql, params \\ []) do
    case Cluster.call(cluster, via, Cell, :query, [Cluster.instance(cluster), {"jobs", key}, sql, params]) do
      {:ok, {:ok, %{rows: rows}}} -> rows
      _ -> nil
    end
  end

  defp effects(cluster, via, key),
    do: (rows(cluster, via, key, "SELECT payload FROM effects ORDER BY job_id") || []) |> List.flatten()

  test "a job runs on the cell owner and a lost owner retries it with one effect" do
    cluster = start()
    key = "takeover"
    wake(cluster, key)
    {:ok, owner} = owner(cluster, :n1, "jobs", key)
    victim = name_of(cluster, owner)
    [survivor | _] = @names -- [victim]

    assert {:ok, {:ok, id}} = enqueue(cluster, survivor, key, "slow")
    Await.until(fn -> rows(cluster, survivor, key, "SELECT count(*) FROM runs") == [[1]] end, 20_000)

    Cluster.kill(cluster, victim)
    Await.until(fn -> effects(cluster, survivor, key) == ["slow"] end, 60_000)
    Await.until(fn -> length(rows(cluster, survivor, key, "SELECT id FROM runs")) >= 2 end, 60_000)

    assert effects(cluster, survivor, key) == ["slow"]
    assert [[^id]] = rows(cluster, survivor, key, "SELECT job_id FROM effects")
    assert length(rows(cluster, survivor, key, "SELECT id FROM runs")) >= 2
  end

  test "a sweep driver is taken over after its node dies and every cell is dispatched once" do
    cluster = start()
    keys = for i <- 1..24, do: "s#{i}"
    for key <- keys, do: wake(cluster, key)

    {:ok, {:ok, op}} =
      Cluster.call(cluster, :n1, Sweeps, :start, [
        Cluster.instance(cluster),
        %{
          "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
          "action" => %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("swept")},
          "rate_per_s" => 1,
          "concurrency" => 2,
          "page_size" => 4
        }
      ])

    Await.until(fn -> sweep_get(cluster, op["id"])["driver"] != nil end, 20_000)

    record = sweep_get(cluster, op["id"])
    driver = peer_of(cluster, record["driver"])
    Cluster.kill(cluster, driver)
    [survivor | _] = @names -- [driver]

    Await.until(fn -> sweep_get(cluster, op["id"])["state"] == "done" end, 60_000)

    for key <- keys do
      Await.until(fn -> effects(cluster, survivor, key) == ["swept"] end, 60_000)

      # The handler writes its effect before the attempt is marked done, so the state is waited for too.
      Await.until(
        fn ->
          rows(cluster, survivor, key, "SELECT state FROM _atanor_jobs WHERE operation_id = ?", [op["id"]]) ==
            [["done"]]
        end,
        60_000
      )

      assert [[1]] =
               rows(cluster, survivor, key, "SELECT count(*) FROM _atanor_jobs WHERE operation_id = ?", [op["id"]])
    end

    final = sweep_get(cluster, op["id"])
    assert final["counters"]["dispatched"] + final["counters"]["skipped"] == 24
  end

  defp peer_of(cluster, node_string),
    do: Enum.find(@names, &(Atom.to_string(Cluster.node(cluster, &1)) == node_string))

  defp sweep_get(cluster, id) do
    Enum.find_value(@names, fn peer ->
      case Cluster.call(cluster, peer, Sweeps, :get, [Cluster.instance(cluster), id]) do
        {:ok, {:ok, record, _etag}} -> record
        _ -> nil
      end
    end)
  end
end
