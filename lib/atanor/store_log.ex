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
    Logger.warning("atanor: #{breaker(meta)} open for #{cooldown} ms (#{inspect(meta.reason)}): #{meta.location}")
  end

  def handle([:alambique, :store, :breaker, :close], _, meta, _),
    do: Logger.info("atanor: #{breaker(meta)} closed: #{meta.location}")

  def handle([:alambique, :store, :failure], _, %{operation: operation, reason: reason, counted: counted} = meta, _) do
    Logger.warning(
      "atanor: store failure: #{inspect(operation)} on #{meta.location}: reason=#{inspect(reason, limit: 8)}" <>
        crash(meta) <> " counted=#{counted}" <> if(meta[:class] == :feed, do: " breaker=feed", else: "")
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

  # `kind` and `detail` are nil unless the store crashed.
  # Each location has two breakers: `:feed` for the feed objects and `:default` for the rest.
  defp breaker(%{class: :feed}), do: "store feed breaker"
  defp breaker(_meta), do: "store breaker"

  defp crash(%{kind: kind, detail: detail}) when kind != nil, do: " kind=#{inspect(kind)} detail=#{detail_text(detail)}"
  defp crash(_meta), do: ""

  defp detail_text(detail) when is_binary(detail), do: detail
  defp detail_text(detail), do: inspect(detail)

  # The operation (a GET with `list-type` is a LIST) and where it went: the first folders of the path and, for a
  # LIST, of its prefix (`LIST store:8333/atanor/?prefix=atanor/alarms/`, `GET store:8333/atanor/atanor/cells/`).
  # Never an object name nor the rest of the query, so no cell id or signature reaches the log.
  defp target(request) do
    params = URI.decode_query(request.query || "")
    {operation, prefix} = if params["list-type"], do: {"LIST", params["prefix"]}, else: {request.method, nil}
    list = if prefix, do: "?prefix=" <> head(folder(prefix), 2), else: ""
    "#{operation} #{request.host}:#{request.port}#{head(folder(request.path || "/"), 4)}#{list}"
  end

  # A path or key without its last segment: "a/b/c" is "a/b/", "a/b/" stays.
  defp folder(path), do: String.replace(path, ~r{[^/]*$}, "")

  # The first `n` segments of a folder, ending in "/".
  defp head(folder, n),
    do: folder |> String.split("/") |> Enum.take(n) |> Enum.join("/") |> String.trim_trailing("/") |> Kernel.<>("/")

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error, limit: 8)

  defp store_error(what, reason) do
    if Alambique.Store.Breaker.classify(reason) != :store_unavailable do
      Logger.warning("atanor: store error: #{what}: #{inspect(reason, limit: 8, printable_limit: 200)}")
    end
  end
end
