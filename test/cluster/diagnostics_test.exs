defmodule Atanor.Cluster.DiagnosticsTest do
  @moduledoc """
  A real VM crash of a peer leaves a breadcrumb, and the restart reports the
  unit and Alambique's quarantine counter (design §17.2).
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 300_000

  defp rows(cluster, name, key, sql, params) do
    case Cluster.call(cluster, name, Atanor.Cell, :query, [Cluster.instance(cluster), {"jobs", key}, sql, params]) do
      {:ok, {:ok, %{rows: rows}}} -> rows
      _ -> nil
    end
  end

  defp peer_dir(cluster, name) do
    dir = :sys.get_state(cluster).dir
    peer = cluster |> Cluster.node(name) |> Atom.to_string() |> String.split("@") |> hd()
    {dir, peer}
  end

  defp report(cluster, name) do
    response =
      Req.get!(
        Cluster.admin_url(cluster, name) <> "/crashes",
        headers: [{"authorization", "Bearer " <> Cluster.admin_token()}],
        retry: false,
        decode_body: false
      )

    case response.status do
      200 -> Jason.decode!(response.body)["crashes"]
      _ -> []
    end
  end

  test "a peer VM crash reports the job unit, its cell and the quarantine counter" do
    cluster =
      start_cluster(
        names: [:n1, :n2],
        workers: [Manifests.jobs("jobs")],
        atanor: [
          alarms: [tick_ms: 50],
          jobs: [timeout_ms: 60_000, claim_ms: 70_000, concurrency: 4, worker_concurrency: 4, cell_concurrency: 1],
          diagnostics: [breadcrumbs: :durable]
        ]
      )

    key = "crash"

    assert {:ok, _} =
             Cluster.call(cluster, :n1, Atanor.Cell, :query, [Cluster.instance(cluster), {"jobs", key}, "SELECT 1"])

    {:ok, owner} = owner(cluster, :n1, "jobs", key)
    victim = name_of(cluster, owner)
    [survivor] = Cluster.names(cluster) -- [victim]

    assert {:ok, {:ok, job_id}} =
             Cluster.call(cluster, survivor, Atanor.Jobs, :enqueue_direct, [
               Cluster.instance(cluster),
               "jobs",
               {"jobs", key},
               %{kind: "test", payload: "slow"}
             ])

    assert {:ok, ^owner} = owner(cluster, survivor, "jobs", key)

    Await.until(
      fn ->
        case rows(cluster, survivor, key, "SELECT state FROM _atanor_jobs WHERE id = ?", [job_id]) do
          [["running"]] -> true
          _ -> false
        end
      end,
      20_000
    )

    # The job row is running before the handler task starts. Wait until the
    # handler wrote its row, so its breadcrumb is open when the VM dies.
    Await.until(fn -> rows(cluster, survivor, key, "SELECT count(*) FROM runs", []) == [[1]] end, 20_000)

    {dir, peer} = peer_dir(cluster, victim)
    unit_files = Path.wildcard(Path.join([dir, peer, "diagnostics", "units", "*"]))

    assert unit_files != [], "no breadcrumb before the crash"
    assert Enum.any?(unit_files, &match?(<<1, _::binary>>, File.read!(&1)))

    Cluster.kill_process(cluster, victim)
    :ok = Cluster.restart(cluster, victim)

    reports =
      try do
        Await.until(
          fn ->
            case report(cluster, survivor) do
              [] -> nil
              reports -> reports
            end
          end,
          90_000
        )
      rescue
        _ ->
          diag = Cluster.call(cluster, victim, Atanor.Diagnostics, :list, [Cluster.instance(cluster)])
          flunk("no report; diag=#{inspect(diag)} admin=#{inspect(report(cluster, survivor))}")
      end

    assert [report] = reports
    assert report["node"] == Atom.to_string(Cluster.node(cluster, victim))
    assert [unit] = report["units"]
    assert unit["kind"] == "job"
    assert unit["worker"] == "jobs"
    assert unit["job_id"] == job_id
    assert unit["cell"] == "jobs.crash"
    assert unit["release"] == Atanor.Release.default_id()
    assert %{"crashes" => crashes, "frozen" => frozen} = unit["alambique"]
    assert is_nil(crashes) or is_map(crashes)
    assert is_boolean(frozen)

    Await.until(
      fn -> Enum.any?(Cluster.events(cluster), &(&1.event == [:atanor, :crash, :detected])) end,
      5_000
    )
  end
end
