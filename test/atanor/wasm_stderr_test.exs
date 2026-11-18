defmodule Atanor.WasmStderrTest do
  use ExUnit.Case, async: true

  import Atanor.Test.WasmCase

  describe "guest stderr in the log" do
    test "control characters are escaped and printable UTF-8 is kept" do
      assert Atanor.Wasm.printable("  fake\nline\r\e[31mred\e[0m\t\x00\u0085end é日本\n") ==
               "fake\\nline\\r\\x1b[31mred\\x1b[0m\\t\\x00\\x85end é日本"

      assert Atanor.Wasm.printable(<<?a, 0x2028::utf8, ?b, 0xFF>>) == "a\\u{2028}b" <> <<0xFFFD::utf8>>
    end

    test "a trapping guest's stderr is one log entry, without raw newlines" do
      node = start([{"crash", "crash", []}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert request(node, "crash").status == 500
        end)

      # The panic message has several lines; each must still carry the prefix of the entry.
      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "the guest panics on purpose"))
      assert lines != []
      assert Enum.all?(lines, &(&1 =~ "wrote to stderr: "))
      assert log =~ "\\n"
    end
  end
end
