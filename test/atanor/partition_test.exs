defmodule Atanor.PartitionTest do
  @moduledoc "The mapping of a partition key to a partition cell (design §4.2)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Partition

  # SHA-256 of the key, first 8 bytes big-endian, as computed outside Erlang (Python's hashlib). A change of
  # the hash function, the byte order or the width moves existing data to other cells, so it breaks here.
  @vectors [
    {"alice", 3_159_282_601_090_220_207},
    {"", 16_406_829_232_824_261_652},
    {"bob", 9_346_719_481_748_178_650},
    {"user-42", 7_892_921_889_885_005_129},
    {"é", 5_375_421_630_974_772_051}
  ]

  test "the hash is pinned: known partition keys map to known partitions" do
    for {key, hash} <- @vectors, n <- [1, 2, 3, 6, 1024] do
      assert Partition.index(key, n) == rem(hash, n), "#{inspect(key)} with #{n} partitions"
    end

    assert Partition.index("alice", 6) == 5
    assert Partition.index("bob", 3) == 2
    assert Partition.index("user-42", 1024) == 329
  end

  test "the physical key is the decimal partition, a dot and the logical key" do
    assert Partition.key("stream", 5) == "5.stream"
    assert Partition.key("stream", 12) == "12.stream"
    assert {:ok, {"events", "5.stream"}} = Partition.address({"events", "stream"}, "alice", 6)
    assert {:ok, {"events", "5.a.b-1"}} = Partition.address({"events", "a.b-1"}, "alice", 6)

    assert {:ok, [{"events", "0.s"}, {"events", "1.s"}, {"events", "2.s"}]} = Partition.addresses({"events", "s"}, 3)
  end

  test "keys that are not valid cell keys are refused" do
    for key <- ["", "a/b", <<"a", 0>>, :atom, 5] do
      assert {:error, :invalid_key} = Partition.address({"events", key}, "alice", 3)
      assert {:error, :invalid_key} = Partition.addresses({"events", key}, 3)
    end

    assert {:error, :invalid_partition_key} = Partition.address({"events", "s"}, 5, 3)
  end

  test "split is the inverse of key, and only for the canonical form" do
    assert {:ok, {"stream", 5}} = Partition.split("5.stream")
    assert {:ok, {"stream", 0}} = Partition.split("0.stream")
    assert {:ok, {"1.a.b", 12}} = Partition.split("12.1.a.b")

    for bad <- ["stream", "5.", "05.stream", "-1.stream", "+1.stream", "a.stream", ".stream", "5stream", "5 .stream"] do
      assert :error = Partition.split(bad), inspect(bad)
    end

    assert Partition.physical?("2.s", 3)
    refute Partition.physical?("3.s", 3)
    refute Partition.physical?("s", 3)
  end

  property "the routing of partitioned cells is stable" do
    check all(
            n <- integer(1..Partition.max_partitions()),
            key <- string(:printable, max_length: 40),
            logical <- string(:alphanumeric, min_length: 1, max_length: 12)
          ) do
      index = Partition.index(key, n)
      assert index in 0..(n - 1)

      # The same input, again, in another process and from the reference computation.
      assert index == Partition.index(key, n)
      assert index == Task.async(fn -> Partition.index(key, n) end) |> Task.await()
      <<hash::unsigned-big-64, _::binary>> = :crypto.hash(:sha256, key)
      assert index == rem(hash, n)

      assert {:ok, {"ns", physical}} = Partition.address({"ns", logical}, key, n)
      assert physical == Integer.to_string(index) <> "." <> logical
      assert {:ok, {^logical, ^index}} = Partition.split(physical)
      assert Partition.physical?(physical, n)
      assert {:ok, {"ns", ^physical}} = Partition.address({"ns", logical}, key, n)
    end
  end

  property "the keys spread over the partitions" do
    check all(n <- integer(2..16), max_runs: 20) do
      per = 200
      counts = Enum.frequencies(for i <- 1..(n * per), do: Partition.index("key-#{i}-#{n}", n))

      assert map_size(counts) == n
      # A loose bound: each partition holds within 40% of its fair share.
      for {_, count} <- counts, do: assert(count in round(per * 0.6)..round(per * 1.4))
    end
  end
end
