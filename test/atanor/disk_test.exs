defmodule Atanor.DiskTest do
  @moduledoc "The disk budget: how it is derived, the Alambique options that follow, and the monitor (design §4.4)."
  use ExUnit.Case, async: true

  alias Atanor.{Admission, Config, Disk}
  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Node

  @moduletag :tmp_dir
  @mib 1_048_576
  @gib 1_073_741_824

  defp build(disk, alambique \\ [], data_dir \\ System.tmp_dir!()) do
    Config.build(
      name: :disk_config,
      store: {AlambiqueTestkit.MemoryStore, %{}},
      data_dir: data_dir,
      port: 0,
      alambique: alambique,
      disk: disk
    )
  end

  defp probe(bytes), do: [probe: fn _path -> {:ok, bytes} end]

  describe "the budget" do
    test "max_bytes wins and the file system is not asked" do
      config = build(max_bytes: 5 * @gib, probe: fn _ -> flunk("asked the file system") end)
      assert {config.disk.budget, config.disk.budget_source} == {5 * @gib, :option}
    end

    test "without max_bytes it is a fraction of the file system" do
      config = build(probe(10 * @gib))
      assert {config.disk.budget, config.disk.budget_source} == {8 * @gib, :filesystem}
      assert build(probe(10 * @gib) ++ [fraction: 0.5]).disk.budget == 5 * @gib
    end

    test "it is nil when the file system cannot be read" do
      config = build(probe: fn _ -> :error end)
      assert {config.disk.budget, config.disk.budget_source} == {nil, :none}
      # Alambique keeps its own defaults.
      refute Keyword.has_key?(config.alambique_opts, :wal)
      refute Keyword.has_key?(config.alambique_opts, :local_cache)
    end

    test "a data_dir that does not exist yet is probed at its nearest parent", %{tmp_dir: dir} do
      test = self()

      build(
        [
          probe: fn path ->
            send(test, {:probed, path})
            {:ok, @gib}
          end
        ],
        [],
        Path.join(dir, "a/b/c")
      )

      assert_received {:probed, ^dir}
    end

    test "the default probe reads the size of the file system with df", %{tmp_dir: dir} do
      assert {:ok, bytes} = Disk.filesystem_bytes(dir)
      assert bytes > 0 and rem(bytes, 1024) == 0
      assert Disk.filesystem_bytes(Path.join(dir, "missing")) == :error
    end

    test "wrong values are refused at start" do
      for disk <- [
            [max_bytes: 0],
            [fraction: 0],
            [fraction: 1.5],
            [evict_fraction: 0.01],
            [refuse_fraction: 0.5],
            [refuse_fraction: 1.5],
            [sample_ms: 0],
            [probe: :df],
            [unknown: 1]
          ] do
        assert_raise ArgumentError, fn -> build(disk) end
      end

      assert build(refuse_fraction: nil, max_bytes: 1).disk.refuse_fraction == nil
    end
  end

  describe "the Alambique options" do
    test "are derived from the budget" do
      opts = build(max_bytes: 20 * @gib).alambique_opts
      # 20 GiB / 20 000 cells / 2 is below the 1 MiB floor; the WALs may take half the budget.
      assert opts[:wal][:checkpoint_bytes] == @mib
      assert opts[:local_cache][:max_bytes] == 10 * @gib
      assert opts[:local_cache][:interval_ms] == 5_000
      # The WAL allowance is the half of the budget Alambique checkpoints under, every second at most.
      assert opts[:wal][:max_bytes] == 10 * @gib
      assert opts[:wal][:budget_interval_ms] == 1_000
      assert build(max_bytes: 20 * @gib, sample_ms: 200).alambique_opts[:wal][:budget_interval_ms] == 200
    end

    test "follow the cells a node may hold" do
      opts = build([max_bytes: 4 * @gib], awake: [max_cells: 16]).alambique_opts
      # 4 GiB / 16 / 2 = 128 MiB, above the 64 MiB mark; the WALs may take half the budget.
      assert opts[:wal][:checkpoint_bytes] == 64 * @mib
      assert opts[:local_cache][:max_bytes] == 4 * @gib - 16 * 64 * @mib

      opts = build([max_bytes: 400 * @mib], awake: [max_cells: 100]).alambique_opts
      assert opts[:wal][:checkpoint_bytes] == 2 * @mib
      assert opts[:local_cache][:max_bytes] == 400 * @mib - 200 * @mib
      assert opts[:wal][:max_bytes] == 200 * @mib
    end

    test "the WAL never takes more than half of a small budget" do
      opts = build([max_bytes: 1_000], awake: [max_cells: 1]).alambique_opts
      assert opts[:wal][:checkpoint_bytes] == 500
      assert opts[:wal][:max_bytes] == 500
      assert opts[:local_cache][:max_bytes] == 500
    end

    test "an option the operator gave wins" do
      opts =
        build([max_bytes: 4 * @gib],
          wal: [checkpoint_bytes: 5_000, max_bytes: 6_000, budget_interval_ms: 8_000],
          local_cache: [max_bytes: 7_000, interval_ms: 9_000]
        ).alambique_opts

      assert opts[:wal][:checkpoint_bytes] == 5_000
      assert opts[:wal][:max_bytes] == 6_000
      assert opts[:wal][:budget_interval_ms] == 8_000
      assert opts[:local_cache][:max_bytes] == 7_000
      assert opts[:local_cache][:interval_ms] == 9_000
    end

    test "local_cache: false stays off" do
      opts = build([max_bytes: 4 * @gib], local_cache: false).alambique_opts
      assert opts[:local_cache] == false
      assert opts[:wal][:checkpoint_bytes] == @mib
    end
  end

  describe "usage" do
    test "adds up the files, and tells each cell", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "a.b.cell"))
      File.write!(Path.join(dir, "a.b.cell/cell.db"), String.duplicate("x", 100))
      File.write!(Path.join(dir, "a.b.cell/cell.db-wal"), String.duplicate("x", 30))
      File.mkdir_p!(Path.join(dir, "diagnostics/pending"))
      File.write!(Path.join(dir, "diagnostics/pending/r.json"), "12345")
      File.write!(Path.join(dir, "lock"), "")

      assert {135, [%{id: "a.b", bytes: 130}]} = Disk.usage(dir)
      assert Disk.usage(Path.join(dir, "missing")) == {0, []}
    end
  end

  describe "the checkpoint at the derived mark" do
    # Alambique checkpoints with SQLITE_CHECKPOINT_TRUNCATE: the WAL of an awake cell shrinks to nothing.
    test "truncates the WAL of an awake cell, which never passes the mark by much" do
      node = Node.start(workers: [Manifests.counter("w")], disk: [max_bytes: 20 * @gib])
      on_exit(fn -> Node.stop(node) end)
      wal = Path.join(node.data_dir, "log.wal.cell/cell.db-wal")

      sizes =
        for _ <- 1..400 do
          Req.post!(node.url <> "/c/wal", body: "1", retry: false)
          Await.until(fn -> match?({:ok, _}, File.stat(wal)) end)
          File.stat!(wal).size
        end

      peak = Enum.max(sizes)
      assert peak >= div(@mib, 2), "the WAL never grew: #{peak}"
      # A fall to less than a tenth of the peak is a truncation, not a smaller write.
      assert Enum.chunk_every(sizes, 2, 1, :discard) |> Enum.any?(fn [a, b] -> b < div(a, 10) end)
      assert peak < @mib + @mib
    end
  end

  def reclaimed(_event, measures, %{instance: name}, {test, name}), do: send(test, {:reclaimed, measures})
  def reclaimed(_event, _measures, _meta, _config), do: :ok

  describe "the monitor" do
    test "hibernates idle cells when the disk passes the eviction mark, and the gate follows" do
      # The WAL mark and allowance are Alambique's 64 MiB, so one cell's WAL alone passes 70% of the budget.
      node =
        Node.start(
          workers: [Manifests.counter("w")],
          disk: [max_bytes: 4 * @mib, sample_ms: 50],
          alambique: [wal: [checkpoint_bytes: 64 * @mib, max_bytes: 64 * @mib]]
        )

      on_exit(fn -> Node.stop(node) end)
      test = self()
      handler = {__MODULE__, make_ref()}
      :telemetry.attach(handler, [:atanor, :disk, :reclaim], &__MODULE__.reclaimed/4, {test, node.name})
      on_exit(fn -> :telemetry.detach(handler) end)

      write = fn -> Req.post!(node.url <> "/c/big", body: "1", retry: false).status end

      Await.until(
        fn ->
          assert write.() in [200, 503]

          receive do
            {:reclaimed, %{hibernated: n}} when n > 0 -> true
          after
            0 -> false
          end
        end,
        20_000
      )

      assert Admission.stats(node.name).disk_budget_bytes == 4 * @mib
      Await.until(fn -> match?({_, :ok}, Disk.status(node.name)) end, 10_000)
      assert write.() == 200
    end

    test "refuses with 503 above the refuse mark and admits again below it" do
      node = Node.start(workers: [Manifests.counter("w")], disk: [max_bytes: 100_000, sample_ms: 50])
      on_exit(fn -> Node.stop(node) end)

      filler = Path.join(node.data_dir, "filler")
      File.write!(filler, :binary.copy("x", 99_000))

      Await.until(fn -> Admission.stats(node.name).disk_refusing end)

      assert %{status: 503, headers: %{"retry-after" => ["1"]}, body: %{"error" => "overloaded"}} =
               Req.post!(node.url <> "/c/a", body: "1", retry: false)

      assert Admission.stats(node.name).refused.disk >= 1

      File.rm!(filler)
      Await.until(fn -> not Admission.stats(node.name).disk_refusing end)
      assert %{status: 200} = Req.post!(node.url <> "/c/a", body: "1", retry: false)
    end
  end
end
