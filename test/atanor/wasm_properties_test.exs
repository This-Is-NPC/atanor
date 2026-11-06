defmodule Atanor.WasmPropertiesTest do
  @moduledoc """
  B1: a WASM worker cannot reach an ungranted binding.
  L1: runaway workers are stopped and the node stays healthy.
  """
  # Not async: L1 fills the node-wide guest pool, which would 503 other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.WasmCase

  alias AtanorTestkit.Node

  @dir Path.expand("test/fixtures/wasm")

  # The bindings each guest imports.
  @imports %{
    "hello" => [],
    "cell" => [:cells],
    "secret" => [:secrets],
    "caller" => [:workers],
    "outbound" => [:http],
    "alarm" => [:cells, :alarms],
    "socket" => [:cells, :sockets],
    "channel" => [:cells, :sockets],
    "sneaky" => [:cells, :secrets, :workers, :alarms, :sockets]
  }
  # Granting alarms or sockets also needs the guest to export its handler.
  @handlers %{"alarm" => [:alarms], "socket" => [:sockets], "channel" => [:sockets], "sneaky" => [:alarms, :sockets]}
  @bindings [:cells, :secrets, :workers, :http, :alarms, :sockets]

  defp grants(granted, name) do
    [
      cells: if(:cells in granted, do: %{name => []}, else: %{}),
      secrets: if(:secrets in granted, do: ["TOKEN"], else: []),
      workers: if(:workers in granted, do: ["friend"], else: []),
      allow: if(:http in granted, do: ["example.com"], else: []),
      alarms: :alarms in granted,
      sockets: :sockets in granted
    ]
  end

  describe "B1" do
    setup do
      node = Node.start()
      on_exit(fn -> Node.stop(node) end)
      %{node: node}
    end

    property "a component instantiates iff its imports are granted and its handlers exported", %{node: node} do
      check all(
              guest <- member_of(Map.keys(@imports)),
              granted <- list_of(member_of(@bindings), max_length: 6),
              max_runs: 120
            ) do
        name = "w#{System.unique_integer([:positive])}"
        result = Atanor.Dev.deploy(node.name, manifest(name, guest, grants(granted, name)), @dir)
        exported = Map.get(@handlers, guest, [])

        cond do
          not Enum.all?(@imports[guest], &(&1 in granted)) ->
            assert {:error, error} = result
            assert inspect(error) =~ "not_granted"

          not Enum.all?(Enum.filter(granted, &(&1 in [:alarms, :sockets])), &(&1 in exported)) ->
            assert {:error, {:missing_export, _}} = result

          true ->
            assert {:ok, _} = result
        end
      end
    end

    property "granted bindings still refuse other namespaces, secrets and workers" do
      node = start([{"c", "cell", cells: %{"granted" => []}}, {"s", "secret", secrets: ["TOKEN"]}])
      other = ExUnitProperties.gen(all(name <- string(?a..?z, min_length: 1, max_length: 8), do: name <> "x"))

      caller = start([{"k", "caller", workers: ["friend"]}])

      check all(name <- other, max_runs: 25) do
        headers = [{"x-op", "query"}, {"x-ns", name}, {"x-key", "a"}]
        assert %{status: 403} = request(node, "c", "", method: :post, body: "SELECT 1", headers: headers)

        secret = String.upcase(name)
        assert %{status: 403} = request(node, "s", "", headers: [{"x-name", secret}])

        assert %{status: 403} = request(caller, "k", "", headers: [{"x-worker", name}, {"x-path", "/"}])
      end
    end
  end

  describe "L1" do
    @runaways 16

    test "runaway guests beyond the pool size are stopped while others keep being served" do
      node =
        start([
          {"spin", "spin", []},
          {"hog", "hog", limits: %{"memory_bytes" => 32 * 1024 * 1024}},
          {"hello", "hello", []}
        ])

      capture([[:atanor, :wasm, :limit]])
      health = Task.async(fn -> sample_health(node) end)
      started = System.monotonic_time(:millisecond)

      runaways =
        for i <- 1..@runaways do
          Task.async(fn -> request(node, if(rem(i, 2) == 0, do: "spin", else: "hog")).status end)
        end

      hellos =
        for _ <- 1..40 do
          Process.sleep(20)
          Task.async(fn -> request(node, "hello").status end)
        end

      statuses = Task.await_many(runaways, 60_000)
      hello_statuses = Task.await_many(hellos, 60_000)
      elapsed = System.monotonic_time(:millisecond) - started
      %{sleep_max_ms: sleep_max, call_max_ms: call_max} = Task.await(health, 60_000)

      IO.puts(
        "L1: #{@runaways} runaways and 40 hellos in #{elapsed} ms, scheduler lag max #{sleep_max} ms, call max #{call_max} ms"
      )

      assert Enum.all?(statuses, &(&1 in [500, 504])), inspect(statuses)
      assert Enum.all?(hello_statuses, &(&1 in [200, 503])), inspect(hello_statuses)
      assert Enum.count(hello_statuses, &(&1 == 200)) > 0
      assert elapsed < 30_000
      assert sleep_max < 250 and call_max < 250

      limits =
        for _ <- 1..@runaways do
          assert_receive {:telemetry, _, _, %{limit: limit}}, 1000
          limit
        end

      assert Enum.sort(Enum.uniq(limits)) == [:cpu, :memory]
      assert %{status: 200} = request(node, "hello")
    end

    test "a full queue refuses calls instead of waiting" do
      node = start([{"spin", "spin", limits: %{"timeout_ms" => 3000}}])

      statuses =
        1..80 |> Enum.map(fn _ -> Task.async(fn -> request(node, "spin").status end) end) |> Task.await_many(60_000)

      assert 503 in statuses
      assert Enum.all?(statuses, &(&1 in [500, 503, 504]))
    end
  end

  # Latency of a timer and of a round trip to another process while guests run.
  defp sample_health(_node) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    deadline = System.monotonic_time(:millisecond) + 4_000

    samples =
      Stream.repeatedly(fn ->
        {sleep_us, _} = :timer.tc(fn -> Process.sleep(1) end)
        {call_us, _} = :timer.tc(fn -> Agent.get(agent, & &1) end)
        {sleep_us / 1000, call_us / 1000}
      end)
      |> Enum.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)

    %{
      sleep_max_ms: samples |> Enum.map(&elem(&1, 0)) |> Enum.max() |> round(),
      call_max_ms: samples |> Enum.map(&elem(&1, 1)) |> Enum.max() |> round()
    }
  end
end
