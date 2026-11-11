defmodule Atanor.WasmCapsPropertyTest do
  @moduledoc "C1: the results a WASM batch accumulates never pass `wasm.max_batch_bytes` (design §4.3)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Wasm.Host

  defp value, do: one_of([integer(), binary(max_length: 40), constant(nil), map(binary(max_length: 40), &{:blob, &1})])

  defp result do
    gen all(
          columns <- list_of(binary(max_length: 8), max_length: 3),
          rows <- list_of(list_of(value(), max_length: 4), max_length: 5)
        ) do
      %{columns: columns, rows: rows}
    end
  end

  property "the batch is refused exactly when the sum of its results passes the cap, and an accepted one stays under it" do
    check all(results <- list_of(result(), max_length: 8), cap <- integer(1..400)) do
      total = results |> Enum.map(&Host.result_bytes/1) |> Enum.sum()

      folded =
        Enum.reduce_while(results, {[], 0}, fn r, acc ->
          case Host.add_result(acc, r, cap) do
            {:ok, acc} -> {:cont, acc}
            {:error, :batch_too_large} = error -> {:halt, error}
          end
        end)

      case folded do
        {:error, :batch_too_large} -> assert total > cap
        {kept, bytes} -> assert bytes <= cap and total <= cap and Enum.reverse(kept) == results
      end
    end
  end
end
