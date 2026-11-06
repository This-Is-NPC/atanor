defmodule Atanor.Cluster.StoppedInstanceTest do
  @moduledoc """
  A call that reaches a node whose Alambique instance has stopped did not run: the node answers a
  retryable refusal instead of raising (design §8.11).
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.Manifests
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  # The state of a node between the stop of its cells' instance and the end of the VM: the cluster still
  # sends it calls, and the lease of its cells is still its own.
  defp stop_cells(cluster, name) do
    {:ok, true} =
      Cluster.call(cluster, name, Alambique.Config, :delete, [Module.concat(Cluster.instance(cluster), Cells)])
  end

  setup do
    cluster = start_cluster(names: [:n1, :n2, :n3], workers: [Manifests.counter("counter")])
    {cell, :n3} = owned_cell(cluster, "st", [:n3])
    stop_cells(cluster, :n3)
    %{cluster: cluster, cell: cell}
  end

  test "a cell call of a handler on another node is refused as a draining owner, not with the exception", %{
    cluster: cluster,
    cell: cell
  } do
    assert {:ok, %{status: 503, body: body}} = request(cluster, :n1, :get, "/c/direct/" <> cell)
    assert %{"error" => "unavailable", "reason" => "draining"} = Jason.decode!(body)
  end

  test "a call forwarded to the node did not run, whatever it is", %{cluster: cluster, cell: cell} do
    {:ok, %{"counter" => %{applied: id}}} = {:ok, Cluster.status(cluster, :n3)}
    call = {:http, %Atanor.Request{method: "POST", path: "/c/" <> cell, body: "1"}}
    args = [Cluster.instance(cluster), "counter", id, nil, 0, {"log", cell}, call, self(), make_ref()]

    assert {:ok, {:moved, nil}} = Cluster.call(cluster, :n3, Atanor.Dispatch, :remote, args)
  end

  test "a write forwarded to the node is answered unavailable, not with an unknown outcome", %{
    cluster: cluster,
    cell: cell
  } do
    assert {503, body} = write(cluster, :n1, cell, 1)
    assert %{"error" => "unavailable"} = Jason.decode!(body)
  end

  test "a handler's call that wakes a cell on a node whose admission table is gone is refused, not a 500" do
    cluster = start_cluster(names: [:n1, :n2, :n3], workers: [Manifests.counter("counter")])
    # Alambique deletes the table when it stops; a wake there then raises `badarg` from `ets:lookup`.
    {:ok, config} =
      Cluster.call(cluster, :n3, Alambique.Config, :fetch!, [Module.concat(Cluster.instance(cluster), Cells)])

    {:ok, true} = Cluster.call(cluster, :n3, :ets, :delete, [config.admission])

    answers =
      for i <- 1..24 do
        {:ok, %{status: status, body: body}} = request(cluster, :n1, :get, "/c/direct/ad#{i}")
        {status, body |> Jason.decode!() |> Map.take(["error", "reason"])}
      end

    assert Enum.all?(answers, fn {status, _} -> status in [200, 503] end), "answers: #{inspect(answers)}"
    assert {503, %{"error" => "unavailable", "reason" => "owner_down"}} in answers
  end

  describe "the answers of a stopped Alambique that did not run the call" do
    alias Atanor.Cell

    # The router of a peer whose instance stopped answers `{:error, :draining}`.
    test "are refusals, in the shapes Alambique still reports" do
      table = AtanorNode.Atanor.Cells.Admission

      stack = [
        {:ets, :lookup, [table, {:failed, "c.x"}], [error_info: %{cause: :id}]},
        {Alambique.Admission, :failure, 2, []}
      ]

      message = "no Alambique instance named AtanorNode.Atanor.Cells is running"

      for reason <- [
            {:exception, :badarg, stack},
            %ArgumentError{message: message}
          ] do
        assert Cell.refusal({:error, {:forward_failed, {:error, reason}}}) == :stopped
      end
    end

    test "a stopped router answers draining, and a peer's raise is no longer a refusal" do
      assert Cell.refusal({:error, :draining}) == :draining
      message = "no Alambique instance named AtanorNode.Atanor.Cells is running"

      assert Cell.refusal({:error, {:forward_failed, {:error, {:exception, %ArgumentError{message: message}, []}}}}) ==
               nil
    end

    test "are not mistaken for calls that may have run" do
      stack = [{:ets, :lookup, [:other_table, {:failed, "c.x"}], []}]
      other_lookup = [{:ets, :lookup, [AtanorNode.Atanor.Cells.Admission, {:waking, self()}], []}]

      for answer <- [
            {:error, {:forward_failed, {:error, {:exception, :badarg, stack}}}},
            {:error, {:forward_failed, {:error, {:exception, :badarg, other_lookup}}}},
            {:error, {:forward_failed, {:error, {:exception, %ArgumentError{message: "other"}, []}}}},
            {:error, {:forward_failed, {:exit, :timeout}}},
            {:error, {:forward_failed, :noconnection}},
            {:error, :outcome_unknown},
            {:error, :timeout}
          ] do
        assert Cell.refusal(answer) == nil, inspect(answer)
      end
    end
  end
end
