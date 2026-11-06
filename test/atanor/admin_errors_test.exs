defmodule Atanor.AdminErrorsTest do
  @moduledoc "How the admin API answers a bad request, a missing thing or a store that fails."
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias AlambiqueTestkit.MemoryStore
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @token "errors-token"

  setup do
    node = Node.start(workers: [Manifests.jobs("jobs")], admin: [token: @token, port: 0], alarms: [tick_ms: 20])
    on_exit(fn -> Node.stop(node) end)
    {:ok, node: node}
  end

  defp call(node, method, path, body) do
    Req.request!(
      method: method,
      url: "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path,
      headers: [{"authorization", "Bearer " <> @token}],
      body: body,
      retry: false,
      decode_body: false
    )
  end

  defp answer(node, method, path, body \\ nil) do
    response = call(node, method, path, body)
    {response.status, Jason.decode!(response.body)}
  end

  test "the hot cells are reported as disabled when the node has no hot cell policy", %{node: node} do
    assert {200, %{"enabled" => false}} = answer(node, :get, "/hot-cells")
  end

  test "a query that is not valid is a 400, a missing thing a 404", %{node: node} do
    own = Atom.to_string(node.name)
    assert {400, %{"error" => "invalid_cell"}} = answer(node, :get, "/jobs?cell=nodot")
    assert {400, %{"error" => "invalid_limit"}} = answer(node, :get, "/jobs/jobs/a?limit=0")
    assert {400, %{"error" => "invalid_limit"}} = answer(node, :get, "/operations?limit=many")
    assert {400, %{"error" => "invalid_limit"}} = answer(node, :get, "/crashes?limit=0")
    assert {404, %{"error" => "not_found"}} = answer(node, :get, "/crashes/#{own}/missing")
    assert {404, %{"error" => "not_found"}} = answer(node, :get, "/operations/missing")
    assert {404, %{"error" => "not_found"}} = answer(node, :get, "/jobs/jobs/a/missing")
    assert {404, %{"error" => "not_found"}} = answer(node, :post, "/jobs/jobs/a/missing/discard", "{}")
    assert {404, %{"error" => "not_found"}} = answer(node, :post, "/operations/missing/resume", "{}")
    assert {400, %{"error" => "invalid_cell"}} = answer(node, :post, "/cells/bad%20ns/k/unfreeze", "{}")
  end

  test "a job that is not dead cannot be retried or discarded", %{node: node} do
    {:ok, _} = Atanor.Cell.query(node.name, {"jobs", "a"}, "SELECT 1")
    {:ok, _} = Atanor.Jobs.enqueue_direct(node.name, "jobs", {"jobs", "a"}, %{kind: "test", payload: "ok"})

    assert until(fn ->
             match?(
               {:ok, %{rows: [["done"]]}},
               Atanor.Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs")
             )
           end)

    {200, %{"jobs" => [%{"id" => id}]}} = answer(node, :get, "/jobs/jobs/a")
    assert {409, %{"error" => "not_dead"}} = answer(node, :post, "/jobs/jobs/a/#{id}/retry", "{}")
    assert {409, %{"error" => "not_dead"}} = answer(node, :post, "/jobs/jobs/a/#{id}/discard", "{}")
  end

  test "an operation needs a JSON object, a valid selector and a state that allows the action", %{node: node} do
    assert {400, %{"error" => "invalid_json"}} = answer(node, :post, "/operations", "not json")
    assert {400, %{"error" => "invalid_json"}} = answer(node, :post, "/operations", "[]")
    assert {400, %{"error" => "invalid_operation"}} = answer(node, :post, "/operations", ~s({"selector": 1}))

    {:ok, _} = Atanor.Cell.query(node.name, {"jobs", "a"}, "SELECT 1")

    attrs = %{
      "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
      "action" => %{"worker" => "jobs", "kind" => "x", "payload_base64" => Base.encode64("x")}
    }

    assert {201, %{"id" => id}} = answer(node, :post, "/operations", Jason.encode!(attrs))
    assert {200, %{"state" => "cancelled"}} = answer(node, :post, "/operations/#{id}/cancel", "{}")
    assert {409, %{"error" => "invalid_state"}} = answer(node, :post, "/operations/#{id}/resume", "{}")
  end

  test "a store that fails is a 503 that does not echo the store", %{node: node} do
    {_module, config} = node.store
    secret = {:http, 500, "AKID-SENTINEL"}
    MemoryStore.inject(config, kind: :error, ops: [:get, :list], key: ~r{operations/}, reason: secret)

    for path <- ["/operations", "/operations/some-id"] do
      assert {503, %{"error" => "store_unavailable"}} = answer(node, :get, path)
    end

    assert {503, %{"error" => "store_unavailable"}} = answer(node, :post, "/operations/some-id/pause", "{}")
  end
end
