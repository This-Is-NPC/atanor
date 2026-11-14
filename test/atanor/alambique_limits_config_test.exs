defmodule Atanor.AlambiqueLimitsConfigTest do
  use ExUnit.Case, async: true

  alias Atanor.Config

  defp build(alambique) do
    Config.build(
      name: :limits_config,
      store: {AlambiqueTestkit.MemoryStore, %{}},
      data_dir: System.tmp_dir!(),
      port: 0,
      alambique: alambique
    )
  end

  test "the limits of Alambique are passed through unchanged" do
    alambique = [
      sql: [statement_timeout_ms: 500, max_result_rows: 10, max_result_bytes: 1_000],
      awake: [max_cells: 5, max_wakes: 2, wake_queue_ms: 100, max_wake_queue: 7, max_pending: 9],
      local_cache: [max_bytes: 1_000_000, interval_ms: 5_000],
      wal: [checkpoint_bytes: 1_000_000, checkpoint_deadline_ms: 2_000, max_bytes: 5_000_000, budget_interval_ms: 500]
    ]

    config = build(alambique)

    for {key, value} <- alambique,
        do: assert(Keyword.take(config.alambique_opts[key], Keyword.keys(value)) |> Enum.sort() == Enum.sort(value))
  end

  test "the statement slots, the script deadline and the moved-cell scan are passed through" do
    alambique = [
      sql: [script_timeout_ms: 5_000, max_concurrent_statements: 3],
      compaction: [
        moved_scan_ms: 1_000,
        moved_scan_page: 10,
        release_min_tail: 8,
        release_deadline_ms: 0,
        release_reserve_ms: 0
      ],
      replicas: [poll_max_ms: 2_000],
      query: [reflink: false]
    ]

    config = build(alambique)
    for {key, value} <- alambique, do: assert(Keyword.take(config.alambique_opts[key], Keyword.keys(value)) == value)

    for bad <- [
          [sql: [max_concurrent_statements: 0]],
          [compaction: [moved_scan_page: 1.5]],
          [compaction: [release_min_tail: 0]],
          [compaction: [release_deadline_ms: -1]],
          [compaction: [release_reserve_ms: 1.5]],
          [sql: [script_timeout_ms: -1]]
        ] do
      assert_raise ArgumentError, fn -> build(bad) end
    end
  end

  test "the registry is off by default and its options are checked" do
    assert build([]).alambique_opts[:registry] == nil
    assert build(registry: false).alambique_opts[:registry] == false

    registry = [advertise: "10.0.0.1:4000", meta: %{"zone" => "a"}, ttl_ms: 30_000, renew_ms: 10_000, sweep_ms: 60_000]
    assert build(registry: registry).alambique_opts[:registry] == registry

    for bad <- [
          [registry: true],
          [registry: []],
          [registry: [advertise: ""]],
          [registry: [advertise: "a", meta: []]],
          [registry: [advertise: "a", ttl_ms: 0]],
          [registry: [advertise: "a", page_size: 1.5]],
          [registry: [advertise: "a", other: 1]]
        ] do
      assert_raise ArgumentError, ~r/:registry/, fn -> build(bad) end
    end
  end

  test "compaction and feed options are passed through, zero is allowed" do
    config =
      build(
        compaction: [hold_bytes: 0, hold_object_bytes: 0],
        feed: [object_batches: 4, linger_ms: 0, stop_publish_ms: 0]
      )

    assert config.alambique_opts[:compaction] == [hold_bytes: 0, hold_object_bytes: 0]
    assert config.alambique_opts[:feed][:object_batches] == 4
    assert config.alambique_opts[:feed][:linger_ms] == 0
    assert config.alambique_opts[:feed][:stop_publish_ms] == 0
    assert build(feed: [window_ms: 5_000]).alambique_opts[:feed][:window_ms] == 5_000
  end

  test "the snapshot, restore and lazy restore options are passed through" do
    alambique = [
      compaction: [
        snapshot_ratio: 1.5,
        snapshot_keep_ms: 0,
        snapshot_interval_ms: 86_400_000,
        delete_superseded: false,
        max_level: 3
      ],
      restore: [fetch_concurrency: 8, max_inflight_bytes: 1_000_000],
      lazy_restore: [min_bytes: 16_777_216],
      feed: [retention_ms: 1_209_600_000]
    ]

    config = build(alambique)

    for {key, value} <- alambique,
        do: assert(Keyword.take(config.alambique_opts[key], Keyword.keys(value)) == value)

    assert build(lazy_restore: [min_bytes: 0])
    assert build(lazy_restore: false)
    assert build(feed: [retention_ms: nil]).alambique_opts[:feed][:retention_ms] == nil
  end

  test "the feed retention is Alambique's unless the operator sets it" do
    feed = build([]).alambique_opts[:feed]
    refute Keyword.has_key?(feed, :retention_ms)
  end

  test "the change feed cannot be turned off" do
    assert_raise ArgumentError, ~r/:alambique :feed cannot be false: Atanor reads the change feed/, fn ->
      build(feed: false)
    end
  end

  test "the feed groups 16 batches and lingers 250 ms unless the operator says otherwise" do
    feed = build([]).alambique_opts[:feed]
    assert {feed[:object_batches], feed[:linger_ms]} == {16, 250}
    assert feed[:stop_publish_ms] == nil

    feed = build(feed: [object_batches: 1]).alambique_opts[:feed]
    assert {feed[:object_batches], feed[:linger_ms]} == {1, 250}
    feed = build(feed: [linger_ms: 100]).alambique_opts[:feed]
    assert {feed[:object_batches], feed[:linger_ms]} == {16, 100}
  end

  test "linger_ms is at most a tenth of window_ms while batches are grouped" do
    assert build(feed: [window_ms: 2_500]).alambique_opts[:feed][:window_ms] == 2_500
    assert build(feed: [window_ms: 1_000, linger_ms: 100])
    assert build(feed: [window_ms: 1, object_batches: 1])
    assert build(feed: [window_ms: 1, linger_ms: 0])

    for bad <- [
          [feed: [window_ms: 2_499]],
          [feed: [window_ms: 1]],
          [feed: [linger_ms: 1_001]],
          [feed: [window_ms: 1_000, linger_ms: 101]]
        ] do
      assert_raise ArgumentError, ~r/:linger_ms .* at most 1\/10 of :window_ms/, fn -> build(bad) end
    end
  end

  test "local_cache can be turned off, and every limit is optional" do
    assert build(local_cache: false)
    assert build(sql: [], awake: [max_cells: 1], wal: [])
  end

  test "an unknown key or a value that is not a positive integer is refused at start" do
    for bad <- [
          [sql: [timeout: 1]],
          [sql: [statement_timeout_ms: 0]],
          [sql: [max_result_rows: 1.5]],
          [sql: :fast],
          [awake: [max_cells: -1]],
          [awake: [max_pending: "9"]],
          [wal: [checkpoint_bytes: nil]],
          [local_cache: [max_bytes: 0]],
          [local_cache: true],
          [local_cache: [size: 1]],
          [compaction: [hold_bytes: -1]],
          [compaction: [hold_object_bytes: 1.5]],
          [compaction: [budget: 1]],
          [compaction: [snapshot_ratio: 0]],
          [compaction: [snapshot_ratio: "2"]],
          [compaction: [snapshot_keep_ms: -1]],
          [compaction: [snapshot_interval_ms: 0]],
          [compaction: [delete_superseded: 1]],
          [compaction: [max_level: 0]],
          [restore: [fetch_concurrency: 0]],
          [restore: [max_inflight_bytes: 1.5]],
          [awake: [wake_queue_ms: 0]],
          [awake: [max_wake_queue: nil]],
          [wal: [max_bytes: 0]],
          [wal: [budget_interval_ms: 1.5]],
          [restore: [prefetch_bytes: 1_000]],
          [restore: [window: 1]],
          [lazy_restore: [min_bytes: -1]],
          [lazy_restore: [concurrency: 0]],
          [lazy_restore: true],
          [lazy_restore: [size: 1]],
          [feed: [retention_ms: 0]],
          [feed: [retention_ms: "7d"]],
          [feed: [object_batches: 0]],
          [feed: [object_batches: "4"]],
          [feed: [linger_ms: -1]],
          [feed: [linger_ms: 1.5]],
          [feed: [stop_publish_ms: -1]],
          [feed: [stop_publish_ms: 1.5]]
        ] do
      assert_raise ArgumentError, ~r/:alambique/, fn -> build(bad) end
    end
  end

  test "the feed selection and object size are passed through to Alambique" do
    tables = %{"messages" => [omit: ["body"]], "parts" => false, "tags" => [only: ["name"]], "users" => true}

    feed =
      build(feed: [tables: tables, other_tables: :skip, max_object_bytes: 1_048_576]).alambique_opts[
        :feed
      ]

    assert feed[:tables] == tables
    assert {feed[:other_tables], feed[:max_object_bytes]} == {:skip, 1_048_576}
  end

  test "the feed selection defaults are Alambique's: nothing is set by Atanor" do
    feed = build([]).alambique_opts[:feed]
    for key <- [:tables, :other_tables, :max_object_bytes], do: refute(Keyword.has_key?(feed, key))
  end

  test "a feed selection or object size of the wrong shape is refused with a message" do
    for {bad, message} <- [
          {[tables: [messages: true]], ~r/:tables must be a map of non-empty table name to true, false/},
          {[tables: %{"" => true}], ~r/:tables must be a map/},
          {[tables: %{messages: true}], ~r/:tables must be a map/},
          {[tables: %{"messages" => :omit}], ~r/:tables must be a map/},
          {[tables: %{"messages" => [omit: "body"]}], ~r/:tables must be a map/},
          {[tables: %{"messages" => [omit: [:body]]}], ~r/:tables must be a map/},
          {[tables: %{"messages" => [omit: [""]]}], ~r/:tables must be a map/},
          {[tables: %{"messages" => [skip: ["body"]]}], ~r/:tables must be a map/},
          {[tables: %{"messages" => [omit: ["a"], only: ["b"]]}], ~r/:tables must be a map/},
          {[other_tables: :all], ~r/:other_tables must be :capture or :skip/},
          {[other_tables: false], ~r/:other_tables must be :capture or :skip/},
          {[max_object_bytes: 0], ~r/:max_object_bytes must be a positive integer/},
          {[max_object_bytes: "1MB"], ~r/:max_object_bytes must be a positive integer/}
        ] do
      assert_raise ArgumentError, message, fn -> build(feed: bad) end
    end
  end
end
