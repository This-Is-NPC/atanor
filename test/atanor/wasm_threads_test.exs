defmodule Atanor.WasmThreadsTest do
  use ExUnit.Case, async: true

  import Atanor.Wasm, only: [cpu_threads: 2]

  test "the pool follows the CPU quota of the container, rounded up, never above the processors" do
    assert cpu_threads(12, {:ok, "100000 100000\n"}) == 1
    assert cpu_threads(12, {:ok, "150000 100000\n"}) == 2
    assert cpu_threads(12, {:ok, "400000 100000\n"}) == 4
    assert cpu_threads(2, {:ok, "400000 100000\n"}) == 2
  end

  test "no quota, or a file that cannot be read, keeps the processors" do
    for result <- [{:ok, "max 100000\n"}, {:ok, "\n"}, {:ok, "0 100000\n"}, {:ok, "100 0\n"}, {:error, :enoent}] do
      assert cpu_threads(12, result) == 12
    end
  end
end
