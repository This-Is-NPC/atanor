defmodule Atanor.WasmWaitTest do
  # A guest that waits does not hold the right to run (design §14.2): other workers are served
  # while it sleeps, and a callee gets a thread while its callers wait for it.
  use ExUnit.Case, async: false

  import Atanor.Test.WasmCase

  @moduletag :wasm_wait

  test "sleeping guests do not starve another worker" do
    node = start([{"sleeper", "sleep", []}, {"hello", "hello", []}])
    threads = Atanor.Wasm.settings().threads

    sleepers =
      for _ <- 1..threads do
        Task.async(fn -> request(node, "sleeper", "/4000") end)
      end

    Process.sleep(500)
    started = System.monotonic_time(:millisecond)
    assert %{status: 200} = request(node, "hello")
    assert System.monotonic_time(:millisecond) - started < 1_000

    assert [%{status: 200, body: "slept 4000"} | _] = Task.await_many(sleepers, 30_000)
  end

  test "waiting guests do not use up the call slots of their worker" do
    node = start([{"sleeper", "sleep", []}, {"hello", "hello", []}])
    settings = Atanor.Wasm.settings()
    count = settings.worker_calls + 2

    # Started in groups, so each group has parked (is waiting) before the next one is admitted.
    sleepers =
      for group <- Enum.chunk_every(1..count, settings.threads) do
        tasks = for _ <- group, do: Task.async(fn -> request(node, "sleeper", "/4000") end)
        Process.sleep(300)
        tasks
      end

    assert %{status: 200} = request(node, "hello")
    assert %{status: 200} = request(node, "sleeper", "/10")
    statuses = sleepers |> List.flatten() |> Task.await_many(30_000) |> Enum.map(& &1.status)
    assert statuses == List.duplicate(200, count)
  end

  test "nested calls complete when their callers hold every thread" do
    node =
      start([
        {"callee", "sleep", callable_by: ["caller"]},
        {"caller", "caller", workers: ["callee"]}
      ])

    threads = Atanor.Wasm.settings().threads

    callers =
      for _ <- 1..threads do
        Task.async(fn ->
          request(node, "caller", "", method: :post, body: "x", headers: [{"x-worker", "callee"}, {"x-path", "/500"}])
        end)
      end

    for response <- Task.await_many(callers, 30_000), do: assert(%{status: 200, body: "200 slept 500"} = response)
  end
end
