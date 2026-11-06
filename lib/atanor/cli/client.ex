defmodule Atanor.CLI.Client do
  @moduledoc """
  The HTTP client of the `atanor` command for the admin API. A connection is
  `%{url:, token:, timeout_ms:, connect_timeout_ms:}`. Every failure comes
  back as a message for the person at the terminal, built from the status and
  the JSON error body (design §10.2.1).
  """

  @type conn :: %{
          url: String.t(),
          token: String.t(),
          timeout_ms: pos_integer,
          connect_timeout_ms: pos_integer
        }

  @doc """
  Sends a request. Options: `:json` (a body, encoded), `:body` (raw bytes),
  `:headers` and `:query`. Returns the decoded JSON body of a 2xx answer.
  """
  @spec request(conn, :get | :post, String.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def request(conn, method, path, opts \\ []) do
    {body, headers} =
      case opts[:json] do
        nil -> {opts[:body], []}
        json -> {Jason.encode!(json), [{"content-type", "application/json"}]}
      end

    result =
      Req.request(
        method: method,
        url: conn.url <> path,
        params: opts[:query] || [],
        headers: [{"authorization", "Bearer " <> conn.token}] ++ headers ++ Keyword.get(opts, :headers, []),
        body: body,
        retry: false,
        decode_body: false,
        redirect: false,
        receive_timeout: conn.timeout_ms,
        connect_options: [timeout: conn.connect_timeout_ms]
      )

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 -> decode(body)
      {:ok, %{status: status, body: body}} -> {:error, failure(status, decode_error(body))}
      {:error, exception} -> {:error, transport(conn, exception)}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "the server answered something that is not a JSON object; is the URL the admin API?"}
    end
  end

  defp decode_error(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp transport(conn, %{reason: :timeout}),
    do: "no answer from #{conn.url} in time; raise it with --timeout or ATANOR_TIMEOUT (seconds)"

  defp transport(conn, %{reason: reason}) when is_atom(reason),
    do: "cannot reach #{conn.url}: #{reason}"

  defp transport(conn, exception), do: "cannot reach #{conn.url}: #{Exception.message(exception)}"

  @doc false
  def failure(401, _), do: "the server did not accept the token (it is wrong, expired or revoked); run `atanor login`"
  def failure(403, %{"required" => scope}), do: "forbidden: this token needs the scope #{scope}"
  def failure(403, _), do: "forbidden: this token may not do that"

  def failure(413, %{"max_bytes" => max}),
    do: "the package is larger than the server accepts (#{max} bytes, the admin max_package_bytes)"

  def failure(422, %{"error" => "hash_mismatch"}),
    do: "the server received other bytes than the ones hashed (hash_mismatch); run the command again"

  def failure(422, %{"error" => "invalid_package"} = body), do: "the server refused the package: #{body["reason"]}"

  def failure(422, %{"error" => "package_of_other_worker", "package_worker" => other}),
    do: "the package is for the worker #{other}, not the one named"

  def failure(409, %{"error" => "no_previous"}), do: "the worker has no previous package to return to"

  def failure(409, %{"error" => "conflict"}),
    do: "other changes moved the head at the same time; run the command again"

  def failure(409, %{"error" => "partitions_changed"} = body) do
    "the namespace #{body["namespace"]} is recorded with #{body["recorded"] || "no"} partitions and the package declares " <>
      "#{body["declared"] || "none"}; the number of partitions is fixed for the life of the data"
  end

  def failure(409, %{"error" => "namespace_has_data", "namespace" => ns}),
    do: "the namespace #{ns} already has cells and cannot become partitioned; use a new namespace"

  def failure(404, %{"error" => "package_not_found"}), do: "the package is not stored; deploy it first"
  def failure(404, %{"error" => "not_found"}), do: "not found"

  def failure(503, %{"error" => error} = body),
    do: "the server cannot do that now (#{error}#{reason(body)}); try again shortly"

  def failure(status, %{"error" => error} = body), do: "the server answered #{status} #{error}#{reason(body)}"
  def failure(status, _), do: "the server answered #{status}"

  defp reason(%{"reason" => reason}), do: ": " <> to_string(reason)
  defp reason(_), do: ""
end
