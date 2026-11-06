defmodule Atanor.Admin do
  @moduledoc """
  The admin API (design §10): JSON about workers, deployments, routes, live
  cells, releases, crash reports, jobs, bulk operations, the failure
  detector's view of the peers, deploys by scoped tokens and their audit log
  (design §10.2.1). It listens on its own port (option `:admin` of
  `Atanor`), loopback by default, and every request needs the operator's token or a
  scoped token (`Atanor.Admin.Tokens`) as `Authorization: Bearer <token>`. It opens before the node loads its
  deployments, so `/health/ready` answers 503 while it does and 200 once the
  node serves; every other endpoint is 503 `not_ready` until then.

  Endpoints that describe the cluster ask every node of the instance through
  `:erpc` and wait at most the `:overview` `:timeout_ms` (5 seconds by
  default); a node that does not answer is reported with `"status": "error"`
  and the response says `"partial": true`. `?limit=` on `/cells` and `/jobs`
  defaults to `:admin` `:default_limit` (100) and is capped by `:max_limit`
  (1,000). The write endpoints are the node-gone hint, dead-letter
  retry/discard, operation create/pause/resume/continue/cancel/undo report and apply, migration
  rehearsal start/cancel, the TLS certificate
  reload of one listener, unfreezing a cell and draining the node (`POST /drain`, `GET /drain`); each is logged and emits
  `[:atanor, :admin, :action]`.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Atanor.Admin.{Audit, Scope, Tokens}
  alias Atanor.Deployments.{Head, Service, Versions}
  alias Atanor.{Deployments, Jobs, Manifest, Overview, Registry, Rehearsal, Sweeps}
  alias Atanor.Sweeps.Undo

  @doc "Name of the admin listener process of the instance."
  def listener(name), do: Module.concat(name, Admin)

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :name)

  @impl true
  def call(conn, name) do
    {need, event} = permission(conn)

    case authenticate(conn, name) do
      {:ok, principal} ->
        conn = assign(conn, :principal, principal)

        if need == :any or Scope.allows?(scopes(principal), need) do
          serve(conn, name, Registry.state(name))
        else
          body = %{error: "forbidden", required: Scope.format(need)}
          if event, do: audited(conn, name, event, 403, body), else: json(conn, 403, body)
        end

      {:error, :unauthorized} ->
        conn |> put_resp_header("www-authenticate", "Bearer") |> json(401, %{error: "unauthorized"})

      {:error, {:store, reason}} ->
        store_unavailable(conn, reason)
    end
  end

  defp authenticate(conn, name) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] -> Tokens.authenticate(name, given)
      _ -> {:error, :unauthorized}
    end
  end

  defp scopes(:operator), do: :all
  defp scopes(%{scopes: scopes}), do: scopes

  # The scope each request needs, and the audit event of the writes. Anything
  # not listed here is an admin endpoint of the operator, `cluster:admin`.
  defp permission(%{path_info: ["health" | _]}), do: {:any, nil}
  defp permission(%{method: "GET", path_info: ["heads"]}), do: {:any, nil}

  defp permission(%{method: "POST", path_info: ["workers", worker, "packages"]}),
    do: {{:worker, worker, :deploy}, %{"action" => "package.upload", "worker" => worker}}

  defp permission(%{method: "POST", path_info: ["workers", worker, "activate"]}),
    do: {{:worker, worker, :activate}, %{"action" => "version.activate", "worker" => worker}}

  defp permission(%{method: "POST", path_info: ["workers", worker, "rollback"]}),
    do: {{:worker, worker, :rollback}, %{"action" => "version.rollback", "worker" => worker}}

  defp permission(%{method: "GET", path_info: ["workers", worker, endpoint]}) when endpoint in ~w(versions status),
    do: {{:worker, worker, :read}, nil}

  defp permission(%{method: "POST", path_info: ["tokens"]}), do: {:cluster, %{"action" => "token.create"}}

  defp permission(%{method: "POST", path_info: ["tokens", id, "revoke"]}),
    do: {:cluster, %{"action" => "token.revoke", "target" => id}}

  defp permission(_conn), do: {:cluster, nil}

  # The listener opens before the node has loaded its deployments (design §2.1):
  # only the health endpoints answer until it is ready.
  defp serve(%{path_info: ["health" | _]} = conn, name, _state), do: route(conn, name)
  defp serve(conn, name, state) when state in [:ready, :draining], do: route(conn, name)

  defp serve(conn, name, _state) do
    {_status, body} = Overview.ready(name)
    json(conn, 503, %{error: "not_ready", reason: body.reason})
  end

  defp route(%{method: "GET", path_info: path} = conn, name), do: get(conn, path, name)
  defp route(%{method: "POST", path_info: ["nodes", node, "gone"]} = conn, name), do: gone(conn, name, node)

  defp route(%{method: "POST", path_info: ["drain"]} = conn, name), do: drain(conn, name)

  defp route(%{method: "POST", path_info: ["listeners", listener, "reload-tls"]} = conn, name),
    do: reload_tls(conn, name, listener)

  defp route(%{method: "POST", path_info: ["operations"]} = conn, name), do: create_operation(conn, name)

  defp route(%{method: "POST", path_info: ["cells", ns, key, "unfreeze"]} = conn, name),
    do: unfreeze(conn, name, ns, key)

  defp route(%{method: "POST", path_info: ["rehearsals"]} = conn, name), do: create_rehearsal(conn, name)

  defp route(%{method: "POST", path_info: ["rehearsals", id, "cancel"]} = conn, name),
    do: cancel_rehearsal(conn, name, id)

  defp route(%{method: "POST", path_info: ["operations", id, "undo"]} = conn, name), do: create_undo(conn, name, id)

  defp route(%{method: "POST", path_info: ["operations", id, action]} = conn, name)
       when action in ~w(pause resume continue cancel),
       do: control_operation(conn, name, id, action)

  defp route(%{method: "POST", path_info: ["jobs", ns, key, id, action]} = conn, name) when action in ~w(retry discard),
    do: control_job(conn, name, ns, key, id, action)

  defp route(%{method: "POST", path_info: ["workers", worker, "packages"]} = conn, name), do: upload(conn, name, worker)

  defp route(%{method: "POST", path_info: ["workers", worker, "activate"]} = conn, name),
    do: activate(conn, name, worker)

  defp route(%{method: "POST", path_info: ["workers", worker, "rollback"]} = conn, name),
    do: rollback(conn, name, worker)

  defp route(%{method: "POST", path_info: ["tokens"]} = conn, name), do: create_token(conn, name)
  defp route(%{method: "POST", path_info: ["tokens", id, "revoke"]} = conn, name), do: revoke_token(conn, name, id)

  defp route(conn, _name), do: json(conn, 405, %{error: "method_not_allowed"})

  defp get(conn, ["health"], name), do: json(conn, 200, Overview.health(name))

  defp get(conn, ["health", "ready"], name) do
    {status, body} = Overview.ready(name)
    json(conn, status, body)
  end

  defp get(conn, ["health", "serving"], name) do
    {status, body} = Overview.serving(name)
    json(conn, status, body)
  end

  defp get(conn, ["drain"], name), do: json(conn, 200, Overview.drain(name))
  defp get(conn, ["nodes"], name), do: json(conn, 200, Overview.peers(name))
  defp get(conn, ["hot-cells"], name), do: json(conn, 200, Overview.hot_cells(name))
  defp get(conn, ["routes"], name), do: json(conn, 200, Overview.routes(name))
  defp get(conn, ["deployments"], name), do: json(conn, 200, Overview.gather(name, :deployments))
  defp get(conn, ["crashes"], name), do: crashes(conn, name, fetch_query_params(conn).query_params)
  defp get(conn, ["crashes", node, id], name), do: crash(conn, name, node, id)
  defp get(conn, ["workers"], name), do: result(conn, Overview.workers(name))
  defp get(conn, ["workers", worker], name), do: result(conn, Overview.worker(name, worker))
  defp get(conn, ["cells"], name), do: cells(conn, name, fetch_query_params(conn).query_params)
  defp get(conn, ["jobs"], name), do: jobs(conn, name, fetch_query_params(conn).query_params)
  defp get(conn, ["jobs", ns, key], name), do: jobs_cell(conn, name, ns, key, fetch_query_params(conn).query_params)
  defp get(conn, ["jobs", ns, key, id], name), do: job(conn, name, ns, key, id)
  defp get(conn, ["rehearsals"], name), do: rehearsals(conn, name, fetch_query_params(conn).query_params)
  defp get(conn, ["rehearsals", id], name), do: rehearsal(conn, name, id)
  defp get(conn, ["operations"], name), do: operations(conn, name, fetch_query_params(conn).query_params)
  defp get(conn, ["operations", id], name), do: operation(conn, name, id)
  defp get(conn, ["operations", id, "undo"], name), do: undo_report(conn, name, id)
  defp get(conn, ["heads"], name), do: heads(conn, name)
  defp get(conn, ["workers", worker, "versions"], name), do: versions(conn, name, worker)
  defp get(conn, ["workers", worker, "status"], name), do: worker_status(conn, name, worker)
  defp get(conn, ["tokens"], name), do: tokens(conn, name, fetch_query_params(conn).query_params)
  defp get(conn, ["tokens", id], name), do: token(conn, name, id)
  defp get(conn, ["audit"], name), do: audit(conn, name, fetch_query_params(conn).query_params)
  defp get(conn, _path, _name), do: json(conn, 404, %{error: "not_found"})

  # The platform's hint that a node is gone (design §8.9).
  defp gone(conn, name, node) do
    action(conn, name, :gone, node)

    case Overview.gone(name, node) do
      {:ok, body} -> json(conn, 200, body)
      {:error, :unknown_node} -> json(conn, 404, %{error: "unknown_node"})
    end
  end

  # Hands this node's cells back and answers when it is done; the node then stops (`stop.exit`, design §8.11).
  defp drain(conn, name) do
    action(conn, name, :drain, node())
    {:ok, status} = Atanor.drain(name)
    json(conn, 200, Overview.drain_body(status))
  end

  # New certificates for one listener; a failed load keeps the previous one (design §7.3).
  defp reload_tls(conn, name, listener) do
    action(conn, name, :reload_tls, listener)

    case Atanor.TCP.TLS.reload(name, listener, :admin) do
      :ok ->
        json(conn, 200, %{listener: listener, reloaded: true})

      {:error, :unknown_listener} ->
        json(conn, 404, %{error: "unknown_listener"})

      {:error, :no_tls} ->
        json(conn, 409, %{error: "no_tls"})

      {:error, reason} ->
        json(conn, 422, %{error: "reload_failed", reason: Atanor.TCP.TLS.format_error(reason)})
    end
  end

  # Crashes and frozen cells.
  defp crashes(conn, name, params) do
    with {:ok, limit} <- limit(params["limit"], Registry.config(name).admin) do
      case Overview.crashes(name, node: params["node"], after: params["after"], limit: limit) do
        {:ok, page} -> json(conn, 200, page)
        {:error, reason} -> json(conn, 503, store_unavailable_body(reason))
      end
    else
      {:error, :invalid_limit} -> json(conn, 400, %{error: "invalid_limit"})
    end
  end

  defp crash(conn, name, node, id) do
    case Overview.crash(name, node, id) do
      {:ok, report} -> json(conn, 200, report)
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 503, store_unavailable_body(reason))
    end
  end

  defp unfreeze(conn, name, ns, key) do
    action(conn, name, :unfreeze_cell, {ns, key})

    case Overview.unfreeze(name, {ns, key}) do
      :ok ->
        json(conn, 200, %{cell: ns <> "." <> key, frozen: false})

      {:error, reason} when reason in [:invalid_address, :invalid_namespace, :invalid_key] ->
        json(conn, 400, %{error: "invalid_cell"})

      {:error, reason} ->
        json(conn, 503, store_unavailable_body(reason))
    end
  end

  # Cells: counts of every node, or one page of one node's cells (`?node=`).
  defp cells(conn, name, %{"node" => node} = params) do
    nodes = Map.new(Overview.nodes(name), &{Atom.to_string(&1), &1})

    with {:ok, target} <- Map.fetch(nodes, node),
         {:ok, limit} <- limit(params["limit"], Registry.config(name).admin),
         {:ok, page} <- Overview.call_node(name, target, :cells_page, [params["after"], limit]) do
      json(conn, 200, Map.put(page, :node, node))
    else
      :error -> json(conn, 404, %{error: "unknown_node"})
      {:error, :invalid_limit} -> json(conn, 400, %{error: "invalid_limit"})
      {:error, reason} -> json(conn, 504, %{error: "node_unreachable", reason: inspect(reason)})
    end
  end

  defp cells(conn, name, _params) do
    report = Overview.gather(name, :cells_count)
    total = for {_, %{count: count}} <- report.nodes, reduce: 0, do: (acc -> acc + count)
    json(conn, 200, Map.put(report, :total, total))
  end

  # Jobs: per-node counts, or one cell's jobs (`?cell=namespace.key`).
  defp jobs(conn, name, %{"cell" => cell} = params) do
    case Atanor.Cell.parse(cell) do
      {:ok, address} -> jobs_cell(conn, name, elem(address, 0), elem(address, 1), params)
      _ -> json(conn, 400, %{error: "invalid_cell"})
    end
  end

  defp jobs(conn, name, _params) do
    report = Overview.gather(name, :jobs_stats)
    total = for {_, %{running: running}} <- report.nodes, reduce: 0, do: (acc -> acc + running)
    json(conn, 200, Map.put(report, :total, total))
  end

  defp jobs_cell(conn, name, ns, key, params) do
    admin = Registry.config(name).admin

    with {:ok, limit} <- limit(params["limit"], admin) do
      case Overview.jobs_page(name, {ns, key}, after: params["after"], limit: limit, state: params["state"]) do
        {:ok, page} -> json(conn, 200, page)
        {:error, reason} -> json(conn, 503, store_unavailable_body(reason))
      end
    else
      {:error, :invalid_limit} -> json(conn, 400, %{error: "invalid_limit"})
    end
  end

  defp job(conn, name, ns, key, id) do
    case Overview.job(name, {ns, key}, id) do
      {:ok, job} -> json(conn, 200, job)
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 503, store_unavailable_body(reason))
    end
  end

  # Operations.
  defp operations(conn, name, params) do
    admin = Registry.config(name).admin

    with {:ok, limit} <- limit(params["limit"], admin) do
      case Overview.operations(name, params["after"], limit) do
        {:ok, operations} -> json(conn, 200, %{operations: operations})
        {:error, reason} -> json(conn, 503, store_unavailable_body(reason))
      end
    else
      {:error, :invalid_limit} -> json(conn, 400, %{error: "invalid_limit"})
    end
  end

  defp operation(conn, name, id) do
    case Overview.operation(name, id) do
      {:ok, operation} -> json(conn, 200, operation)
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 503, store_unavailable_body(reason))
    end
  end

  defp create_operation(conn, name) do
    case read_json(conn) do
      {:ok, attrs, conn} ->
        action(conn, name, :create_operation, attrs["selector"])

        try do
          case Sweeps.start(name, attrs) do
            {:ok, operation} -> json(conn, 201, operation)
            {:error, :too_many_operations} -> json(conn, 429, %{error: "too_many_operations"})
            {:error, reason} -> json(conn, 400, %{error: "invalid_operation", reason: inspect(reason)})
          end
        rescue
          exception -> json(conn, 400, %{error: "invalid_operation", reason: Exception.message(exception)})
        end

      {:error, conn} ->
        json(conn, 400, %{error: "invalid_json"})
    end
  rescue
    exception -> json(conn, 400, %{error: "invalid_operation", reason: Exception.message(exception)})
  end

  defp control_operation(conn, name, id, action) do
    action(conn, name, String.to_atom(action), id)

    result =
      case action do
        "pause" -> Sweeps.pause(name, id)
        "resume" -> Sweeps.resume(name, id)
        "continue" -> Sweeps.continue(name, id)
        "cancel" -> Sweeps.cancel(name, id)
      end

    case result do
      {:ok, operation} -> json(conn, 200, operation)
      {:error, :invalid_state} -> json(conn, 409, %{error: "invalid_state"})
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 503, store_unavailable_body(reason))
    end
  end

  # Undo of operations (design §15.10): a report, then a rewind of the cells.
  defp create_undo(conn, name, id) do
    case read_json(conn) do
      {:ok, attrs, conn} -> start_undo(conn, name, id, Map.get(attrs, "mode", "report"))
      {:error, conn} -> json(conn, 400, %{error: "invalid_json"})
    end
  end

  defp start_undo(conn, name, id, "report") do
    action(conn, name, :undo_report, id)
    undo_started(conn, Undo.start(name, id))
  end

  defp start_undo(conn, name, id, "apply") do
    action(conn, name, :undo_apply, id)
    undo_started(conn, Undo.rewind(name, id))
  end

  defp start_undo(conn, _name, _id, _mode),
    do: json(conn, 400, %{error: "invalid_mode", reason: "mode must be \"report\" or \"apply\""})

  defp undo_started(conn, {:ok, record}), do: json(conn, 202, %{undo_id: record["undo_id"], state: record["state"]})
  defp undo_started(conn, {:error, error}), do: undo_error(conn, error)

  defp undo_report(conn, name, id) do
    case Undo.get(name, id) do
      {:ok, report} -> json(conn, 200, report)
      {:error, error} -> undo_error(conn, error)
    end
  end

  defp undo_error(conn, :not_found), do: json(conn, 404, %{error: "not_found"})

  defp undo_error(conn, error)
       when error in [
              :undo_not_enabled,
              :already_running,
              :operation_active,
              :report_required,
              :report_truncated,
              :jobs_active
            ],
       do: json(conn, 409, %{error: Atom.to_string(error)})

  defp undo_error(conn, {:store, reason}),
    do: json(conn, 503, store_unavailable_body(reason))

  # Migration rehearsals (design §17.3).
  defp rehearsals(conn, name, params) do
    with {:ok, limit} <- limit(params["limit"], Registry.config(name).admin) do
      case Rehearsal.list(name, limit) do
        {:ok, records} -> json(conn, 200, %{rehearsals: records})
        {:error, error} -> rehearsal_error(conn, error)
      end
    else
      {:error, :invalid_limit} -> json(conn, 400, %{error: "invalid_limit"})
    end
  end

  defp rehearsal(conn, name, id) do
    case Rehearsal.get(name, id) do
      {:ok, record} -> json(conn, 200, record)
      {:error, error} -> rehearsal_error(conn, error)
    end
  end

  defp create_rehearsal(conn, name) do
    case read_json(conn) do
      {:ok, attrs, conn} ->
        action(conn, name, :start_rehearsal, {attrs["worker"], attrs["id"]})

        case Rehearsal.start(name, attrs) do
          {:ok, record} -> json(conn, 202, Map.take(record, ~w(id state worker package)))
          {:error, error} -> rehearsal_error(conn, error)
        end

      {:error, conn} ->
        json(conn, 400, %{error: "invalid_json"})
    end
  end

  defp cancel_rehearsal(conn, name, id) do
    action(conn, name, :cancel_rehearsal, id)

    case Rehearsal.cancel(name, id) do
      {:ok, record} -> json(conn, 200, record)
      {:error, error} -> rehearsal_error(conn, error)
    end
  end

  defp rehearsal_error(conn, {:invalid, message}), do: json(conn, 400, %{error: "invalid_rehearsal", reason: message})
  defp rehearsal_error(conn, :wrong_worker), do: json(conn, 400, %{error: "wrong_worker"})
  defp rehearsal_error(conn, :package_not_found), do: json(conn, 404, %{error: "package_not_found"})
  defp rehearsal_error(conn, :not_found), do: json(conn, 404, %{error: "not_found"})
  defp rehearsal_error(conn, :already_running), do: json(conn, 409, %{error: "already_running"})
  defp rehearsal_error(conn, :invalid_state), do: json(conn, 409, %{error: "invalid_state"})

  defp rehearsal_error(conn, {:store, reason}),
    do: json(conn, 503, store_unavailable_body(reason))

  # Deploys (design §5.4, §10.2): the bucket is written by the node, not by the caller.
  defp upload(conn, name, worker) do
    admin = Registry.config(name).admin
    params = fetch_query_params(conn).query_params
    event = %{"action" => "package.upload", "worker" => worker}
    action(conn, name, :upload_package, worker)

    with {:ok, activate?} <- flag(params["activate"]),
         :ok <- activate_scope(conn, worker, activate?),
         {:ok, expected} <- expected_hash(conn),
         event = Map.put(event, "version", version(expected)),
         {:ok, bytes, conn} <- read_package(conn, admin.max_package_bytes) do
      case Service.upload(name, worker, bytes, expected,
             max_bytes: admin.max_package_bytes,
             activate: activate?,
             uploaded_by: actor(conn.assigns.principal)
           ) do
        {:ok, package, head} ->
          body = %{worker: worker, package_id: package.id, kind: package.manifest.kind, size: byte_size(bytes)}
          audited(conn, name, %{event | "version" => package.id}, 201, activated(body, head))

        {:error, error} ->
          {status, body} = deploy_error(error, admin)
          audited(conn, name, event, status, body)
      end
    else
      {:error, {status, body}} -> audited(conn, name, event, status, body)
    end
  end

  defp version(id), do: if(Head.id?(id), do: id)

  defp activated(body, nil), do: Map.put(body, :head, nil)
  defp activated(body, head), do: Map.put(body, :head, Head.to_map(head))

  defp flag(nil), do: {:ok, false}
  defp flag("false"), do: {:ok, false}
  defp flag("true"), do: {:ok, true}
  defp flag(_), do: {:error, {400, %{error: "invalid_activate", reason: "activate must be true or false"}}}

  # Uploading with `?activate=true` also needs the activate scope.
  defp activate_scope(_conn, _worker, false), do: :ok

  defp activate_scope(conn, worker, true) do
    need = {:worker, worker, :activate}

    if Scope.allows?(scopes(conn.assigns.principal), need),
      do: :ok,
      else: {:error, {403, %{error: "forbidden", required: Scope.format(need)}}}
  end

  defp expected_hash(conn) do
    case get_req_header(conn, "x-package-sha256") do
      [hash] -> {:ok, String.downcase(hash)}
      _ -> {:error, {400, %{error: "missing_hash", reason: "send the package SHA-256 (hex) in x-package-sha256"}}}
    end
  end

  defp read_package(conn, max) do
    declared = conn |> get_req_header("content-length") |> List.first() |> then(&Integer.parse(&1 || "0"))

    if match?({n, _} when n > max, declared) do
      {:error, {413, too_large(max)}}
    else
      case read_body(conn, length: max, read_length: 1_000_000) do
        {:ok, bytes, conn} -> {:ok, bytes, conn}
        {:more, _, _conn} -> {:error, {413, too_large(max)}}
        {:error, _} -> {:error, {400, %{error: "invalid_body"}}}
      end
    end
  end

  defp too_large(max), do: %{error: "package_too_large", max_bytes: max}

  defp deploy_error(:too_large, admin), do: {413, too_large(admin.max_package_bytes)}
  defp deploy_error(:invalid_hash, _), do: {400, %{error: "invalid_hash", reason: "expected 64 hex characters"}}
  defp deploy_error(:hash_mismatch, _), do: {422, %{error: "hash_mismatch"}}

  defp deploy_error({:invalid_package, reason}, _),
    do: {422, %{error: "invalid_package", reason: format_package_error(reason)}}

  defp deploy_error({:package_of_other_worker, other}, _),
    do: {422, %{error: "package_of_other_worker", package_worker: other}}

  defp deploy_error({:package_of_other_worker, other, _worker}, admin),
    do: deploy_error({:package_of_other_worker, other}, admin)

  defp deploy_error({:partitions_changed, ns, recorded, declared}, _),
    do: {409, %{error: "partitions_changed", namespace: ns, recorded: recorded, declared: declared}}

  defp deploy_error({:namespace_has_data, ns}, _), do: {409, %{error: "namespace_has_data", namespace: ns}}

  # What the operator's policy and the other workers allow (design §3.3). The body names the subject, never
  # another worker.
  defp deploy_error({tag, subject, _}, _)
       when tag in [
              :host_not_allowed,
              :http_not_allowed,
              :module_not_allowed,
              :listener_not_allowed,
              :namespace_not_allowed
            ],
       do: {422, %{error: Atom.to_string(tag), subject: subject}}

  defp deploy_error({tag, subject, _}, _) when tag in [:namespace_owned, :namespace_conflict, :listener_taken],
    do: {409, %{error: Atom.to_string(tag), subject: subject}}

  defp deploy_error({:route_taken, host, path, _}, _), do: {409, %{error: "route_taken", subject: host <> path}}
  defp deploy_error({:migrations_lowered, ns}, _), do: {409, %{error: "migrations_lowered", subject: ns}}
  defp deploy_error({:module_not_loaded, name}, _), do: {422, %{error: "module_not_loaded", subject: name}}
  defp deploy_error({:listener_not_configured, name}, _), do: {422, %{error: "listener_not_configured", subject: name}}

  defp deploy_error({:listener_protocol_mismatch, name, _, _}, _),
    do: {422, %{error: "listener_protocol_mismatch", subject: name}}

  defp deploy_error({:store_unavailable, reason}, _), do: {503, store_unavailable_body(reason)}

  defp deploy_error({stage, reason}, admin) when stage in [:publish, :activate], do: deploy_error(reason, admin)
  defp deploy_error(:invalid_worker, _), do: {400, %{error: "invalid_worker"}}
  defp deploy_error(:invalid_id, _), do: {400, %{error: "invalid_package_id"}}
  defp deploy_error(:not_found, _), do: {404, %{error: "package_not_found"}}
  defp deploy_error(:no_previous, _), do: {409, %{error: "no_previous"}}
  defp deploy_error(:conflict, _), do: {409, %{error: "conflict"}}
  defp deploy_error(reason, _), do: {503, store_unavailable_body(reason)}

  defp format_package_error({:invalid_manifest, _, _} = error), do: Manifest.format_error(error)
  defp format_package_error(reason), do: inspect(reason)

  defp activate(conn, name, worker) do
    event = %{"action" => "version.activate", "worker" => worker}
    action(conn, name, :activate, worker)

    case read_json(conn) do
      {:ok, attrs, conn} ->
        id = attrs["package_id"]
        event = Map.put(event, "version", version(id))

        case Deployments.activate(name, worker, id) do
          {:ok, head} ->
            audited(conn, name, event, 200, Head.to_map(head))

          {:error, error} ->
            {status, body} = deploy_error(error, nil)
            audited(conn, name, event, status, body)
        end

      {:error, conn} ->
        audited(conn, name, event, 400, %{error: "invalid_json"})
    end
  end

  defp rollback(conn, name, worker) do
    event = %{"action" => "version.rollback", "worker" => worker}
    action(conn, name, :rollback, worker)

    case Deployments.rollback(name, worker) do
      {:ok, head} ->
        audited(conn, name, Map.put(event, "version", head.active), 200, Head.to_map(head))

      {:error, error} ->
        {status, body} = deploy_error(error, nil)
        audited(conn, name, event, status, body)
    end
  end

  # The head and the uploaded versions, oldest first.
  defp versions(conn, name, worker) do
    params = fetch_query_params(conn).query_params

    with {:ok, limit} <- limit(params["limit"], Registry.config(name).admin),
         {:ok, head} <- head_or_blank(name, worker),
         {:ok, entries, next} <- Versions.list(name, worker, params["after"], limit),
         true <- head.revision > 0 or entries != [] do
      mark = fn entry ->
        id = entry["package_id"]

        state =
          cond do
            id == head.active -> "active"
            id in head.previous -> "previous"
            true -> nil
          end

        Map.put(entry, "state", state)
      end

      json(conn, 200, Map.merge(Head.to_map(head), %{versions: Enum.map(entries, mark), next: next}))
    else
      false -> json(conn, 404, %{error: "not_found"})
      {:error, :invalid_limit} -> json(conn, 400, %{error: "invalid_limit"})
      {:error, error} -> error_json(conn, error)
    end
  end

  defp head_or_blank(name, worker) do
    case Deployments.head(name, worker) do
      {:error, :not_found} -> {:ok, %Head{worker: worker}}
      other -> other
    end
  end

  defp worker_status(conn, name, worker) do
    case Deployments.head(name, worker) do
      {:ok, head} ->
        applied = Map.get(Deployments.status(name), worker, %{applied: nil, error: nil})

        json(
          conn,
          200,
          Map.merge(Head.to_map(head), %{
            node: node(),
            applied: applied.applied,
            error: applied.error && inspect(applied.error)
          })
        )

      {:error, error} ->
        error_json(conn, error)
    end
  end

  # The heads the token may read.
  defp heads(conn, name) do
    case Deployments.list(name) do
      {:ok, heads} ->
        scopes = scopes(conn.assigns.principal)
        visible = for head <- heads, Scope.allows?(scopes, {:worker, head.worker, :read}), do: Head.to_map(head)
        json(conn, 200, %{workers: visible})

      {:error, error} ->
        error_json(conn, error)
    end
  end

  defp error_json(conn, :not_found), do: json(conn, 404, %{error: "not_found"})
  defp error_json(conn, :invalid_worker), do: json(conn, 400, %{error: "invalid_worker"})
  defp error_json(conn, reason), do: store_unavailable(conn, reason)

  # Scoped tokens and the audit log (design §10.2).
  defp create_token(conn, name) do
    event = %{"action" => "token.create"}
    action(conn, name, :create_token, nil)

    case read_json(conn) do
      {:ok, attrs, conn} ->
        case Tokens.create(name, attrs, actor_id(conn.assigns.principal)) do
          {:ok, record, secret} ->
            audited(conn, name, Map.put(event, "target", record["id"]), 201, Map.put(record, "token", secret))

          {:error, error} ->
            token_error(conn, name, event, error)
        end

      {:error, conn} ->
        audited(conn, name, event, 400, %{error: "invalid_json"})
    end
  end

  defp revoke_token(conn, name, id) do
    event = %{"action" => "token.revoke", "target" => id}
    action(conn, name, :revoke_token, id)

    case Tokens.revoke(name, id, actor_id(conn.assigns.principal)) do
      {:ok, record} -> audited(conn, name, event, 200, record)
      {:error, error} -> token_error(conn, name, event, error)
    end
  end

  defp tokens(conn, name, params) do
    with {:ok, limit} <- limit(params["limit"], Registry.config(name).admin) do
      case Tokens.list(name, params["after"], limit) do
        {:ok, records, next} -> json(conn, 200, %{tokens: records, next: next})
        {:error, {:store, reason}} -> store_unavailable(conn, reason)
      end
    else
      {:error, :invalid_limit} -> json(conn, 400, %{error: "invalid_limit"})
    end
  end

  defp token(conn, name, id) do
    case Tokens.get(name, id) do
      {:ok, record} -> json(conn, 200, record)
      {:error, {:store, reason}} -> store_unavailable(conn, reason)
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
    end
  end

  defp token_error(conn, name, event, {:invalid, message}),
    do: audited(conn, name, event, 400, %{error: "invalid_token", reason: message})

  defp token_error(conn, name, event, :not_found), do: audited(conn, name, event, 404, %{error: "not_found"})

  defp token_error(conn, name, event, {:store, reason}),
    do: audited(conn, name, event, 503, store_unavailable_body(reason))

  defp audit(conn, name, params) do
    with {:ok, limit} <- limit(params["limit"], Registry.config(name).admin) do
      case Audit.list(name, params["after"], limit) do
        {:ok, entries, next} -> json(conn, 200, %{entries: entries, next: next})
        {:error, reason} -> store_unavailable(conn, reason)
      end
    else
      {:error, :invalid_limit} -> json(conn, 400, %{error: "invalid_limit"})
    end
  end

  defp actor_id(:operator), do: "operator"
  defp actor_id(%{id: id}), do: id

  defp actor(:operator), do: %{"type" => "operator"}
  defp actor(%{id: id, name: name}), do: %{"type" => "token", "id" => id, "name" => name}

  # Answers and records the event in the audit log.
  defp audited(conn, name, event, status, body) do
    result = if(status < 300, do: "ok", else: if(status == 403, do: "denied", else: "failed"))

    entry =
      Map.merge(
        %{
          "actor" => actor(conn.assigns.principal),
          "status" => status,
          "result" => result,
          "error" => body[:error],
          "remote_ip" => conn.remote_ip |> :inet.ntoa() |> to_string()
        },
        event
      )

    Audit.record(name, entry)
    json(conn, status, body)
  end

  defp store_unavailable(conn, reason), do: json(conn, 503, store_unavailable_body(reason))

  # The store's error can hold a response of the object store (bucket, keys, request ids): it goes to the log, not to the client.
  defp store_unavailable_body(reason) do
    Logger.warning("atanor admin: store unavailable: " <> inspect(reason, limit: 20, printable_limit: 500))
    %{error: "store_unavailable"}
  end

  defp control_job(conn, name, ns, key, id, action) do
    action(conn, name, String.to_atom(action), {ns, key, id})

    result =
      case action do
        "retry" -> Jobs.retry(name, {ns, key}, id)
        "discard" -> Jobs.discard(name, {ns, key}, id)
      end

    case result do
      :ok -> json(conn, 200, %{ok: true})
      {:error, :not_dead} -> json(conn, 409, %{error: "not_dead"})
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 503, store_unavailable_body(reason))
    end
  end

  defp read_json(conn) do
    case read_body(conn, length: 1_000_000) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, attrs} when is_map(attrs) -> {:ok, attrs, conn}
          _ -> {:error, conn}
        end

      {:more, _body, conn} ->
        {:error, conn}

      {:error, _reason} ->
        {:error, conn}
    end
  end

  # Every control action is logged (who/what) and emitted as telemetry.
  defp action(conn, name, action, target) do
    remote = conn.remote_ip |> :inet.ntoa() |> to_string()
    Logger.info("atanor admin #{action} #{inspect(target)} from #{remote} on #{node()}")

    :telemetry.execute([:atanor, :admin, :action], %{count: 1}, %{
      instance: name,
      action: action,
      target: inspect(target),
      remote_ip: remote,
      node: node()
    })
  end

  defp limit(nil, admin), do: {:ok, admin.default_limit}

  defp limit(text, admin) do
    case Integer.parse(text) do
      {n, ""} when n in 1..admin.max_limit//1 -> {:ok, n}
      _ -> {:error, :invalid_limit}
    end
  end

  defp result(conn, {:ok, body}), do: json(conn, 200, body)
  defp result(conn, {:error, :not_found}), do: json(conn, 404, %{error: "not_found"})
  defp result(conn, {:error, _}), do: json(conn, 503, %{error: "store_unavailable"})

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
