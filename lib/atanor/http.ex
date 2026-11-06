defmodule Atanor.HTTP do
  @moduledoc """
  HTTP ingress (design §7.1). A request is matched to a route, its deployment
  is resolved once and carried in the env until the response is written
  (guarantee D1).

  A request that asks for a WebSocket upgrade on a route of a worker with
  `handle_ws/3` is accepted if the worker's `ws_init/2` accepts it. Plug
  workers upgrade through the Plug itself.

  Failures never leak internals: no route is a 404, an oversized body a 413,
  a worker that crashes or returns something else a 500, all with a JSON body.
  Expected unavailability is a 503 with the reason and `Retry-After`
  (`:http`'s `:retry_after_s`, or the lease's time left for `held_elsewhere`, design §8.4); a worker that mapped the error to
  5xx still gets the 503.
  """
  @behaviour Plug

  import Plug.Conn

  alias Atanor.{Auth, Dispatch, Env, Registry, Request, Response, Route, Telemetry, Unavailable, Workers}
  alias Atanor.Diagnostics.Breadcrumb
  alias Atanor.HTTP.Socket

  @rejections %{400 => "bad_request", 404 => "not_found", 413 => "payload_too_large"}

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :name)

  @impl true
  def call(conn, name) do
    config = Registry.config(name)

    case Route.canonical(conn.host, conn.request_path, config.http) do
      {:ok, host, path} ->
        conn = canonical(conn, host, path)

        case Registry.match(name, host, path) do
          {:ok, deployment, _route} -> authorize(conn, name, config, deployment)
          :error -> reject(conn, 404, :no_route)
        end

      {:error, reason} ->
        reject(conn, 400, reason)
    end
  end

  # Routing, authorization and the worker see one request: workers that decode the path (a Plug router) get
  # the canonical segments.
  defp canonical(conn, host, path) do
    %{
      conn
      | host: host,
        request_path: path,
        path_info: for(segment <- String.split(path, "/"), segment != "", do: segment)
    }
  end

  # A protected route (design §7.5) answers without calling the worker unless the token is valid. The claims
  # header is Atanor's: every copy the client sent is dropped.
  defp authorize(conn, name, config, deployment) do
    conn = %{conn | req_headers: Auth.strip_claims(conn.req_headers)}
    env = Env.new(name, deployment)

    case Auth.check(name, config, conn.host, conn.request_path, conn.req_headers) do
      :open -> dispatch(conn, env, config)
      {:ok, claims} -> dispatch(put_req_header(conn, Auth.claims_header(), Auth.encode_claims(claims)), env, config)
      {:reject, status, challenge, error, reason} -> deny(conn, env, config, status, challenge, error, reason)
    end
  end

  defp dispatch(conn, %Env{deployment: %{plug?: true}} = env, _config), do: serve_plug(conn, env)
  defp dispatch(conn, env, config), do: serve(conn, env, config)

  defp deny(conn, env, config, status, challenge, error, reason) do
    meta = %{reason: reason, status: status, host: conn.host, worker: Env.worker(env)}
    :telemetry.execute([:atanor, :auth, :reject], %{count: 1}, meta)

    conn =
      if challenge, do: put_resp_header(conn, "www-authenticate", challenge), else: conn

    conn =
      if status == 503,
        do: put_resp_header(conn, "retry-after", Integer.to_string(config.http.retry_after_s)),
        else: conn

    json(conn, status, error || "unauthorized")
  end

  defp serve(conn, %Env{deployment: deployment} = env, config) do
    cond do
      deployment.ws? and upgrade?(conn) -> serve_socket(conn, env, config)
      deployment.request? -> serve_request(conn, env, config)
      true -> reject(conn, 404, :no_handler)
    end
  end

  defp upgrade?(conn), do: Enum.any?(get_req_header(conn, "upgrade"), &(String.downcase(&1) == "websocket"))

  defp serve_request(conn, env, config) do
    case read_body(conn,
           length: config.max_body_bytes,
           read_length: config.max_body_bytes,
           read_timeout: config.http.read_timeout_ms
         ) do
      {:ok, body, conn} ->
        request = request(conn, body)

        case route(env, request) do
          {:ok, cell, consistency} ->
            case Dispatch.execute(%{env | consistency: consistency}, cell, {:http, request}) do
              {:ok, response} -> write(conn, response)
              {:error, reason} -> failure(conn, reason, config, cell)
            end

          {:error, reason} ->
            failure(conn, reason, config, nil)
        end

      {:more, _, conn} ->
        reject(conn, 413, :payload_too_large, env)

      {:error, _} ->
        reject(conn, 400, :bad_request, env)
    end
  end

  # `cell` is the cell the request routed to, whose lease a `held_elsewhere` 503 waits for.
  defp failure(conn, :invalid_key, _config, _cell), do: json(conn, 400, "invalid_key")

  defp failure(conn, :overloaded, config, _cell),
    do: unavailable(conn, "overloaded", "overloaded", config.http.retry_after_s)

  defp failure(conn, {:unavailable, reason}, config, cell) do
    retry_after = Unavailable.retry_after_s(config, reason, cell)
    unavailable(conn, "unavailable", reason_name(reason), retry_after)
  end

  # A configuration error, not unavailability: no `Retry-After`, a repeat fails the same way (design §8.4).
  defp failure(conn, {:foreign_store, _node}, _config, _cell),
    do: json(conn, 500, %{error: "foreign_store", reason: "foreign_store"})

  defp failure(conn, :unknown_outcome, config, _cell),
    do: unavailable(conn, "unknown_outcome", "unknown_outcome", config.http.retry_after_s)

  defp failure(conn, {:limit, :timeout}, _config, _cell), do: json(conn, 504, "timeout")
  defp failure(conn, {:limit, _}, _config, _cell), do: json(conn, 500, "limit_exceeded")
  defp failure(conn, _reason, _config, _cell), do: json(conn, 500, "internal_error")

  defp unavailable(conn, error, reason, retry_after_s) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> json(503, %{error: error, reason: reason})
  end

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(reason), do: inspect(reason)

  defp serve_socket(conn, env, config) do
    request = request(conn, "")

    # The bound of `route_key/2` is for plain requests: a socket is served by the owner.
    case route(env, request) do
      {:ok, cell, _consistency} ->
        case Dispatch.execute(env, cell, {:ws_init, request}) do
          {:ok, {:ok, worker}} -> upgrade(conn, config, %{env: env, cell: cell, worker: worker})
          {:ok, {:reject, response}} -> write(conn, response)
          {:error, reason} -> failure(conn, reason, config, cell)
        end

      {:error, reason} ->
        failure(conn, reason, config, nil)
    end
  end

  defp upgrade(conn, config, arg) do
    options = [
      timeout: config.websocket.idle_timeout_ms,
      max_frame_size: config.websocket.max_frame_bytes,
      max_fragmented_message_size: config.websocket.max_frame_bytes
    ]

    WebSockAdapter.upgrade(conn, Socket, Map.put(arg, :expires_at, token_expiry(conn)), options)
  end

  # The `exp` (seconds) of the verified token of a protected route, which the socket must not outlive.
  defp token_expiry(conn) do
    with [value | _] <- get_req_header(conn, Auth.claims_header()),
         {:ok, %{"exp" => exp}} when is_number(exp) <- Auth.decode_claims(value) do
      exp
    else
      _ -> nil
    end
  end

  # No routing key means the work is not bound to a cell.
  defp route(env, request) do
    case Dispatch.route(env, request) do
      {:ok, _cell, _consistency} = routed -> routed
      :none -> {:ok, nil, :strong}
      {:error, _} = error -> error
    end
  end

  defp request(conn, body) do
    %Request{
      method: conn.method,
      scheme: Atom.to_string(conn.scheme),
      host: conn.host,
      port: conn.port,
      path: conn.request_path,
      query: conn.query_string,
      headers: conn.req_headers,
      body: body
    }
  end

  defp write(conn, %Response{status: status, headers: headers, body: body}) do
    conn = Enum.reduce(headers, conn, fn {name, value}, conn -> put_resp_header(conn, String.downcase(name), value) end)
    send_resp(conn, status, body)
  end

  defp serve_plug(conn, %Env{} = env) do
    result =
      Breadcrumb.callback(
        env.instance,
        %{kind: "http", worker: Env.worker(env), deployment: env.deployment.id, cell: nil},
        fn -> Telemetry.call(env, nil, :plug, false, fn -> run_plug(conn, env) end) end
      )

    case result do
      {_, conn} -> conn
    end
  end

  # `{:ok, conn}` when the Plug answered, `{:error, conn}` when it failed.
  defp run_plug(conn, %Env{deployment: deployment} = env) do
    {plug, opts} = deployment.module.plug(env)
    result = plug.call(put_private(conn, :atanor, env), plug.init(opts))

    case result do
      %Plug.Conn{state: state} = conn when state in [:sent, :chunked, :upgraded, :file] ->
        {:ok, conn}

      other ->
        Workers.log(deployment, "returned an unsent conn", inspect(other, limit: 5))
        {:error, json(conn, 500, "internal_error")}
    end
  catch
    kind, reason ->
      Workers.log(deployment, "crashed", Workers.format_crash(kind, reason, __STACKTRACE__))
      {:error, if(conn.state == :unset, do: json(conn, 500, "internal_error"), else: conn)}
  end

  # A request the ingress answers without calling the worker.
  defp reject(conn, status, reason, env \\ nil) do
    meta = %{reason: reason, status: status, host: conn.host, worker: env && Env.worker(env)}
    :telemetry.execute([:atanor, :http, :reject], %{count: 1}, meta)
    json(conn, status, Map.fetch!(@rejections, status))
  end

  defp json(conn, status, error) when is_binary(error), do: json(conn, status, %{error: error})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
