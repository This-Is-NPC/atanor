defmodule Atanor.SignalTest do
  @moduledoc "SIGTERM runs the drain while the listeners serve, then stops the VM (design §8.11)."
  # The handler is one per VM and drains every running instance.
  use ExUnit.Case, async: false

  alias AlambiqueTestkit.{GatedStore, MemoryStore}
  alias Atanor.{Config, Signal}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @moduletag capture_log: true
  @operator "operator-secret"

  setup do
    parent = self()
    Application.put_env(:atanor, :vm_stop, &send(parent, {:vm_stop, &1}))
    on_exit(fn -> Application.delete_env(:atanor, :vm_stop) end)
  end

  defp start(opts) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, _} = start_supervised({MemoryStore, name: name})
    gate = start_supervised!(GatedStore)

    node =
      Node.start(
        [
          store: GatedStore.wrap(gate, {MemoryStore, MemoryStore.config(name)}),
          workers: [Manifests.counter("counter")],
          admin: [token: @operator, port: 0]
        ] ++ opts
      )

    on_exit(fn -> Node.stop(node) end)
    {node, gate}
  end

  defp sigterm, do: :gen_event.notify(:erl_signal_server, :sigterm)

  test "the application installs the handler, and uninstalling puts OTP's back" do
    assert Signal in :gen_event.which_handlers(:erl_signal_server)
    assert :ok = Signal.uninstall()
    assert :erl_signal_handler in :gen_event.which_handlers(:erl_signal_server)
    assert :ok = Signal.install()
    assert Signal in :gen_event.which_handlers(:erl_signal_server)
  end

  test "SIGTERM drains while the listeners answer, then stops the VM with status 0" do
    {node, gate} = start([])
    assert Req.post!(node.url <> "/c/a", body: "1", retry: false).status == 200
    GatedStore.hold(gate, ~r{log\.a})

    sigterm()

    admin = "http://127.0.0.1:#{Atanor.admin_port(node.name)}"
    headers = [authorization: "Bearer " <> @operator]

    Atanor.Test.Await.until(fn ->
      match?(
        %{status: 200, body: %{"status" => "draining"}},
        Req.get!(admin <> "/health", headers: headers, retry: false)
      )
    end)

    # Hibernating the cell is stuck on the gate: the node still answers on both listeners.
    resp = Req.get!(node.url <> "/c/b", retry: false)
    assert resp.status in [200, 503]
    refute_received {:vm_stop, _}

    GatedStore.open(gate)
    assert_receive {:vm_stop, 0}, 10_000
    assert %{released: true} = elem(Alambique.lease(Atanor.Registry.config(node.name).alambique, "log.a"), 1)
  end

  test "an instance with `stop: [sigterm: :stop]` is left to the VM stop" do
    {node, _gate} = start(stop: [sigterm: :stop, exit: false])
    sigterm()
    assert_receive {:vm_stop, 0}, 10_000
    assert %{state: :idle} = Atanor.drain_status(node.name)
  end

  test "`stop.sigterm` is :drain by default and checked" do
    build = &Config.build([data_dir: "/tmp/x", store: {Mod, nil}] ++ &1)
    assert build.([]).stop.sigterm == :drain
    assert build.(stop: [sigterm: :stop]).stop.sigterm == :stop
    assert_raise ArgumentError, fn -> build.(stop: [sigterm: :kill]) end
    assert_raise ArgumentError, fn -> build.(stop: [sigterm: 1]) end
  end
end
