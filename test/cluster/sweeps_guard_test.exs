defmodule Atanor.Cluster.SweepsGuardTest do
  @moduledoc """
  The canary and the error-rate guard of bulk operations across nodes
  (design §15.8): a canary window survives the loss of its driver, a halt is
  seen by every node and stops dispatching, and an unreadable window halts
  with `guard_unavailable` after `guard_attempts`.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.{Cell, Store, Sweeps}
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 600_000

  @names [:n1, :n2, :n3]

  defp start do
    start_cluster(
      names: @names,
      ttl_ms: 3_000,
      skew_margin_ms: 400,
      workers: [Manifests.jobs("jobs")],
      atanor: [
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
          retry_ms: 100
        ],
        poll_interval_ms: 200
      ]
    )
  end

  defp wake_all(cluster, keys) do
    for key <- keys do
      Await.until(fn ->
        match?(
          {:ok, {:ok, _}},
          Cluster.call(cluster, :n1, Cell, :query, [Cluster.instance(cluster), {"jobs", key}, "SELECT 1"])
        )
      end)
    end
  end

  defp operation(cluster, attrs) do
    base = %{
      "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
      "action" => %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("swept")}
    }

    {:ok, {:ok, op}} = Cluster.call(cluster, :n1, Sweeps, :start, [Cluster.instance(cluster), Map.merge(base, attrs)])
    op
  end

  defp failing do
    %{
      "action" => %{
        "worker" => "jobs",
        "kind" => "sweep",
        "payload_base64" => Base.encode64("fail"),
        "max_attempts" => 1
      }
    }
  end

  defp record(cluster, via, id) do
    case Cluster.call(cluster, via, Sweeps, :get, [Cluster.instance(cluster), id]) do
      {:ok, {:ok, record, _etag}} -> record
      _ -> nil
    end
  end

  defp job_rows(cluster, via, key, id) do
    case Cluster.call(cluster, via, Cell, :query, [
           Cluster.instance(cluster),
           {"jobs", key},
           "SELECT state FROM _atanor_jobs WHERE operation_id = ?",
           [id]
         ]) do
      {:ok, {:ok, %{rows: rows}}} -> rows
      _ -> nil
    end
  end

  defp peer_of(cluster, node_string),
    do: Enum.find(@names, &(Atom.to_string(Cluster.node(cluster, &1)) == node_string))

  test "the driver dies during the canary window and a survivor finishes the operation" do
    cluster = start()
    keys = for i <- 1..12, do: "k#{i}"
    wake_all(cluster, keys)
    op = operation(cluster, %{"canary_size" => 3, "canary_window_ms" => 6_000, "guard_poll_ms" => 200})

    Await.until(
      fn ->
        r = record(cluster, :n1, op["id"])
        r && r["driver"] != nil && r["canary"]["until_ms"] != nil
      end,
      30_000
    )

    waiting = record(cluster, :n1, op["id"])
    assert waiting["canary"]["dispatched"] == 3 and waiting["counters"]["dispatched"] == 3
    driver = peer_of(cluster, waiting["driver"])
    Cluster.kill(cluster, driver)
    [survivor | _] = @names -- [driver]

    Await.until(fn -> (record(cluster, survivor, op["id"]) || %{})["state"] == "done" end, 60_000)
    final = record(cluster, survivor, op["id"])
    assert final["canary"]["passed"] == true
    assert final["counters"]["dispatched"] + final["counters"]["skipped"] == 12

    for key <- keys do
      Await.until(fn -> job_rows(cluster, survivor, key, op["id"]) == [["done"]] end, 60_000)
    end
  end

  test "a halt on the driver is seen by the other nodes and stops dispatching" do
    cluster = start()
    keys = for i <- 1..40, do: "h#{i}"
    wake_all(cluster, keys)

    op =
      operation(
        cluster,
        Map.merge(failing(), %{
          "canary_size" => 0,
          "rate_per_s" => 20,
          "page_size" => 2,
          "guard_poll_ms" => 1,
          "guard_min_cells" => 2,
          "guard_window_cells" => 4
        })
      )

    Await.until(fn -> (record(cluster, :n1, op["id"]) || %{})["driver"] != nil end, 30_000)
    driver = peer_of(cluster, record(cluster, :n1, op["id"])["driver"])
    [observer | _] = @names -- [driver]

    Await.until(fn -> (record(cluster, observer, op["id"]) || %{})["state"] == "halted" end, 60_000)
    halted = record(cluster, observer, op["id"])
    assert halted["halt_reason"] == "error_rate"
    assert halted["driver"] == nil
    assert halted["counters"]["dispatched"] < length(keys)

    # Exactly the counted cells hold a job of the operation: nothing after the halt.
    marked = Enum.count(keys, &(job_rows(cluster, observer, &1, op["id"]) not in [[], nil]))
    assert marked == halted["counters"]["dispatched"] + halted["counters"]["skipped"]
  end

  test "an unreadable window halts with guard_unavailable only after guard_attempts" do
    cluster = start()
    wake_all(cluster, for(i <- 1..6, do: "u#{i}"))
    instance = Cluster.instance(cluster)

    op =
      operation(cluster, %{"canary_size" => 0, "rate_per_s" => 1, "guard_poll_ms" => 1, "guard_attempts" => 3})

    {:ok, {:ok, _}} = Cluster.call(cluster, :n1, Sweeps, :pause, [instance, op["id"]])
    Await.until(fn -> (record(cluster, :n1, op["id"]) || %{})["driver"] == nil end, 30_000)

    # A window cell that cannot be read stands for a store the sample cannot reach.
    {:ok, {:ok, stored, etag}} = Cluster.call(cluster, :n1, Sweeps, :get, [instance, op["id"]])
    body = Jason.encode!(Map.put(stored, "recent", ["jobs.u1", "no such cell"]))
    {:ok, handle} = Cluster.call(cluster, :n1, Store, :handle, [instance])

    assert {:ok, {:ok, _}} =
             Cluster.call(cluster, :n1, Store, :put, [handle, "operations/" <> op["id"], body, {:if_match, etag}])

    assert {:ok, {:ok, _}} = Cluster.call(cluster, :n1, Sweeps, :resume, [instance, op["id"]])

    Await.until(fn -> (record(cluster, :n2, op["id"]) || %{})["state"] == "halted" end, 60_000)
    halted = record(cluster, :n2, op["id"])
    assert halted["halt_reason"] == "guard_unavailable"
    assert halted["guard"]["failures"] == 3
  end
end
