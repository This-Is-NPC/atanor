defmodule Atanor.StoreLogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defp emit(event, measurements, meta) do
    capture_log(fn -> :telemetry.execute([:alambique | event], measurements, meta) end)
  end

  defp finch(event, duration_ms, meta) do
    measurements = %{duration: System.convert_time_unit(duration_ms, :millisecond, :native)}
    meta = Map.put(meta, :request, Finch.build(:get, "http://store:8333/bucket/key"))
    capture_log(fn -> :telemetry.execute([:finch | event], measurements, meta) end)
  end

  test "an open breaker is logged with its location and reason, and its closing too" do
    meta = %{instance: :x, location: "s3://bucket", reason: :failures}
    log = emit([:store, :breaker, :open], %{cooldown_ms: 5_000}, meta)
    assert log =~ "store breaker open for 5000 ms (:failures): s3://bucket"

    log = emit([:store, :breaker, :close], %{}, Map.delete(meta, :reason))
    assert log =~ "store breaker closed: s3://bucket"
  end

  test "a store failure is logged with its operation, reason and whether the breaker counted it" do
    meta = %{instance: :x, location: "s3://bucket", operation: :head, reason: {:http, 503}, counted: true}
    log = emit([:store, :failure], %{}, meta)
    assert log =~ "store failure: :head on s3://bucket: reason={:http, 503} counted=true"

    log = emit([:store, :failure], %{}, %{meta | operation: :put, reason: :local, counted: false})
    assert log =~ "store failure: :put on s3://bucket: reason=:local counted=false"
  end

  test "a crashed store failure is logged with its kind and detail" do
    meta = %{instance: :x, location: "s3://bucket", operation: :list, reason: :crashed, counted: true}

    log = emit([:store, :failure], %{}, Map.merge(meta, %{kind: :exit, detail: :pool_checkout_timeout}))
    assert log =~ "reason=:crashed kind=:exit detail=:pool_checkout_timeout counted=true"

    log = emit([:store, :failure], %{}, Map.merge(meta, %{kind: :error, detail: "%RuntimeError{message: \"boom\"}"}))
    assert log =~ "kind=:error detail=%RuntimeError{message: \"boom\"} counted=true"

    log = emit([:store, :failure], %{}, Map.merge(meta, %{kind: nil, detail: nil, reason: :transport}))
    assert log =~ "reason=:transport counted=true"
    refute log =~ "kind="
  end

  test "a store error of a request that reached the store is logged with its reason" do
    reason = {:request_crashed, :exit, :timeout}

    log = emit([:cell, :upload_retry], %{delay_ms: 100}, %{cell: "a.1", reason: reason})
    assert log =~ "store error: upload of a.1 failed (retry in 100 ms): {:request_crashed, :exit, :timeout}"

    assert emit([:lease, :renew], %{}, %{cell: "a.1", result: :error, reason: {:http, 500, ""}}) =~
             "store error: lease renew of a.1 failed: {:http, 500, \"\"}"

    assert emit([:replication, :sync], %{}, %{cell: "a.1", result: :error, reason: :timeout}) =~
             "store error: sync of a.1 failed: :timeout"
  end

  test "an HTTP request that failed, raised or was slow is logged with its target and time" do
    error = %Mint.TransportError{reason: :closed}

    assert finch([:request, :stop], 12, %{result: {:error, error}}) =~
             "HTTP request GET store:8333 failed after 12 ms: socket closed"

    assert finch([:request, :exception], 30, %{kind: :exit, reason: :timeout}) =~
             "HTTP request of GET store:8333 raised after 30 ms: {:exit, :timeout}"

    assert finch([:queue, :exception], 5000, %{kind: :exit, reason: :timeout}) =~
             "HTTP queue of GET store:8333 raised after 5000 ms"

    assert finch([:request, :stop], 1500, %{result: {:ok, %{status: 200}}}) =~
             "HTTP request GET store:8333 took 1500 ms"

    assert finch([:request, :stop], 20, %{result: {:ok, %{status: 200}}}) == ""
  end

  test "a request refused by an open breaker, and a success, are not logged" do
    assert emit([:cell, :upload_retry], %{delay_ms: 1}, %{cell: "a.1", reason: :store_unavailable}) == ""
    assert emit([:lease, :renew], %{}, %{cell: "a.1", result: :ok, epoch: 1}) == ""
    assert emit([:replication, :sync], %{}, %{cell: "a.1", result: :ok}) == ""
  end

  test "the handler is attached when the application starts and can be detached" do
    assert Enum.any?(:telemetry.list_handlers([:alambique, :store, :breaker, :open]), &(&1.id == "atanor-store-log"))
    :ok = Atanor.StoreLog.detach()
    refute Enum.any?(:telemetry.list_handlers([:alambique, :store, :breaker, :open]), &(&1.id == "atanor-store-log"))
    :ok = Atanor.StoreLog.attach()
  end
end
