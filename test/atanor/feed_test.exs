defmodule Atanor.FeedTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Atanor.Test.Await

  alias Atanor.{Change, Env}
  alias Atanor.Test.{AddressCache, Manifests}
  alias AlambiqueTestkit.MemoryStore
  alias AtanorTestkit.Node

  @notes [[1, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"]]
  @domains [[1, "CREATE TABLE domains (id INTEGER PRIMARY KEY, address TEXT)"]]

  defp start(opts \\ []) do
    feed =
      Keyword.merge(
        [poll_ms: 20, page_size: 100, retry_ms: 10, max_backoff_ms: 50, max_backlog: 1_000],
        Keyword.get(opts, :feed, [])
      )

    alambique =
      Keyword.merge(
        # A window of 1 ms is for speed; `linger_ms` must stay below it, so nothing lingers here.
        [feed: [window_ms: 1, linger_ms: 0], op_timeout_ms: 10, skew_margin_ms: 0],
        Keyword.get(opts, :alambique, [])
      )

    manifest =
      Manifests.probe(
        "feed",
        Keyword.merge(
          [module: Atanor.Test.FeedWorker, cells: %{"notes" => @notes, "domains" => @domains}, alarms: true],
          Keyword.get(opts, :manifest, [])
        )
      )

    node =
      Node.start(
        Keyword.merge(
          [workers: [manifest], feed: feed, alambique: alambique],
          Keyword.drop(opts, [:feed, :alambique, :manifest])
        )
      )

    on_exit(fn -> Node.stop(node) end)
    {:ok, deployment} = Atanor.Registry.deployment(node.name, "feed")
    {node, Env.new(node.name, deployment)}
  end

  defp execute(env, ns, key, table, value) do
    assert {:ok, _} = Env.execute(env, {ns, key}, "INSERT INTO #{table} (body) VALUES (?)", [value])
  end

  defp execute_domain(env, key, address) do
    assert {:ok, _} = Env.execute(env, {"domains", key}, "INSERT INTO domains (address) VALUES (?)", [address])
  end

  defp changes(env, namespace, position) do
    assert {:ok, changes, next} = Env.changes(env, namespace, position, 100)
    {changes, next}
  end

  defp await_changes(env, namespace, position, count \\ 1) do
    until(
      fn ->
        {changes, next} = changes(env, namespace, position)
        if length(changes) >= count, do: {changes, next}
      end,
      5_000
    )
  end

  defp flush(ref) do
    receive do
      {:atanor_changes, ^ref, _changes, _position} -> flush(ref)
      {:atanor_feed_dropped, ^ref, _position} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp tailer(name), do: Process.whereis(Atanor.Feed.Tailer.name(name))

  defp gen_calls(pid) do
    case Process.info(pid, :messages) do
      {:messages, messages} -> Enum.count(messages, &match?({:"$gen_call", _, _}, &1))
      _ -> 0
    end
  end

  @doc false
  def handle_feed_event(event, measurements, meta, test_pid),
    do: send(test_pid, {event, measurements, meta})

  defp subscribers(name) do
    case tailer(name) do
      nil ->
        0

      pid ->
        try do
          :sys.get_state(pid).subscribers |> map_size()
        catch
          :exit, _ -> 0
        end
    end
  end

  describe "changes/4" do
    test "returns the granted namespace with plain change data" do
      {_node, env} = start()
      execute(env, "notes", "a", "notes", "hi")
      execute_domain(env, "example.com", "1.2.3.4")

      {changes, next} = await_changes(env, "notes", nil)
      assert next != nil
      assert [%Change{} = change] = changes
      assert change.namespace == "notes"
      assert change.cell == "a"
      assert change.table == "notes"
      assert change.op == :insert
      assert change.key == %{"id" => 1}
      assert change.row == %{"id" => 1, "body" => "hi"}
      assert is_integer(change.txid) and change.txid > 0
      assert is_integer(change.at) and change.at > 0
      assert is_binary(change.id)

      assert {:error, {:not_granted, {:cell, "other"}}} = Env.changes(env, "other", nil, 10)
      assert {:error, :bad_limit} = Env.changes(env, "notes", nil, 0)
      assert {:error, :bad_position} = Env.changes(env, "notes", "not-a-position", 10)
    end

    test "Atanor's own tables never enter the feed" do
      {_node, env} = start()
      assert :ok = Env.set_alarm(env, {"notes", "a"}, System.os_time(:millisecond) + 60_000, "later")
      execute(env, "notes", "a", "notes", "hi")

      {changes, _next} = await_changes(env, "notes", nil)
      assert Enum.all?(changes, &(&1.table == "notes"))

      # The alarm row is in the cell, and the feed read below has settled past it.
      assert {:ok, %{rows: [[1]]}} =
               Atanor.Cell.query(env.instance, {"notes", "a"}, "SELECT count(*) FROM _atanor_alarms")

      {:ok, records, _next} = Atanor.Feed.read_records(env.instance, nil, 100)
      assert Enum.any?(records, &(&1.table == "notes"))
      refute Enum.any?(records, &String.starts_with?(&1.table, "_atanor_"))
    end

    test "continues from next_position and change ids are stable" do
      {_node, env} = start()
      execute(env, "notes", "a", "notes", "first")
      {[first], next} = await_changes(env, "notes", nil)
      assert %Change{id: id} = first

      {again, _next} = changes(env, "notes", nil)
      assert Enum.any?(again, &(&1.id == id))

      assert {:ok, [], ^next} = Env.changes(env, "notes", next, 100)

      execute(env, "notes", "b", "notes", "second")
      {second, _next} = await_changes(env, "notes", next)
      assert [%Change{cell: "b"}] = second
    end

    test "feed_position starts after the changes that were already there" do
      {_node, env} = start()
      execute(env, "notes", "a", "notes", "old")
      {_old, _next} = await_changes(env, "notes", nil)
      position = Env.feed_position(env, :now)
      assert is_binary(position)
      assert {:ok, [], ^position} = Env.changes(env, "notes", position, 100)

      execute(env, "notes", "b", "notes", "new")
      {[change], _next} = await_changes(env, "notes", position)
      assert change.cell == "b"
    end
  end

  describe "groups of batches" do
    # What a record carries (its id, from the cell and its TXID, and its TXID) must not depend on grouping.
    defp identity(changes), do: Enum.map(changes, &{&1.id, &1.txid, &1.row["body"]})

    test "a group is one object: limit counts objects, and each change arrives once, in order, as without groups" do
      # A window of 1 ms makes every batch late; Alambique still keys the objects in commit order.
      {_plain, plain_env} = start()
      for i <- 1..16, do: execute(plain_env, "notes", "a", "notes", "b#{i}")
      {plain, _next} = await_changes(plain_env, "notes", nil, 16)

      # The group closes when the 16th batch arrives, not at the linger, so the clock only has to leave room
      # for the commits: a linger of a tenth of the window (the most Atanor accepts) is 1 s. The object is
      # readable after the window, 10 s.
      {_node, env} = start(alambique: [feed: [window_ms: 10_000, object_batches: 16, linger_ms: 1_000]])
      {:ok, ref} = Env.subscribe(env, "notes", from: nil)

      for i <- 1..16, do: execute(env, "notes", "a", "notes", "b#{i}")

      assert {:ok, [_ | _] = page, next} =
               until(
                 fn ->
                   case Env.changes(env, "notes", nil, 1) do
                     {:ok, [_ | _], _} = found -> found
                     _ -> nil
                   end
                 end,
                 30_000
               )

      assert identity(page) == identity(plain)
      assert length(Enum.uniq_by(page, & &1.id)) == 16
      assert {:ok, [], ^next} = Env.changes(env, "notes", next, 1)

      # A message position is the cursor of the stream, not of a record: the object key after a catch-up read,
      # or the live position of the tailer. Either one resumes after the group.
      assert_receive {:atanor_changes, ^ref, ^page, position}, 30_000
      assert {:ok, [], _} = Env.changes(env, "notes", position, 100)
      refute_receive {:atanor_changes, ^ref, _, _}, 100
    end
  end

  describe "a rewound cell" do
    # Two notes in `a`, then the cell goes back to the first one.
    defp rewind_a(node, env) do
      execute(env, "notes", "a", "notes", "keep")
      {:ok, %{txid: target}} = Atanor.Cell.position(node.name, {"notes", "a"})
      execute(env, "notes", "a", "notes", "undone")
      assert {:ok, rewind} = Atanor.Cell.rewind(node.name, {"notes", "a"}, {:txid, target})
      # The marker is published when the cell wakes.
      assert {:ok, %{rows: [[1]]}} = Env.query(env, {"notes", "a"}, "SELECT count(*) FROM notes")
      {target, rewind}
    end

    # The rewind republishes the target batch, so a change can come twice (delivery is at least once):
    # wait for the marker, which follows it, and drop the repeats.
    defp await_marker(env) do
      until(
        fn ->
          {changes, _next} = changes(env, "notes", nil)
          if Enum.any?(changes, &match?(%Change.Rewind{}, &1)), do: dedupe(changes)
        end,
        5_000
      )
    end

    defp dedupe(changes), do: Enum.uniq_by(changes, & &1.id)

    defp collect_until_marker(ref, acc) do
      assert_receive {:atanor_changes, ^ref, changes, _position}, 5_000
      acc = acc ++ changes
      if Enum.any?(acc, &match?(%Change.Rewind{}, &1)), do: acc, else: collect_until_marker(ref, acc)
    end

    test "changes/4 returns the marker after the changes it undoes" do
      {node, env} = start()
      {target, rewind} = rewind_a(node, env)

      changes = await_marker(env)

      assert [%Change{row: %{"body" => "keep"}}, %Change{row: %{"body" => "undone"}}, %Change.Rewind{} = marker] =
               changes

      assert %Change.Rewind{
               namespace: "notes",
               cell: "a",
               from_txid: from,
               to_txid: ^target,
               txid: txid,
               target: {:txid, ^target},
               kept: kept
             } = marker

      assert {from, txid, kept} == {rewind.from, rewind.txid, rewind.kept}
      assert marker.id == "notes.a:#{txid}:rewind"
      assert is_integer(marker.at) and marker.at > 0
    end

    test "a subscriber receives the marker and only for its namespace" do
      {node, env} = start()
      {:ok, ref} = Env.subscribe(env, "notes", from: nil)
      {:ok, other} = Env.subscribe(env, "domains", from: nil)
      {_target, _rewind} = rewind_a(node, env)

      all = ref |> collect_until_marker([]) |> dedupe()
      assert [%Change{}, %Change{}, %Change.Rewind{cell: "a"}] = all
      refute_receive {:atanor_changes, ^other, _changes, _position}, 200
    end
  end

  describe "a backlog" do
    test "is read page after page without waiting for the poll interval" do
      {_node, env} = start(feed: [poll_ms: 1_000, page_size: 2])
      for i <- 1..12, do: execute(env, "notes", "k#{i}", "notes", "x")

      started = System.monotonic_time(:millisecond)
      {:ok, ref} = Env.subscribe(env, "notes", from: nil)
      assert length(collect(ref, 12)) == 12

      # Pages of 2 objects, one per second, would take 6 seconds.
      assert System.monotonic_time(:millisecond) - started < 3_500
    end
  end

  defp collect(_ref, count) when count <= 0, do: []

  defp collect(ref, count) do
    assert_receive {:atanor_changes, ^ref, changes, _position}, 5_000
    changes ++ collect(ref, count - length(changes))
  end

  describe "rejected objects" do
    # An object Alambique cannot decode comes as `%Alambique.Feed.Rejected{}` and belongs to no namespace.
    defp put_junk(node, cell, body \\ "not json", txid \\ 1, offset_ms \\ -1_000) do
      prefix = Atanor.Registry.config(node.name).prefix <> "/cells"
      {mod, config} = node.store

      key =
        Alambique.Feed.Keys.object(
          prefix,
          Alambique.Feed.Keys.default_shards(),
          cell,
          System.system_time(:millisecond) + offset_ms,
          txid
        )

      {:ok, _} = mod.put(config, key, body, :if_none_match, %{})
    end

    test "keep/2 and the counts skip them, and report_rejected/3 emits one event each" do
      rejected = %Alambique.Feed.Rejected{key: "k", reason: {:unsupported_format, 9}, id: "rejected:k", at: 1}
      other = %Alambique.Feed.Rejected{key: "j", reason: :invalid_json, id: "rejected:j", at: 1}
      assert [] = Atanor.Feed.keep([rejected], "notes")
      assert 0 = Atanor.Feed.kept_count([rejected, rejected])

      :telemetry.attach("rejected-event-test", [:atanor, :feed, :rejected], &__MODULE__.handle_feed_event/4, self())
      on_exit(fn -> :telemetry.detach("rejected-event-test") end)

      assert [^rejected, ^other] = Atanor.Feed.report_rejected(:feed_unit, "notes", [rejected, other])
      assert [] = Atanor.Feed.report_rejected(:feed_unit, "notes", [])

      assert_receive {[:atanor, :feed, :rejected], %{count: 1},
                      %{instance: :feed_unit, namespace: "notes", reason: {:unsupported_format, 9}, key: "k"}}

      assert_receive {[:atanor, :feed, :rejected], %{count: 1}, %{reason: :invalid_json, key: "j"}}
      refute_receive {[:atanor, :feed, :rejected], _, _}, 50
    end

    # An object of a newer format than this node reads: a subscriber that catches up reads it in its own page
    # (`from: nil`, objects in the past), the shared stream when the object is published after `from: :now`.
    for {name, from, offset_ms, namespace} <- [{"catching up", nil, -1_000, "notes"}, {"live", :now, 300, nil}] do
      test "an object of an unsupported format is counted each time and logged once per interval, #{name}" do
        # A longer backoff than the poll, so the second object falls in the interval of the first warning.
        {node, env} = start(feed: [max_backoff_ms: 60_000])
        :telemetry.attach("rejected-format-test", [:atanor, :feed, :rejected], &__MODULE__.handle_feed_event/4, self())
        on_exit(fn -> :telemetry.detach("rejected-format-test") end)

        newer = "ALF" <> <<9>> <> "payload"
        {:ok, ref} = Env.subscribe(env, "notes", from: unquote(from))

        log =
          capture_log(fn ->
            # One at a time, so each is read by a poll of its own.
            for {cell, txid} <- [{"newer-1", 1}, {"newer-2", 2}] do
              put_junk(node, cell, newer, txid, unquote(offset_ms))

              assert_receive {[:atanor, :feed, :rejected], %{count: 1},
                              %{reason: {:unsupported_format, 9}, key: key, namespace: unquote(namespace)}},
                             5_000

              assert key =~ cell
            end

            # The tailer goes on: a change after the objects still arrives.
            execute(env, "notes", "after", "notes", "x")
            assert_receive {:atanor_changes, ^ref, [%Change{cell: "after"}], _position}, 5_000
          end)

        assert [_] = Regex.scan(~r/change feed skipped/, log)
        assert log =~ "unsupported_format"
      end
    end

    test "a bad object neither stops reads nor the tailer, and is counted" do
      {node, env} = start()
      :telemetry.attach("rejected-feed-test", [:atanor, :feed, :read], &__MODULE__.handle_feed_event/4, self())
      on_exit(fn -> :telemetry.detach("rejected-feed-test") end)

      put_junk(node, "junk")
      execute(env, "notes", "a", "notes", "after")
      {:ok, ref} = Env.subscribe(env, "notes", from: nil)

      assert_receive {:atanor_changes, ^ref, [%Change{cell: "a"}], _position}, 5_000
      assert {[%Change{cell: "a"}], _} = await_changes(env, "notes", nil)
      assert_receive {[:atanor, :feed, :read], %{rejected: 1}, _meta}, 5_000
    end
  end

  describe "feed selection" do
    @posts [[1, "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, body TEXT)"]]

    defp post(env, sql, params), do: assert({:ok, _} = Env.execute(env, {"posts", "a"}, sql, params))

    defp posts_feed(alambique) do
      {node, env} =
        start(
          alambique: [feed: [window_ms: 1, linger_ms: 0] ++ alambique],
          manifest: [cells: %{"posts" => @posts}]
        )

      post(env, "INSERT INTO posts (title, body) VALUES (?, ?)", ["t", String.duplicate("big ", 100)])
      post(env, "UPDATE posts SET body = ? WHERE id = 1", ["only the body changed"])
      post(env, "UPDATE posts SET title = ? WHERE id = 1", ["t2"])
      post(env, "INSERT INTO posts (title, body) VALUES (?, NULL)", ["no body"])
      post(env, "DELETE FROM posts WHERE id = 2", [])
      {node, env}
    end

    test "an omitted column is absent from the row, and an update of only omitted columns is no change" do
      {_node, env} = posts_feed(tables: %{"posts" => [omit: ["body"]]})
      {changes, _next} = await_changes(env, "posts", nil, 4)

      assert [
               %{op: :insert, key: %{"id" => 1}, row: %{"id" => 1, "title" => "t"} = insert},
               %{op: :update, key: %{"id" => 1}, row: %{"id" => 1, "title" => "t2"} = update},
               %{op: :insert, key: %{"id" => 2}, row: %{"id" => 2, "title" => "no body"} = second},
               %{op: :delete, key: %{"id" => 2}, row: nil}
             ] = changes

      # Absent, not NULL: the key is not there at all.
      for row <- [insert, update, second], do: refute(Map.has_key?(row, "body"))
    end

    test "without a selection every column is there, and a NULL column is nil" do
      {_node, env} = posts_feed([])
      {changes, _next} = await_changes(env, "posts", nil, 5)

      assert [%{row: %{"body" => "big " <> _}}, %{row: %{"body" => "only the body changed"}}, _, %{row: second}, _] =
               changes

      assert %{"id" => 2, "title" => "no body", "body" => nil} = second
    end

    test "the objects are zlib-compressed with the format byte 1" do
      {node, env} = posts_feed([])
      {changes, _} = await_changes(env, "posts", nil, 5)
      assert length(changes) == 5

      {store, config} = node.store
      prefix = Atanor.Registry.config(node.name).prefix <> "/cells/feed/"
      {:ok, keys, _} = store.list(config, prefix, nil, 100)
      bodies = for key <- keys, do: elem(store.get(config, key), 1)
      assert bodies != [] and Enum.all?(bodies, &match?(<<"ALF", 1, _::binary>>, &1))
    end
  end

  describe "subscribe/3" do
    test "a write in the namespace reaches the subscriber and another namespace does not" do
      {node, env} = start()
      assert {:ok, ref} = Env.subscribe(env, "notes")

      assert {:error, {:not_granted, {:cell, "other"}}} = Env.subscribe(env, "other", from: :now)
      assert {:error, {:invalid_option, :from}} = Env.subscribe(env, "notes", from: 123)

      execute(env, "notes", "a", "notes", "hi")
      assert_receive {:atanor_changes, ^ref, [%Change{cell: "a"}], position}, 5_000
      assert is_binary(position)

      flush(ref)
      execute_domain(env, "example.com", "1.2.3.4")
      refute_receive {:atanor_changes, ^ref, _changes, _position}, 200

      assert :ok = Env.unsubscribe(env, ref)
      until(fn -> tailer(node.name) == nil end)

      execute(env, "notes", "b", "notes", "after")
      refute_receive {:atanor_changes, ^ref, _changes, _position}, 200
    end

    test "a subscriber that exits is removed and stops the tailer" do
      {node, env} = start()
      parent = self()

      pid =
        spawn(fn ->
          {:ok, ref} = Env.subscribe(env, "notes", from: :now)
          send(parent, {:subscribed, self(), ref})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:subscribed, ^pid, _ref}, 5_000
      until(fn -> subscribers(node.name) == 1 end)
      Process.exit(pid, :kill)
      until(fn -> tailer(node.name) == nil end)
    end

    test "a stuck subscriber is dropped after max_backlog with its position" do
      {_node, env} = start(feed: [max_backlog: 2, poll_ms: 10])
      parent = self()

      pid =
        spawn(fn ->
          {:ok, ref} = Env.subscribe(env, "notes", from: :now)
          send(parent, {:subscribed, self(), ref})

          receive do
            {:atanor_feed_dropped, ^ref, position} -> send(parent, {:dropped, self(), ref, position})
          end
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive {:subscribed, ^pid, ref}, 5_000

      for n <- 1..10 do
        execute(env, "notes", "k#{n}", "notes", "v#{n}")
        Process.sleep(30)
      end

      assert_receive {:dropped, ^pid, ^ref, position}, 5_000
      assert is_binary(position)
    end

    test "a store error is retried and does not drop subscribers" do
      {node, env} = start(feed: [poll_ms: 10, retry_ms: 10, max_backoff_ms: 20])
      test_pid = self()
      handler = make_ref()

      :telemetry.attach(
        handler,
        [:atanor, :feed, :error],
        &__MODULE__.handle_feed_event/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, ref} = Env.subscribe(env, "notes", from: :now)
      {MemoryStore, config} = node.store
      fault = MemoryStore.inject(config, kind: :error, ops: [:list], key: ~r{/feed/}, times: 2)
      on_exit(fn -> MemoryStore.remove(config, fault) end)

      execute(env, "notes", "a", "notes", "hi")

      assert_receive {:atanor_changes, ^ref, [%Change{cell: "a"}], _position}, 5_000
      assert_receive {[:atanor, :feed, :error], %{count: 1}, %{reason: _reason}}, 5_000
      refute_receive {:atanor_feed_dropped, ^ref, _position}, 100
    end

    test "a store that does not answer in time is an unavailable store" do
      {node, env} = start()
      execute(env, "notes", "a", "notes", "hi")
      {MemoryStore, config} = node.store
      fault = MemoryStore.inject(config, kind: :latency, ops: [:list], key: ~r{/feed/}, ms: 500)
      on_exit(fn -> MemoryStore.remove(config, fault) end)

      assert {:error, {:store, :timeout}} = Atanor.Feed.read_records(node.name, nil, 10)
      assert {:error, {:store, :timeout}} = Env.changes(env, "notes", nil, 10)
      assert Atanor.Unavailable.reason({:store, :timeout}) == :store_unavailable
    end

    test "a :now subscriber repeats changes inside the skew margin" do
      {_node, env} =
        start(
          feed: [poll_ms: 10],
          alambique: [
            clock: {AlambiqueTestkit.Clock, nil},
            skew_margin_ms: 200,
            feed: [window_ms: 1, linger_ms: 0],
            op_timeout_ms: 10
          ]
        )

      on_exit(fn -> AlambiqueTestkit.Clock.set_offset(0) end)
      assert {:ok, ref} = Env.subscribe(env, "notes", from: :now)

      # The publisher's clock is behind the subscriber's by less than the
      # margin. The commit happens after subscribe, but its record time is
      # before the subscriber's now.
      AlambiqueTestkit.Clock.set_offset(-150)
      execute(env, "notes", "a", "notes", "behind")
      AlambiqueTestkit.Clock.set_offset(0)

      assert_receive {:atanor_changes, ^ref, [%Change{cell: "a"}], _position}, 5_000
    end

    test "a subscribe racing a stopping tailer retries" do
      {node, env} = start(feed: [poll_ms: 10])
      assert {:ok, ref} = Env.subscribe(env, "notes", from: :now)
      pid = tailer(node.name)
      assert is_pid(pid)
      assert :ok = :sys.suspend(pid)

      unsubscribe = Task.async(fn -> Env.unsubscribe(env, ref) end)
      until(fn -> gen_calls(pid) >= 1 end)

      subscribe = Task.async(fn -> Env.subscribe(env, "notes", from: :now) end)
      until(fn -> gen_calls(pid) >= 2 end)

      assert :ok = :sys.resume(pid)
      assert :ok = Task.await(unsubscribe)
      assert {:ok, new_ref} = Task.await(subscribe)
      assert :ok = Env.unsubscribe(env, new_ref)
    end

    test "a subscriber that starts older catches up while a current subscriber does not" do
      {_node, env} = start()
      execute(env, "notes", "a", "notes", "old")
      {[old], _next} = await_changes(env, "notes", nil)
      assert %Change{id: old_id} = old

      assert {:ok, current} = Env.subscribe(env, "notes", from: :now)
      assert {:ok, older} = Env.subscribe(env, "notes", from: nil)

      assert_receive {:atanor_changes, ^older, [%Change{id: ^old_id}], _position}, 5_000
      flush(current)
      refute_receive {:atanor_changes, ^current, _changes, _position}, 200

      execute(env, "notes", "b", "notes", "new")
      assert_receive {:atanor_changes, ^current, [%Change{cell: "b"}], _position}, 5_000
      assert_receive {:atanor_changes, ^older, [%Change{cell: "b"}], _position}, 5_000
    end
  end

  test "an address cache evicts a domain when its cell changes" do
    {_node, env} = start()
    {:ok, cache} = AddressCache.start_link({env, %{"a" => "1.1.1.1", "b" => "2.2.2.2"}})
    on_exit(fn -> if Process.alive?(cache), do: GenServer.stop(cache) end)

    execute_domain(env, "a", "9.9.9.9")
    assert until(fn -> AddressCache.entries(cache) == %{"b" => "2.2.2.2"} end)

    assert :ok = AddressCache.put(cache, "a", "8.8.8.8")
    execute_domain(env, "b", "7.7.7.7")
    assert until(fn -> AddressCache.entries(cache) == %{"a" => "8.8.8.8"} end)
  end
end
