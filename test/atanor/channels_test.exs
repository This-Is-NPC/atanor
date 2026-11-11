defmodule Atanor.ChannelsTest do
  @moduledoc "Ephemeral channels of native and WASM workers on one node (design §7.6)."
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import Atanor.Test.Await

  alias Atanor.{Cell, Channels, Env, Registry}
  alias Atanor.Test.{ChannelWorker, Manifests, WSClient, WasmCase}
  alias AtanorTestkit.Node

  @log [[1, "CREATE TABLE log (id INTEGER PRIMARY KEY, socket TEXT NOT NULL)"]]
  @routes [{"127.0.0.1", "/"}]

  defp start_native(opts \\ [], node_opts \\ []) do
    manifest =
      Manifests.probe(
        "chan",
        Keyword.merge([module: ChannelWorker, sockets: true, cells: %{"rooms" => @log}, routes: @routes], opts)
      )

    node = Node.start([workers: [manifest]] ++ node_opts)
    on_exit(fn -> Node.stop(node) end)
    capture([[:atanor, :call], [:atanor, :channel, :publish], [:atanor, :channel, :rejected]])
    node
  end

  defp start_wasm(node_opts \\ []) do
    node =
      WasmCase.start([{"wchan", "channel", sockets: true, cells: %{"rooms" => @log}}], node_opts)

    capture([[:atanor, :call], [:atanor, :channel, :publish], [:atanor, :channel, :rejected]])
    node
  end

  defp capture(events), do: WasmCase.capture(events)

  defp connect(node, path) do
    assert {:ok, client} = WSClient.connect(node.port, path)
    on_exit(fn -> WSClient.close(client) end)
    client
  end

  defp call(client, text) do
    client = WSClient.send_frame(client, {:text, text})
    {{:text, reply}, client} = WSClient.recv(client, 5_000)
    {reply, client}
  end

  # The callbacks of `kind` that ran on the node so far. Other tests' nodes emit the same events.
  defp calls(node, kind) do
    receive do
      {:telemetry, [:atanor, :call], _, %{kind: ^kind, instance: instance} = meta} when instance == node.name ->
        [meta | calls(node, kind)]

      {:telemetry, [:atanor, :call], _, _} ->
        calls(node, kind)
    after
      0 -> []
    end
  end

  defp flush_calls do
    receive do
      {:telemetry, [:atanor, :call], _, _} -> flush_calls()
    after
      0 -> :ok
    end
  end

  defp env(node, worker) do
    {:ok, deployment} = Registry.deployment(node.name, worker)
    Env.new(node.name, deployment)
  end

  describe "native workers" do
    test "a client frame is shaped by the local callback and reaches the channel without an owner callback" do
      node = start_native()
      [a, b, c] = for room <- ~w(r1 r1 r1), do: connect(node, "/room/#{room}")
      assert {":ok", a} = call(a, "join r1 alice")
      assert {":ok", b} = call(b, "join r1 bob")
      assert {":ok", c} = call(c, "join r2")

      {:ok, before} = Cell.position(node.name, {"rooms", "r1"})
      flush_calls()

      a = WSClient.send_frame(a, {:text, "cur r1 hello"})
      stamp = "#{node()}|hello"
      assert {{:text, ^stamp}, a} = WSClient.recv(a, 5_000)
      assert {{:text, ^stamp}, b} = WSClient.recv(b, 5_000)
      assert {:timeout, c} = WSClient.recv(c, 100)

      # The local callback ran once; no callback reached the owner and the cell did not change.
      assert length(calls(node, :ws_local)) == 1
      assert calls(node, :ws_in) == []
      assert {:ok, ^before} = Cell.position(node.name, {"rooms", "r1"})

      # A frame the local callback passes still reaches handle_ws/3.
      assert {"hi", _} = call(a, "echo hi")
      assert [%{kind: :ws_in}] = calls(node, :ws_in)
      Enum.each([b, c], &WSClient.close/1)
    end

    test "publishing is not an owner call either from a worker process" do
      node = start_native()
      a = connect(node, "/room/r1")
      assert {":ok", a} = call(a, "join r1")
      assert :ok = Env.publish(env(node, "chan"), {"rooms", "r1"}, {:binary, <<1, 2, 3>>})
      assert {{:binary, <<1, 2, 3>>}, _} = WSClient.recv(a, 5_000)

      assert_receive {:telemetry, [:atanor, :channel, :publish], %{bytes: 3, nodes: 1, subscribers: 1},
                      %{cell: {"rooms", "r1"}}}
    end

    test "leaving, closing and joining again" do
      node = start_native()
      [a, b] = for _ <- 1..2, do: connect(node, "/room/r1")
      assert {":ok", a} = call(a, "join r1 alice")
      assert {":ok", b} = call(b, "join r1 bob")
      assert {"2:alice,bob", a} = call(a, "members r1")

      assert {":ok", b} = call(b, "leave r1")
      assert {":ok", b} = call(b, "leave r1")
      assert {"1:alice", a} = call(a, "members r1")
      assert {":ok", a} = call(a, "pub r1 x")
      assert {{:text, "x"}, a} = WSClient.recv(a, 5_000)
      assert {:timeout, b} = WSClient.recv(b, 100)

      # Joining again replaces the id.
      assert {":ok", a} = call(a, "join r1 alicia")
      assert {"1:alicia", a} = call(a, "members r1")

      WSClient.close(a)
      assert until(fn -> {:ok, %{count: 0, ids: []}} == Env.channel_members(env(node, "chan"), {"rooms", "r1"}) end)
      assert {:timeout, _} = WSClient.recv(b, 100)
    end

    test "the local callback cannot reach cells" do
      node = start_native()
      a = connect(node, "/room/r1")
      assert {":ok", a} = call(a, "join probe")
      a = WSClient.send_frame(a, {:text, "probe"})
      assert {{:text, reply}, _} = WSClient.recv(a, 5_000)
      assert reply == inspect({:error, {:not_granted, {:cell, "rooms"}}})
    end

    test "the channel needs sockets: true and a granted namespace" do
      node = start_native(sockets: false)
      env = env(node, "chan")
      assert {:error, {:not_granted, :sockets}} = Env.publish(env, {"rooms", "r1"}, {:text, "x"})
      assert {:error, {:not_granted, :sockets}} = Env.channel_members(env, {"rooms", "r1"})
      assert {:error, {:not_granted, :sockets}} = Env.join_channel(env, {"rooms", "r1"})

      node = start_native()
      env = env(node, "chan")
      assert {:error, {:not_granted, {:cell, "other"}}} = Env.publish(env, {"other", "r1"}, {:text, "x"})
      assert {:error, :not_a_socket} = Env.join_channel(env, {"rooms", "r1"})
      assert {:error, :not_a_socket} = Env.leave_channel(env, {"rooms", "r1"})
      assert {:error, {:invalid_option, :id}} = Env.join_channel(%{env | socket: self()}, {"rooms", "r1"}, id: 1)
      assert {:error, :invalid_key} = Env.publish(env, {"rooms", ""}, {:text, "x"})
    end

    test "limits: message size, channels per socket and channels per node" do
      node = start_native([], channels: [max_message_bytes: 10, max_subscriptions: 2, max_channels: 3])
      env = env(node, "chan")
      [a, b] = for _ <- 1..2, do: connect(node, "/room/r1")

      assert {":ok", a} = call(a, "big r1 10")
      assert {"{:error, :too_large}", a} = call(a, "big r1 11")
      assert_receive {:telemetry, [:atanor, :channel, :rejected], _, %{reason: :too_large, cell: {"rooms", "r1"}}}
      assert {:error, :too_large} = Env.publish(env, {"rooms", "r1"}, {:text, "01234567890"})

      assert {":ok", a} = call(a, "join c1")
      assert {":ok", a} = call(a, "join c2")
      # Joining a channel again is not a new subscription.
      assert {":ok", a} = call(a, "join c2")
      assert {"{:error, :too_many_subscriptions}", a} = call(a, "join c3")
      assert_receive {:telemetry, [:atanor, :channel, :rejected], _, %{reason: :too_many_subscriptions}}

      # c1 and c2 hold two of the node's three channels; b opens the third; a new one is refused.
      assert {":ok", b} = call(b, "join c3")
      assert {"{:error, :too_many_channels}", b} = call(b, "join c4")
      assert {":ok", b} = call(b, "join c1")
      assert_receive {:telemetry, [:atanor, :channel, :rejected], _, %{reason: :too_many_channels}}

      # A socket that ends frees its channels.
      WSClient.close(a)
      assert until(fn -> Env.channel_members(env, {"rooms", "c2"}) == {:ok, %{count: 0, ids: []}} end)
      assert {":ok", _} = call(b, "leave c3")
      assert {":ok", _} = call(connect(node, "/room/r1"), "join c5")
    end
  end

  describe "per namespace limit" do
    test "one namespace cannot use up the channels of the node" do
      node = start_native([], channels: [max_channels: 10, max_channels_per_namespace: 3])
      pids = for _ <- 1..4, do: spawn_link(fn -> Process.sleep(:infinity) end)
      [a, b | _] = pids

      for i <- 1..3, do: assert(:ok = Channels.join(node.name, a, {"busy", "r#{i}"}, nil))
      assert {:error, :too_many_channels} = Channels.join(node.name, b, {"busy", "r4"}, nil)
      # Another subscriber to a channel that exists is not a new channel.
      assert :ok = Channels.join(node.name, b, {"busy", "r1"}, nil)
      assert :ok = Channels.join(node.name, b, {"rooms", "r4"}, nil)

      # A namespace's channels free up when their members leave.
      assert :ok = Channels.leave(node.name, a, {"busy", "r2"})
      assert :ok = Channels.join(node.name, b, {"busy", "r5"}, nil)
    end
  end

  describe "WASM workers" do
    test "a guest joins, receives, publishes from on-frame and sees who is in" do
      node = start_wasm()
      [a, b] = for _ <- 1..2, do: connect(node, "/wchan")
      assert {"ok", a} = call(a, "join r1 alice")
      assert {"ok", b} = call(b, "join r1")
      assert {"2:alice", a} = call(a, "members r1")

      before = elem(Cell.position(node.name, {"rooms", "r1"}), 1)
      flush_calls()

      a = WSClient.send_frame(a, {:text, "cur r1 hello"})
      assert {{:text, <<_::binary>> = stamped}, a} = WSClient.recv(a, 5_000)
      assert String.ends_with?(stamped, ":hello")
      assert {{:text, ^stamped}, b} = WSClient.recv(b, 5_000)
      assert {:ok, ^before} = Cell.position(node.name, {"rooms", "r1"})
      assert calls(node, :ws_in) == []

      # Other frames pass to on-message on the owner.
      assert {"hi", a} = call(a, "echo hi")

      assert {"ok", a} = call(a, "pub r1 from-owner")
      assert {{:text, "from-owner"}, a} = WSClient.recv(a, 5_000)
      assert {{:text, "from-owner"}, b} = WSClient.recv(b, 5_000)

      assert {"ok", b} = call(b, "leave r1")
      assert {"1:alice", a} = call(a, "members r1")
      assert {"failed: :too_large", a} = call(a, "big r1 20000")
      assert {"ok", a} = call(a, "big r1 16384")
      assert {{:binary, data}, _} = WSClient.recv(a, 5_000)
      assert byte_size(data) == 16_384
      assert {:timeout, _} = WSClient.recv(b, 100)
    end

    test "on-frame has no access to cells" do
      node = start_wasm()
      a = connect(node, "/wchan")
      assert {"ok", a} = call(a, "join probe")
      a = WSClient.send_frame(a, {:text, "probe"})
      assert {{:text, "not granted: rooms"}, _} = WSClient.recv(a, 5_000)
    end

    test "a guest without the local export has every frame handled on the owner" do
      node = WasmCase.start([{"wsock", "socket", sockets: true, cells: %{"rooms" => @log}}])
      a = connect(node, "/wsock")
      assert {"ok", a} = call(a, "join r1")
      assert {"cur r1 x", _} = call(a, "echo cur r1 x")
    end
  end

  describe "a subscriber that cannot keep up" do
    # A process that joins and never reads, so its mailbox only grows; and one that reads.
    defp subscriber(join) do
      test = self()

      pid =
        spawn_link(fn ->
          join.(self())
          send(test, {:joined, self()})

          loop = fn loop, n ->
            receive do
              :stop ->
                :ok

              _ ->
                send(test, {:got, self(), n + 1})
                loop.(loop, n + 1)
            end
          end

          receive do
            :read -> loop.(loop, 0)
          end
        end)

      assert_receive {:joined, ^pid}
      pid
    end

    test "is skipped past max_queue, for channel and cell messages, and the drops are counted" do
      node = start_native([], channels: [max_queue: 3])
      capture([[:atanor, :channel, :dropped]])
      cell = {"rooms", "slow"}

      for {name, join, send_fun} <- [
            {:channel, &Channels.join(node.name, &1, cell, nil),
             fn n -> for i <- 1..n, do: Channels.publish(node.name, cell, {:text, "m#{i}"}) end},
            {:cell, &Atanor.Sockets.attach(node.name, &1, cell),
             fn n -> for i <- 1..n, do: Atanor.Sockets.send_to(node.name, cell, "m#{i}") end}
          ] do
        slow = subscriber(join)
        send_fun.(10)

        # Four messages fit (the queue is checked before each send); six were skipped.
        assert {:message_queue_len, 4} = Process.info(slow, :message_queue_len), "#{name}"
        assert_receive {:telemetry, [:atanor, :channel, :dropped], %{count: 1}, %{cell: ^cell}}
        assert for(_ <- 1..5, do: receive(do: ({:telemetry, _, %{count: c}, _} -> c))) |> Enum.sum() == 5

        # Once it reads, it gets new messages again.
        send(slow, :read)
        assert_receive {:got, ^slow, 3}
        send_fun.(1)
        assert_receive {:got, ^slow, 5}
        send(slow, :stop)
        assert until(fn -> not Process.alive?(slow) end)
      end
    end
  end

  test "a node that does not answer is reported as unreachable, not as an owner" do
    node = start_native()
    assert {:error, :node_unreachable} = Channels.remote(node.name, :"nobody@127.0.0.1", Kernel, :node, [])
  end

  test "Channels.broadcast reaches the members of any group" do
    node = start_native()
    group = {:test, "x", "rooms", "any"}
    :ok = :pg.join(Atanor.PG, group, self())
    assert {1, 1} = Channels.broadcast(node.name, group, :hello)
    assert_receive :hello
    assert {0, 0} = Channels.broadcast(node.name, {:test, "x", "rooms", "nobody"}, :nobody)
  end
end
