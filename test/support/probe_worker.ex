defmodule Atanor.Test.ProbeWorker do
  @moduledoc "Test worker: the last path segment picks what to exercise (gate, crash, cell, fetch, ...); anything else is echoed. Replies are JSON."
  @behaviour Atanor.Worker

  alias Atanor.{Env, Request, Response}

  @impl true
  def handle_request(%Request{path: path} = req, env), do: dispatch(Path.basename(path), req, env)

  defp dispatch("gate", req, env) do
    test = req |> Request.header("x-test-pid") |> Base.decode64!() |> :erlang.binary_to_term()
    send(test, {:in_handler, self()})

    receive do
      :go -> json(200, %{deployment: env.deployment.id})
    end
  end

  # Reports the deployment at the start and at the end of a request that waits
  # in between; the limit is read from the manifest, which belongs to the version.
  defp dispatch("span", req, env) do
    test = req |> Request.header("x-test-pid") |> Base.decode64!() |> :erlang.binary_to_term()
    first = env.deployment.id
    send(test, {:in_handler, self()})

    receive do
      :go ->
        json(200, %{
          start: first,
          end: env.deployment.id,
          limit: env.deployment.manifest.limits[:timeout_ms],
          node: node()
        })
    end
  end

  # As if a cell write answered `:outcome_unknown` (Atanor.Cell marks it), then answers `status`.
  defp dispatch("unknown", %Request{query: "status=" <> status}, _env) do
    Process.put({Atanor.Cell, :unknown_outcome}, true)
    json(String.to_integer(status), %{handled: true})
  end

  # As if a cell call failed for unavailability, optionally also an unknown outcome.
  defp dispatch("unavailable", %Request{query: query}, _env) do
    params = URI.decode_query(query)
    Atanor.Cell.mark_unavailable(String.to_existing_atom(params["reason"]))
    if params["unknown"] == "1", do: Process.put({Atanor.Cell, :unknown_outcome}, true)
    if params["crash"] == "1", do: raise("secret internals")
    json(String.to_integer(params["status"] || "500"), %{handled: true})
  end

  defp dispatch("headers", req, _env), do: json(200, %{headers: Map.new(req.headers)})
  defp dispatch("socket", _req, env), do: json(200, %{socket: inspect(env.socket)})
  defp dispatch("claims", req, _env), do: json(200, %{claims: Request.claims(req)})
  defp dispatch("crash", _req, _env), do: raise("secret internals")
  defp dispatch("exit", _req, _env), do: exit(:secret_reason)
  defp dispatch("bad", _req, _env), do: :not_a_response
  defp dispatch("bad-status", _req, _env), do: %Response{status: 99}

  defp dispatch("cell", req, env) do
    %{"op" => op, "ns" => ns, "key" => key, "sql" => sql} = args = Jason.decode!(req.body)
    params = args["params"] || []

    result =
      case op do
        "query" -> Env.query(env, {ns, key}, sql, params)
        "execute" -> Env.execute(env, {ns, key}, sql, params)
        "transaction" -> Env.transaction(env, {ns, key}, fn tx -> Alambique.Tx.execute(tx, sql, params) end)
      end

    json(200, render(result))
  end

  # One write or one read of a note whose failure is a 5xx, so the ingress names it (`Atanor.Cell.mark_*`).
  defp dispatch("write", %Request{query: "key=" <> key, body: body}, env) do
    case Env.execute(env, {"notes", key}, "INSERT INTO notes (body) VALUES (?)", [body]) do
      {:ok, _} -> json(200, %{written: key})
      {:error, reason} -> json(500, %{error: inspect(reason)})
    end
  end

  defp dispatch("read", %Request{query: "key=" <> key}, env) do
    case Env.query(env, {"notes", key}, "SELECT body FROM notes") do
      {:ok, %{rows: rows}} -> json(200, %{rows: rows})
      {:error, reason} -> json(500, %{error: inspect(reason)})
    end
  end

  defp dispatch("secret", %Request{query: "name=" <> name}, env),
    do: json(200, render(Env.secret(env, name)))

  defp dispatch("fetch", req, env) do
    url = URI.parse(req.query |> URI.decode_query() |> Map.fetch!("url"))

    request = %Request{
      method: "GET",
      scheme: url.scheme,
      host: url.host,
      port: url.port,
      path: url.path || "/",
      query: url.query || ""
    }

    json(200, render(Env.fetch(env, request)))
  end

  defp dispatch("call", req, env) do
    %{"worker" => worker, "path" => path} = URI.decode_query(req.query)
    json(200, render(Env.call(env, worker, %Request{path: path})))
  end

  # Calls `worker` twice, waiting for `:go` in between; returns both answers.
  defp dispatch("pair", req, env) do
    %{"worker" => worker, "path" => path} = URI.decode_query(req.query)
    test = req |> Request.header("x-test-pid") |> Base.decode64!() |> :erlang.binary_to_term()
    first = render(Env.call(env, worker, %Request{path: path}))
    send(test, {:in_handler, self()})

    receive do
      :go -> json(200, %{first: first, second: render(Env.call(env, worker, %Request{path: path}))})
    end
  end

  # Calls itself until the depth limit stops it.
  defp dispatch("recurse", req, env), do: json(200, render(Env.call(env, Env.worker(env), req)))

  # Anything else is echoed back.
  defp dispatch(_action, req, env) do
    json(200, %{
      method: req.method,
      scheme: req.scheme,
      host: req.host,
      path: req.path,
      query: req.query,
      headers: Map.new(req.headers),
      body: req.body,
      worker: Env.worker(env),
      deployment: env.deployment.id
    })
  end

  @impl true
  def route_key(%Request{path: "/keyed/" <> key}, _env), do: {:cell, "notes", key}
  def route_key(_input, _env), do: :none

  defp json(status, term),
    do: %Response{status: status, headers: [{"content-type", "application/json"}], body: Jason.encode!(term)}

  defp render({:ok, %Response{status: status, body: body}}), do: %{ok: %{status: status, body: body}}
  defp render({:ok, %{rows: rows}}), do: %{ok: %{rows: rows}}
  defp render({:ok, value}) when is_binary(value), do: %{ok: value}
  defp render({:ok, _}), do: %{ok: true}
  defp render({:error, reason}), do: %{error: inspect(reason)}
end
