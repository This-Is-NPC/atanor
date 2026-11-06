defmodule Atanor.DetectorTest do
  @moduledoc "State transitions of the failure detector (design §8.8) with peers that are only heartbeats."
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias Atanor.Detector

  @peer :"peer@127.0.0.1"

  setup do
    name = Module.concat(__MODULE__, "D#{System.unique_integer([:positive])}")

    config =
      Atanor.Config.build(
        name: name,
        data_dir: "/tmp/unused",
        store: {Unused, nil},
        takeover: [settle_ms: 300],
        detector: [
          interval_ms: 20,
          min_std_ms: 5,
          acceptable_pause_ms: 40,
          phi_threshold: 6,
          indirect: [timeout_ms: 100]
        ]
      )

    start_supervised!(Detector.tasks_spec(name))
    start_supervised!(Detector.child_spec(config))
    me = self()
    handler = {__MODULE__, name}

    :telemetry.attach_many(
      handler,
      for(e <- [:suspect, :down, :link_broken, :alive], do: [:atanor, :node, e]),
      &__MODULE__.relay/4,
      {me, name}
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{name: name, server: Module.concat(name, :Detector)}
  end

  def relay(event, _measurements, meta, {pid, name}),
    do: if(meta.instance == name, do: send(pid, {:event, List.last(event), meta}))

  defp beat(server, node \\ @peer, count \\ 15) do
    for _ <- 1..count do
      send(server, {:heartbeat, node})
      Process.sleep(20)
    end
  end

  defp state(name), do: for(%{node: @peer, state: state} <- Detector.peers(name), do: state)

  test "a peer heard that is not connected is reconnected from the detector's own tasks", %{server: server} do
    ref = Process.monitor(server)
    send(server, {:heartbeat, @peer})

    # The reconnect task runs in the detector's own supervisor: the instance's `Atanor.Tasks` is not started here.
    until(fn -> is_pid(:sys.get_state(server).peers[@peer][:reconnect]) end)
    refute_received {:DOWN, ^ref, _, _, _}
  end

  test "the options are validated" do
    build = &Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, detector: &1)

    assert %{interval_ms: 500, indirect_k: 0, phi_threshold: 5.0} =
             build.(interval_ms: 500, phi_threshold: 5, indirect: [k: 0]).detector

    for bad <- [
          [interval_ms: 0],
          [phi_threshold: -1],
          [window: 1.5],
          [reprobe_ms: 0],
          [seed_spread: 1],
          [unknown: 1],
          [indirect: [x: 1]],
          :nope
        ] do
      assert_raise ArgumentError, fn -> build.(bad) end
    end
  end

  test "the takeover, routing and stop options are validated" do
    build = &Atanor.Config.build([data_dir: "/tmp/x", store: {Mod, nil}] ++ &1)
    config = build.([])
    assert %{enabled: true, quorum: true, settle_ms: 2_000, attempts: 3, timeout_ms: nil} = config.takeover

    assert %{attempts: 3, retry_ms: 50, remote_timeout_ms: 60_000, owner_check: true, owner_check_ms: 1_000} =
             config.routing

    assert %{drain_timeout_ms: nil, drain_concurrency: nil, shutdown_ms: 75_000, connections_ms: 15_000} = config.stop

    config =
      build.(takeover: [enabled: false, timeout_ms: 5_000], stop: [drain_concurrency: 8], routing: [retry_ms: 10])

    assert %{enabled: false, timeout_ms: 5_000} = config.takeover
    assert %{drain_concurrency: 8} = config.stop
    assert %{retry_ms: 10} = config.routing

    assert %{concurrency: 8, page_size: 100, timeout_ms: nil} = config.migrate
    assert %{page_size: 5} = build.(migrate: [page_size: 5]).migrate

    for bad <- [
          [migrate: [concurrency: 0]],
          [takeover: [enabled: 1]],
          [takeover: [quorum: nil]],
          [takeover: [attempts: 0]],
          [takeover: [unknown: 1]],
          [routing: [attempts: -1]],
          [stop: [shutdown_ms: nil]],
          [stop: :nope]
        ] do
      assert_raise ArgumentError, fn -> build.(bad) end
    end
  end

  test "a peer that keeps sending heartbeats stays alive", %{name: name, server: server} do
    beat(server, @peer, 25)
    assert state(name) == [:alive]
    refute_received {:event, _, _}
    refute Detector.blocked?(name, @peer)
  end

  test "silence makes a peer suspect, then down when nobody reaches it; heartbeats bring it back",
       %{name: name, server: server} do
    beat(server)
    assert_receive {:event, :suspect, %{node: @peer, reason: {:phi, phi}}}
    assert phi >= 6
    assert_receive {:event, :down, %{node: @peer}}
    assert state(name) == [:down]
    assert Detector.blocked?(name, @peer)
    # This node alone, with its only peer lost, is not a majority.
    refute Detector.quorum?(name)

    send(server, {:heartbeat, @peer})
    assert_receive {:event, :alive, %{node: @peer, from: :down}}
    assert state(name) == [:alive]
    refute Detector.blocked?(name, @peer)
    # A majority again, but a rejoining node waits for it to settle before it acts.
    refute Detector.quorum?(name)
    beat(server, @peer, 20)
    assert Detector.quorum?(name)
  end

  test "a peer that announces it leaves is down at once and is not disconnected", %{name: name, server: server} do
    beat(server, @peer, 3)
    send(server, {:leaving, @peer})
    assert_receive {:event, :down, %{node: @peer, reason: :left}}
    assert Detector.blocked?(name, @peer)
  end

  test "the platform hint and confirmed_down act without phi", %{name: name, server: server} do
    beat(server, @peer, 3)
    assert Detector.quorum?(name)
    assert {:error, :unknown_node} = Detector.gone(name, :"other@127.0.0.1")
    assert :ok = Detector.gone(name, @peer)
    assert_receive {:event, :down, %{reason: :platform_hint}}
    assert state(name) == [:down]
    assert {:ok, @peer, :platform_hint} = Detector.down_owner(name, Atom.to_string(@peer))
    # A peer the platform says is gone does not count against the majority.
    assert Detector.quorum?(name)
    assert :error = Detector.down_owner(name, "other@127.0.0.1")
    refute_received {:event, :suspect, _}

    beat(server, @peer, 2)
    assert_receive {:event, :alive, _}
    assert :error = Detector.down_owner(name, Atom.to_string(@peer))
    assert :ok = Detector.confirmed_down(name, @peer, :test)
    assert_receive {:event, :down, %{reason: :test}}
  end

  test "a stall of this node is not held against its peers", %{name: name, server: server} do
    beat(server)
    :sys.suspend(server)
    # A loaded machine can delay the beats above and suspect the peer before the
    # stall. Events are emitted by the detector, so once it is suspended all of
    # them are in the mailbox: drop them so the refute below covers the stall only.
    flush_events()
    Process.sleep(300)
    send(server, {:heartbeat, @peer})
    :sys.resume(server)
    await_state(name, :alive)
    refute_received {:event, :suspect, _}
  end

  test "a peer suspected before a stall is alive again when its heartbeat comes after it", %{name: name, server: server} do
    beat(server)
    # No more beats: the peer turns suspect (and then down, as nobody can vouch for it).
    until(fn -> state(name) != [:alive] end)
    :sys.suspend(server)
    Process.sleep(300)
    send(server, {:heartbeat, @peer})
    :sys.resume(server)
    await_state(name, :alive)
  end

  defp flush_events do
    receive do
      {:event, _, _} -> flush_events()
    after
      0 -> :ok
    end
  end

  defp await_state(name, expected), do: until(fn -> state(name) == [expected] end)
end
