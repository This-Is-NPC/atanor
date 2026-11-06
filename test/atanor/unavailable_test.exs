defmodule Atanor.UnavailableTest do
  use ExUnit.Case, async: true

  alias Atanor.Unavailable

  test "names the availability reasons of cell and routing errors" do
    for {error, reason} <- [
          {:no_quorum, :no_quorum},
          {:owner_down, :owner_down},
          {:owner_unreachable, :owner_unreachable},
          {:fenced, :fenced},
          {:lease_lost, :fenced},
          {:lease_expired, :fenced},
          {:overloaded, :overloaded},
          {:busy, :overloaded},
          {:draining, :owner_down},
          {:taken_elsewhere, :owner_unreachable},
          {:epoch_changed, :owner_unreachable},
          {{:epoch_changed, 7}, :owner_unreachable},
          {{:contended, "n@h", 7}, :owner_unreachable},
          {{:deployment_unavailable, :x}, :deployment_unavailable},
          {{:store, :econnrefused}, :store_unavailable},
          {{:unavailable, :no_quorum}, :no_quorum},
          {{:unavailable, "n@h", 1}, :owner_unreachable},
          {{:lost, :n2, :timeout}, :owner_unreachable},
          {{:cell_down, :fenced}, :fenced},
          {{:wake_failed, :boom}, :owner_unreachable}
        ] do
      assert Unavailable.reason(error) == reason
      assert Unavailable.from_error({:error, error}) == reason
    end

    assert Unavailable.reason(:unknown_namespace) == nil
    assert Unavailable.reason(:timeout) == nil
    assert Unavailable.from_error({:ok, :x}) == nil
  end

  def relay(_event, measurements, meta, parent), do: send(parent, {:foreign_store, measurements, meta})

  test "a foreign store is a configuration error, not unavailability" do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler,
      [:atanor, :foreign_store],
      &__MODULE__.relay/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Unavailable.error(:inst, {:foreign_store, :x@h}) == {:error, {:foreign_store, :x@h}}
      end)

    assert log =~ "foreign_store"
    assert_receive {:foreign_store, %{count: 1}, %{instance: :inst, node: :x@h}}
    assert Unavailable.reason({:foreign_store, :x@h}) == nil
    refute :foreign_store in Unavailable.reasons()
    assert Unavailable.error(:inst, :stale) == {:error, {:unavailable, :owner_unreachable}}
    assert Unavailable.error(:inst, :no_quorum) == {:error, {:unavailable, :no_quorum}}
  end

  test "a failed upload is an unknown outcome, a store that did not answer a refusal" do
    # The cell stopped on an upload that may have reached the store; the transaction of a job was rolled back.
    assert Unavailable.reason({:sync_failed, :econnrefused}) == nil
    assert :store_unavailable in Unavailable.reasons()

    assert Atanor.Wasm.Host.error({:error, {:store, :econnrefused}}) ==
             {:error, :failed, "store_unavailable: the store did not answer; nothing was applied, retry later"}

    assert {:error, :failed, "sync_failed: " <> _} = Atanor.Wasm.Host.error({:error, {:sync_failed, :econnrefused}})
    assert {:error, :failed, "{:other, 1}"} = Atanor.Wasm.Host.error({:error, {:other, 1}})
  end

  test "a lease that could not be read ran nothing: a refusal, not a 500" do
    assert Unavailable.reason({:lease_unreadable, :econnrefused}) == :store_unavailable

    assert {:error, :failed, "store_unavailable: " <> _} =
             Atanor.Wasm.Host.error({:error, {:lease_unreadable, :econnrefused}})
  end
end
