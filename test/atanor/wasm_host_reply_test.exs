defmodule Atanor.WasmHostReplyTest do
  @moduledoc """
  Copying a large host reply into Rust does not hold a normal scheduler
  (design §14.7).
  """
  use ExUnit.Case, async: false

  alias Atanor.Wasm.Native

  @reply_bytes 128 * 1024 * 1024

  # Wakeups of a 1 ms ticker pinned to scheduler 1 while a process pinned there
  # replies to an unknown call. A NIF that holds the scheduler allows none.
  defp ticks_during_reply(reply) do
    counter = :atomics.new(1, [])

    ticker =
      spawn_link(fn ->
        :erlang.process_flag(:scheduler, 1)
        tick(counter)
      end)

    caller = self()

    spawn_link(fn ->
      :erlang.process_flag(:scheduler, 1)
      Process.sleep(20)

      ticks =
        for _ <- 1..5 do
          before = :atomics.get(counter, 1)
          :ok = Native.host_reply(4_000_000_000, reply)
          :atomics.get(counter, 1) - before
        end

      send(caller, {:ticks, ticks})
    end)

    assert_receive {:ticks, ticks}, 30_000
    Process.unlink(ticker)
    Process.exit(ticker, :kill)
    ticks
  end

  defp tick(counter) do
    receive do
    after
      1 ->
        :atomics.add(counter, 1, 1)
        tick(counter)
    end
  end

  test "a large reply leaves its normal scheduler free" do
    reply = :binary.copy(<<1>>, @reply_bytes)
    # The first reply may tick around its edges; load can starve some of the
    # others, not all.
    assert ticks_during_reply(reply) |> Enum.drop(1) |> Enum.max() > 0
  end

  test "the size decides the entry point" do
    assert Native.reply_entry(:binary.copy(<<1>>, 99), 100) == :small
    assert Native.reply_entry(:binary.copy(<<1>>, 100), 100) == :large
    assert Native.reply_entry({:ok, [:binary.copy(<<1>>, 200)]}, 100) == :large
    assert Native.reply_entry(nil, 100) == :small
  end
end
