defmodule Atanor.StoreLog do
  @moduledoc false
  # Logs what Alambique's and Finch's telemetry say about the store, so an open breaker leaves its cause in the node log:
  # the breaker opening and closing, the store errors of the requests that reached it (a request refused by an open
  # breaker is `:store_unavailable` and is not logged again), each store failure with its reason and whether the breaker
  # counted it, the HTTP requests that failed (the transport error the
  # breaker counts) and those that took over `@slow_ms`.

  require Logger

  @id "atanor-store-log"
  @slow_ms 1_000
  @events [
    [:alambique, :store, :breaker, :open],
    [:alambique, :store, :breaker, :close],
    [:alambique, :store, :failure],
    [:alambique, :cell, :upload_retry],
    [:alambique, :lease, :renew],
    [:alambique, :lease, :acquire],
    [:alambique, :replication, :sync],
    [:finch, :request, :stop],
    [:finch, :request, :exception],
    [:finch, :queue, :exception]
  ]

  @doc "Attaches the handler once per VM."
  @spec attach() :: :ok
  def attach do
    _ = :telemetry.attach_many(@id, @events, &__MODULE__.handle/4, nil)
    :ok
  end

  @doc "Removes the handler."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@id)
    :ok
  end

  @doc false
  def handle([:alambique, :store, :breaker, :open], %{cooldown_ms: cooldown}, meta, _) do
    Logger.warning("atanor: store breaker open for #{cooldown} ms (#{inspect(meta.reason)}): #{meta.location}")
  end

  def handle([:alambique, :store, :breaker, :close], _, meta, _),
    do: Logger.info("atanor: store breaker closed: #{meta.location}")

  def handle([:alambique, :store, :failure], _, %{operation: operation, reason: reason, counted: counted} = meta, _) do
    Logger.warning(
      "atanor: store failure: #{inspect(operation)} on #{meta.location}: reason=#{inspect(reason, limit: 8)} counted=#{counted}"
    )
  end

  def handle([:alambique, :cell, :upload_retry], %{delay_ms: delay}, %{reason: reason} = meta, _) do
    store_error("upload of #{meta.cell} failed (retry in #{delay} ms)", reason)
  end

  def handle([:alambique, :lease, op], _, %{result: :error, reason: reason} = meta, _) do
    store_error("lease #{op} of #{meta.cell} failed", reason)
  end

  def handle([:alambique, :replication, :sync], _, %{result: :error, reason: reason} = meta, _) do
    store_error("sync of #{meta.cell} failed", reason)
  end

  def handle([:finch, :request, :stop], %{duration: duration}, %{request: request, result: result}, _) do
    ms = System.convert_time_unit(duration, :native, :millisecond)

    case result do
      {:error, error} ->
        Logger.warning("atanor: HTTP request #{target(request)} failed after #{ms} ms: #{message(error)}")

      _ when ms >= @slow_ms ->
        Logger.warning("atanor: HTTP request #{target(request)} took #{ms} ms")

      _ ->
        :ok
    end
  end

  def handle([:finch, phase, :exception], %{duration: duration}, %{request: request, kind: kind, reason: reason}, _) do
    ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.warning(
      "atanor: HTTP #{phase} of #{target(request)} raised after #{ms} ms: #{inspect({kind, reason}, limit: 8)}"
    )
  end

  def handle(_event, _measurements, _meta, _config), do: :ok

  defp target(request), do: "#{request.method} #{request.host}:#{request.port}"

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error, limit: 8)

  defp store_error(what, reason) do
    if Alambique.Store.Breaker.classify(reason) != :store_unavailable do
      Logger.warning("atanor: store error: #{what}: #{inspect(reason, limit: 8, printable_limit: 200)}")
    end
  end
end
