defmodule Atanor.WasmCompileTest do
  @moduledoc """
  A compile nobody waits for does not hold a BEAM scheduler (design §14.5). The
  compile pool is shared by the VM, so these tests do not run beside others.
  """
  use ExUnit.Case, async: false

  alias Atanor.Wasm.{Cache, Native}
  alias AtanorTestkit.Node

  @grants %{sql: false, secrets: false, call: false, http: false, alarms: false, sockets: false, jobs: false}

  setup do
    node = Node.start()
    on_exit(fn -> Node.stop(node) end)
    %{node: node.name, bytes: File.read!("test/fixtures/wasm/hello.wasm")}
  end

  # Waits until the compile pool has taken every abandoned compile.
  defp drained(node, bytes, n \\ 0) do
    case Cache.fetch(node, "drain-#{n}", bytes) do
      {:ok, _} ->
        :ok

      {:error, _} when n < 600 ->
        Process.sleep(50)
        drained(node, bytes, n + 1)
    end
  end

  test "abandoned compiles leave the dirty schedulers free", %{node: node, bytes: bytes} do
    assert {:ok, compiled} = Cache.fetch(node, "first", bytes)

    # Distinct keys make every fetch a cold compile that its caller abandons.
    for i <- 1..400, do: spawn(fn -> Cache.fetch(node, "abandoned-#{i}", bytes, 1) end)
    Process.sleep(20)

    {micros, _} = :timer.tc(fn -> Native.prepare(compiled, @grants) end)
    assert micros < 100_000
    drained(node, bytes)
  end

  test "a full queue refuses the compile at once", %{node: node, bytes: bytes} do
    settings = Atanor.Wasm.settings()
    limit = settings.compile_threads + settings.compile_queue + 50

    results =
      1..limit
      |> Enum.map(fn i -> Task.async(fn -> Cache.fetch(node, "burst-#{i}", bytes) end) end)
      |> Task.await_many()

    assert {:error, "compile queue is full"} in results
    drained(node, bytes)
  end
end
