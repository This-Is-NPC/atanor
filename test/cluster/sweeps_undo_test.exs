defmodule Atanor.Cluster.SweepsUndoTest do
  @moduledoc """
  The undo report and the undo of a bulk operation across nodes (design
  §15.10): they run on the node that received the request, read and rewind the
  cells whichever node owns them, and every node reads the record.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.{Cell, Sweeps}
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 300_000

  @names [:n1, :n2, :n3]
  @keys ~w(k1 k2 k3 k4)

  defp start do
    start_cluster(
      names: @names,
      ttl_ms: 3_000,
      skew_margin_ms: 400,
      workers: [Manifests.jobs("jobs")],
      atanor: [
        alarms: [tick_ms: 100, timeout_ms: 1_000, max_attempts: 5],
        jobs: [claim_ms: 2_000, timeout_ms: 1_000, backoff_ms: 100, max_backoff_ms: 100],
        sweeps: [poll_ms: 100, lease_ttl_ms: 3_000, renew_ms: 500, cell_timeout_ms: 2_000, page_size: 5, retry_ms: 100],
        poll_interval_ms: 200
      ]
    )
  end

  defp call(cluster, via, module, function, args) do
    {:ok, result} = Cluster.call(cluster, via, module, function, args)
    result
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

  test "a node that owns none of the cells reports on them and rewinds them, and every node reads the record" do
    cluster = start()
    instance = Cluster.instance(cluster)
    alambique = Module.concat(instance, Cells)

    # Every target cell lives on n2; the request goes to n1.
    for key <- @keys do
      {:ok, _} = call(cluster, :n1, Cell, :execute, [instance, {"jobs", key}, "INSERT INTO notes (body) VALUES ('a')"])
      {:ok, _} = call(cluster, :n1, Alambique, :move, [alambique, "jobs." <> key, Cluster.node(cluster, :n2)])
      assert {:ok, Cluster.node(cluster, :n2)} == owner(cluster, :n1, "jobs", key)
    end

    selector = %{"kind" => "namespace", "namespace" => "jobs"}
    action = %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("swept")}

    {:ok, op} =
      call(cluster, :n1, Sweeps, :start, [instance, %{"selector" => selector, "action" => action, "undo" => true}])

    Await.until(
      fn -> (call(cluster, :n1, Sweeps, :get, [instance, op["id"]]) |> elem(1))["state"] == "done" end,
      60_000
    )

    {:ok, _} =
      call(cluster, :n3, Cell, :execute, [instance, {"jobs", "k1"}, "INSERT INTO notes (body) VALUES ('after')"])

    for key <- @keys do
      Await.until(
        fn ->
          match?(
            {:ok, %{rows: [["done"]]}},
            call(cluster, :n3, Cell, :query, [
              instance,
              {"jobs", key},
              "SELECT state FROM _atanor_jobs WHERE operation_id = ?",
              [op["id"]]
            ])
          )
        end,
        60_000
      )

      {:ok, :ok} = Cluster.call(cluster, :n1, Alambique, :hibernate, [alambique, "jobs." <> key])
    end

    path = "/operations/#{op["id"]}/undo"

    assert {202, %{"undo_id" => "u-" <> _, "state" => "running"}} =
             api(cluster, :n1, :post, path, %{"mode" => "report"})

    report =
      Await.until(fn -> (r = elem(api(cluster, :n3, :get, path), 1)) && r["state"] != "running" && r end, 60_000)

    assert report["state"] == "done"
    assert report["node"] == Atom.to_string(Cluster.node(cluster, :n1))
    assert %{"cells" => 4, "with_position" => 4, "restorable" => 4, "unrestorable" => 0} = report["summary"]

    cells = Map.new(report["cells"], &{&1["cell"], &1})
    notes = fn cell -> Enum.find(cells[cell]["tables"], &(&1["name"] == "notes")) end
    assert %{"before" => 1, "current" => 2, "changed" => true} = notes.("jobs.k1")
    assert %{"before" => 1, "current" => 1, "changed" => false} = notes.("jobs.k2")
    assert api(cluster, :n2, :get, path) == {200, report}

    # No copy stays on the node that made the report.
    {:ok, root} = Cluster.call(cluster, :n1, Atanor.Registry, :config, [instance])
    Await.until(fn -> File.ls!(Path.join(root.data_dir, "undos")) == [] end)

    # The cells are awake on n2 again after the report. n1 rewinds them: the owner gives them up first.
    assert {202, %{"undo_id" => "u-" <> _, "state" => "running"}} =
             api(cluster, :n1, :post, path, %{"mode" => "apply"})

    applied =
      Await.until(fn -> (r = elem(api(cluster, :n3, :get, path), 1)) && r["state"] != "running" && r end, 60_000)

    assert %{"mode" => "apply", "state" => "done", "error" => nil} = applied
    assert %{"rewound" => 4, "data_written" => 0, "failed" => 0, "unknown" => 0} = applied["summary"]
    assert api(cluster, :n2, :get, path) == {200, applied}

    for key <- @keys do
      sql = "SELECT (SELECT count(*) FROM notes), (SELECT count(*) FROM effects), (SELECT count(*) FROM _atanor_jobs)"
      assert {:ok, %{rows: [[1, 0, 1]]}} = call(cluster, :n3, Cell, :query, [instance, {"jobs", key}, sql])
    end
  end
end
