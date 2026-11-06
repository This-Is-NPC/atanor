defmodule Atanor.BoundedReadsTest.Worker do
  @moduledoc false
  @behaviour Atanor.Worker

  @impl true
  def handle_alarm(_cell, _payload, _env), do: :ok
  @impl true
  def handle_job(_job, _env), do: :ok
end

defmodule Atanor.BoundedReadsTest do
  @moduledoc "Reads with a bound on one node: the options of Env.query/5, bounded requests and the route key (design §19)."
  use ExUnit.Case, async: true

  alias Atanor.{Dispatch, Env, Registry, Request}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  defp start(opts \\ []) do
    node = Node.start(workers: [Manifests.counter("counter", opts)])
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp env(node) do
    {:ok, deployment} = Registry.deployment(node.name, "counter")
    Env.new(node.name, deployment)
  end

  defp get(node, path), do: Req.get!(node.url <> path, retry: false)

  describe "Env.query/5" do
    test "takes :strong and {:bounded, ms}, and the owner answers both" do
      node = start()
      env = env(node)
      cell = {"log", "a"}
      {:ok, _} = Env.execute(env, cell, "INSERT INTO log (n) VALUES (?)", [7])

      for consistency <- [:strong, {:bounded, 1}, {:bounded, 60_000}] do
        assert {:ok, %{rows: [[7]]}} = Env.query(env, cell, "SELECT n FROM log", [], consistency: consistency)
      end

      assert {:ok, %{rows: [[7]]}} = Env.query(env, cell, "SELECT n FROM log")
    end

    test "refuses what Alambique would, before the call" do
      env = env(start())
      cell = {"log", "a"}

      for consistency <- [{:bounded, 0}, {:bounded, -1}, {:bounded, 1.5}, :bounded, :eventual, {:stale, 5}] do
        assert {:error, {:invalid_option, :consistency}} =
                 Env.query(env, cell, "SELECT 1", [], consistency: consistency)
      end

      assert {:error, {:invalid_option, :consistency}} =
               Env.query(env, cell, "SELECT 1", [], consistency: {:bounded, 10}, verify_lease: true)

      assert {:error, {:invalid_option, :verfy_lease}} = Env.query(env, cell, "SELECT 1", [], verfy_lease: true)
      assert {:error, {:invalid_option, :opts}} = Env.query(env, cell, "SELECT 1", [], :strong)
      assert {:error, {:not_granted, {:cell, "other"}}} = Env.query(env, {"other", "a"}, "SELECT 1", [], [])
    end
  end

  describe "a bounded env" do
    test "reads with its bound, may ask for the lease check, and cannot write" do
      env = %{
        env(start(module: Atanor.BoundedReadsTest.Worker, alarms: true, jobs: true))
        | consistency: {:bounded, 500}
      }

      cell = {"log", "a"}

      assert {:ok, _} = Env.query(env, cell, "SELECT 1")
      assert {:ok, _} = Env.query(env, cell, "SELECT 1", [], consistency: :strong)
      assert {:ok, _} = Env.query(env, cell, "SELECT 1", [], verify_lease: true)
      assert {:error, :read_only} = Env.execute(env, cell, "INSERT INTO log (n) VALUES (1)")
      assert {:error, :read_only} = Env.transaction(env, cell, fn _tx -> :ok end)
      assert {:error, :read_only} = Env.set_alarm(env, cell, 0, "")
      assert {:error, :read_only} = Env.cancel_alarm(env, cell)
      assert {:error, :read_only} = Env.enqueue(env, cell, %{kind: "k", payload: ""})
      assert {:error, :read_only} = Env.cron(env, cell, %{kind: "k", payload: "", cron: "* * * * *"})
    end
  end

  describe "route_key/2 with consistency" do
    test "a bounded request reads, a write in it is refused with 409, a normal request writes" do
      node = start()
      assert %{status: 200} = Req.post!(node.url <> "/c/a", body: "5", retry: false)
      assert %{status: 200, body: %{"rows" => [5], "node" => _}} = get(node, "/r/a?ms=500")

      assert %{status: 409, body: %{"error" => ":read_only"}} =
               Req.post!(node.url <> "/r/a?ms=500", body: "6", retry: false)

      assert %{body: %{"rows" => [5]}} = get(node, "/c/a")
    end

    defp route(node, key) do
      {:ok, deployment} = Registry.deployment(node.name, "counter")
      module = Module.concat(__MODULE__, "Router#{System.unique_integer([:positive])}")

      Module.create(
        module,
        quote do
          def route_key(_input, _env), do: unquote(Macro.escape(key))
        end,
        Macro.Env.location(__ENV__)
      )

      Dispatch.route(%{env(node) | deployment: %{deployment | module: module}}, %Request{path: "/"})
    end

    test "accepts the options after the key and after a partition key" do
      node = start()
      assert {:ok, {"log", "a"}, :strong} = route(node, {:cell, "log", "a", []})
      assert {:ok, {"log", "a"}, :strong} = route(node, {:cell, "log", "a", consistency: :strong})
      assert {:ok, {"log", "a"}, {:bounded, 250}} = route(node, {:cell, "log", "a", consistency: {:bounded, 250}})
    end

    test "refuses an option that is not valid" do
      node = start()

      for key <- [
            {:cell, "log", "a", consistency: {:bounded, 0}},
            {:cell, "log", "a", consistency: :eventual},
            {:cell, "log", "a", unknown: 1},
            {:cell, "log", "a", [:consistency]},
            {:cell, "other", "a", consistency: {:bounded, 5}},
            {:cell, "log", "", consistency: {:bounded, 5}}
          ] do
        assert {:error, {:bad_route_key, ^key}} = route(node, key)
      end
    end
  end
end
