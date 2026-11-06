defmodule Atanor.Partition do
  @moduledoc """
  Partitioned cells (design §4.2): the mapping of a partition key to the
  physical cell that holds it.

  A namespace that declares `partitions: n` in its manifest has `n` physical
  cells for each logical cell `{namespace, key}`. The physical cell for a
  partition key is `{namespace, index <> "." <> key}`, where `index` is in
  `0..n-1` and is written in decimal without leading zeros. The Alambique id
  of the cell is `<namespace>.<index>.<key>`. The characters of the id are
  those every placement allows (`A-Za-z0-9_.-`), so the separator is a dot.

  The index is the first 8 bytes of the SHA-256 of the partition key, read as
  an unsigned big-endian integer, modulo `n`. SHA-256 is specified outside
  Erlang and available in every language, so a guest or a tool can reproduce
  the mapping, and it never changes with the OTP version. The pinned vectors
  are in the tests.

  In a partitioned namespace a cell is addressed only by its physical key: a
  key that does not start with a partition number below `n` and a dot is
  refused (`{:partition_required, namespace}`). The index is read up to the
  first dot, so any logical key has exactly one physical form and no key
  collides with the name of a partition.
  """

  @separator "."
  @max 1024

  @doc "The largest number of partitions a namespace can declare."
  @spec max_partitions() :: pos_integer
  def max_partitions, do: @max

  @doc "The partition, in `0..n-1`, of `partition_key`."
  @spec index(binary, pos_integer) :: non_neg_integer
  def index(partition_key, n) when is_binary(partition_key) and is_integer(n) and n > 0 do
    <<hash::unsigned-big-64, _::binary>> = :crypto.hash(:sha256, partition_key)
    rem(hash, n)
  end

  @doc "The key of partition `index` of the logical `key`."
  @spec key(String.t(), non_neg_integer) :: String.t()
  def key(key, index), do: Integer.to_string(index) <> @separator <> key

  @doc """
  The physical address of the logical cell `{namespace, key}` for
  `partition_key`. `{:error, :invalid_key}` when `key` is empty or contains
  `/` or a NUL byte, `{:error, :invalid_partition_key}` when `partition_key`
  is not a binary.
  """
  @spec address({String.t(), String.t()}, term, pos_integer) ::
          {:ok, Atanor.Cell.address()} | {:error, :invalid_key | :invalid_partition_key}
  def address({ns, key}, partition_key, n) do
    cond do
      not logical?(key) -> {:error, :invalid_key}
      not is_binary(partition_key) -> {:error, :invalid_partition_key}
      true -> {:ok, {ns, key(key, index(partition_key, n))}}
    end
  end

  @doc "The `n` physical addresses of the logical cell `{namespace, key}`, in partition order."
  @spec addresses({String.t(), String.t()}, pos_integer) :: {:ok, [Atanor.Cell.address()]} | {:error, :invalid_key}
  def addresses({ns, key}, n) do
    if logical?(key), do: {:ok, for(i <- 0..(n - 1), do: {ns, key(key, i)})}, else: {:error, :invalid_key}
  end

  @doc """
  Splits a physical key into the logical key and the partition: `{:ok, {key,
  index}}`, `:error` for a key that is not a physical key. Use it on the `cell`
  of an `Atanor.Change` to group the changes by logical cell.
  """
  @spec split(String.t()) :: {:ok, {String.t(), non_neg_integer}} | :error
  def split(physical) when is_binary(physical) do
    with [digits, key] <- String.split(physical, @separator, parts: 2),
         true <- logical?(key),
         {index, ""} when index >= 0 <- Integer.parse(digits),
         true <- Integer.to_string(index) == digits do
      {:ok, {key, index}}
    else
      _ -> :error
    end
  end

  @doc "Whether `key` is a physical key of a namespace with `n` partitions."
  @spec physical?(String.t(), pos_integer) :: boolean
  def physical?(key, n), do: match?({:ok, {_, index}} when index < n, split(key))

  defp logical?(key), do: is_binary(key) and key != "" and not String.contains?(key, ["/", <<0>>])
end
