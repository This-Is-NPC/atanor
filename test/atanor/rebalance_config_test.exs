defmodule Atanor.RebalanceConfigTest do
  use ExUnit.Case, async: true

  alias Atanor.Config

  defp build(rebalance) do
    Config.build(
      name: :rebalance_config,
      store: {AlambiqueTestkit.MemoryStore, %{}},
      data_dir: System.tmp_dir!(),
      port: 0,
      rebalance: rebalance
    )
  end

  test "is on by default, at a low rate and after a delay" do
    assert %{rebalance: %{enabled: true, max_moves_per_s: 5, start_delay_ms: 30_000}} = build(nil)
  end

  test "takes options and refuses what cannot work" do
    assert %{rebalance: %{enabled: false, max_moves_per_s: 20, start_delay_ms: 100}} =
             build(enabled: false, max_moves_per_s: 20, start_delay_ms: 100)

    for bad <- [[max_moves_per_s: 0], [max_moves_per_s: 21], [start_delay_ms: 0], [enabled: 1], [unknown: 1], :on] do
      assert_raise ArgumentError, ~r/rebalance/, fn -> build(bad) end
    end
  end
end
