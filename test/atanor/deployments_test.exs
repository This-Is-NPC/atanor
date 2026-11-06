defmodule Atanor.DeploymentsTest do
  use ExUnit.Case, async: true

  alias Atanor.{Deployments, Store}
  alias Atanor.Deployments.Head
  alias Atanor.Test.Manifests

  # Package number `n` of worker `name`: only the limit differs.
  defp package(n, name \\ "w"), do: Manifests.package(Manifests.probe(name, limits: %{"timeout_ms" => n}))

  defp publish!(store, n, name \\ "w") do
    {:ok, id} = Deployments.publish(store, package(n, name))
    id
  end

  setup do
    %{store: Manifests.memory_store()}
  end

  describe "publish" do
    test "stores the bytes once under the hash, and again is fine", %{store: store} do
      package = package(1)
      assert {:ok, id} = Deployments.publish(store, package)
      assert id == package.id
      assert {:ok, bytes, _, _} = Store.get(store, "packages/" <> id)
      assert bytes == package.bytes
      assert {:ok, ^id} = Deployments.publish(store, package)
      assert {:ok, ^package} = Deployments.fetch_package(store, id)
    end

    test "fetch refuses bytes that do not hash to their key", %{store: store} do
      a = package(1)
      b = package(2)
      {:ok, _} = Store.put(store, "packages/" <> a.id, b.bytes)
      assert {:error, {:package_id_mismatch, _, _}} = Deployments.fetch_package(store, a.id)

      {:ok, _} = Store.put(store, "packages/" <> String.duplicate("0", 64), "junk")
      assert {:error, {:invalid_package, :bad_magic}} = Deployments.fetch_package(store, String.duplicate("0", 64))
      assert {:error, :not_found} = Deployments.fetch_package(store, String.duplicate("1", 64))
    end
  end

  describe "heads" do
    test "the first activation creates the head at revision 1", %{store: store} do
      id = publish!(store, 1)
      assert {:error, :not_found} = Deployments.head(store, "w")

      assert {:ok, %Head{worker: "w", active: ^id, previous: [], revision: 1, updated_at: at}} =
               Deployments.activate(store, "w", id)

      assert {:ok, _, _} = DateTime.from_iso8601(at)
      assert {:ok, %Head{active: ^id, revision: 1}} = Deployments.head(store, "w")

      assert {:ok, json, _, _} = Store.get(store, "workers/w/head")
      assert %{"worker" => "w", "active" => ^id, "previous" => [], "revision" => 1} = Jason.decode!(json)
    end

    test "a switch keeps the old ones, newest first, and activating the active one changes nothing", %{store: store} do
      [a, b, c] = for n <- 1..3, do: publish!(store, n)
      {:ok, _} = Deployments.activate(store, "w", a)
      {:ok, _} = Deployments.activate(store, "w", b)
      assert {:ok, %Head{active: ^c, previous: [^b, ^a], revision: 3}} = Deployments.activate(store, "w", c)
      assert {:ok, %Head{revision: 3}} = Deployments.activate(store, "w", c)
      assert {:ok, %Head{revision: 3}} = Deployments.head(store, "w")
    end

    test "only the last 20 previous packages are kept", %{store: store} do
      ids = for n <- 1..25, do: publish!(store, n)
      for id <- ids, do: {:ok, _} = Deployments.activate(store, "w", id)

      assert {:ok, %Head{active: active, previous: previous, revision: 25}} = Deployments.head(store, "w")
      assert active == List.last(ids)
      assert previous == ids |> Enum.take(24) |> Enum.reverse() |> Enum.take(20)
    end

    test "keeps the configured number of previous packages", %{store: store} do
      ids = for n <- 1..5, do: publish!(store, n)
      for id <- ids, do: {:ok, _} = Deployments.activate(store, "w", id, max_previous: 2)

      assert {:ok, %Head{active: active, previous: previous}} = Deployments.head(store, "w")
      assert active == List.last(ids)
      assert previous == ids |> Enum.take(4) |> Enum.reverse() |> Enum.take(2)

      assert_raise ArgumentError, ~r/deployment options/, fn ->
        Deployments.activate(store, "w", hd(ids), max_previous: 0)
      end
    end

    test "refuses unknown packages, bad ids, other workers' packages and bad worker names", %{store: store} do
      other = publish!(store, 1, "other")
      assert {:error, :not_found} = Deployments.activate(store, "w", String.duplicate("a", 64))
      assert {:error, :invalid_id} = Deployments.activate(store, "w", "abc")
      assert {:error, {:package_of_other_worker, "other", "w"}} = Deployments.activate(store, "w", other)
      assert {:error, :invalid_worker} = Deployments.activate(store, "../x", other)
      assert {:error, :not_found} = Deployments.head(store, "w")
    end

    test "lists the workers that have a head", %{store: store} do
      for name <- ~w(b a c), do: {:ok, _} = Deployments.activate(store, name, publish!(store, 1, name))
      assert {:ok, ["a", "b", "c"]} = Deployments.workers(store)
      assert {:ok, [%Head{worker: "a"}, %Head{worker: "b"}, %Head{worker: "c"}]} = Deployments.list(store)
    end
  end

  describe "rollback" do
    test "restores the previous package, and again goes further back", %{store: store} do
      [a, b, c] = for n <- 1..3, do: publish!(store, n)
      for id <- [a, b, c], do: {:ok, _} = Deployments.activate(store, "w", id)

      assert {:ok, %Head{active: ^b, previous: [^a], revision: 4}} = Deployments.rollback(store, "w")
      assert {:ok, %Head{active: ^a, previous: [], revision: 5}} = Deployments.rollback(store, "w")
      assert {:error, :no_previous} = Deployments.rollback(store, "w")
      assert {:ok, %Head{active: ^a, revision: 5}} = Deployments.head(store, "w")
    end

    test "a worker without a head has nothing to roll back", %{store: store} do
      assert {:error, :no_previous} = Deployments.rollback(store, "w")
      assert {:error, :not_found} = Deployments.head(store, "w")
    end
  end

  describe "deactivate" do
    test "clears the active package and keeps it for a rollback", %{store: store} do
      [a, b] = for n <- 1..2, do: publish!(store, n)
      for id <- [a, b], do: {:ok, _} = Deployments.activate(store, "w", id)

      assert {:ok, %Head{active: nil, previous: [^b, ^a], revision: 3}} = Deployments.deactivate(store, "w")
      assert {:ok, %Head{revision: 3}} = Deployments.deactivate(store, "w")
      assert {:ok, %Head{active: ^b, previous: [^a]}} = Deployments.rollback(store, "w")
      assert {:error, :not_found} = Deployments.deactivate(store, "none")
    end

    test "activating again after a deactivation does not repeat a null in the history", %{store: store} do
      [a, b] = for n <- 1..2, do: publish!(store, n)
      {:ok, _} = Deployments.activate(store, "w", a)
      {:ok, _} = Deployments.deactivate(store, "w")
      assert {:ok, %Head{active: ^b, previous: [^a]}} = Deployments.activate(store, "w", b)
    end
  end

  describe "concurrent changes" do
    test "two activators both end in a consistent head: no update is lost", %{store: store} do
      mine = for n <- 1..6, do: publish!(store, n)
      theirs = for n <- 11..16, do: publish!(store, n)

      results =
        [mine, theirs]
        |> Task.async_stream(
          fn ids -> for id <- ids, do: Deployments.activate(store, "w", id) end,
          timeout: 30_000
        )
        |> Enum.flat_map(fn {:ok, results} -> results end)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      assert successes == 12

      assert {:ok, %Head{revision: ^successes, active: active, previous: previous}} = Deployments.head(store, "w")
      # Each activator's own order is kept, and every package but the active one is in the history once.
      assert Enum.sort([active | previous]) == Enum.sort(mine ++ theirs)
      assert Enum.filter(Enum.reverse(previous) ++ [active], &(&1 in mine)) == mine
      assert Enum.filter(Enum.reverse(previous) ++ [active], &(&1 in theirs)) == theirs
    end
  end
end
