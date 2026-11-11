defmodule Atanor.CallPinningTest do
  @moduledoc "Nested worker calls reach the deployment that was active when the request began (design §4)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.{Deployments, Registry}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @versions 4

  defp caller, do: Manifests.probe("a", routes: [{"pin.test", "/"}], workers: ["b"])
  defp callee(n), do: Manifests.probe("b", callable_by: ["a"], limits: %{"timeout_ms" => n})

  defp start do
    packages = Map.new(1..@versions, fn n -> {n, Manifests.package(callee(n))} end)
    node = Node.start(workers: [caller(), callee(1)])
    for {_, package} <- packages, do: {:ok, _} = Deployments.publish(node.name, package)
    {node, Map.new(packages, fn {n, package} -> {n, package.id} end)}
  end

  defp activate(node, ids, n) do
    {:ok, _} = Deployments.activate(node.name, "b", ids[n])
    :ok = Deployments.sync(node.name)
  end

  # Starts a request that calls `b`, waits for `:go`, and calls `b` again.
  defp start_request(node) do
    pid = Base.encode64(:erlang.term_to_binary(self()))
    query = URI.encode_query(worker: "b", path: "/b/echo")

    task =
      Task.async(fn ->
        Req.get!(node.url <> "/pair?" <> query, headers: [{"host", "pin.test"}, {"x-test-pid", pid}], retry: false)
      end)

    assert_receive {:in_handler, handler}, 5_000
    {task, handler}
  end

  defp seen(%{"ok" => %{"body" => body}}), do: Jason.decode!(body)["deployment"]

  defp finish({task, handler}) do
    send(handler, :go)
    body = Task.await(task, 5_000).body
    {seen(body["first"]), seen(body["second"])}
  end

  test "two calls of one request reach one version of the callee across an activation" do
    {node, ids} = start()
    on_exit(fn -> Node.stop(node) end)

    request = start_request(node)
    activate(node, ids, 2)
    assert {:ok, %{id: new}} = Registry.deployment(node.name, "b")
    assert new == ids[2]

    assert finish(request) == {ids[1], ids[1]}
    # A later request resolves the new version.
    {task, handler} = start_request(node)
    assert finish({task, handler}) == {ids[2], ids[2]}
  end

  property "every call of a request reaches the version that was active when it began" do
    check all(
            ops <-
              list_of(
                one_of([tuple({constant(:activate), integer(1..@versions)}), constant(:request), constant(:release)]),
                max_length: 20
              ),
            max_runs: 25
          ) do
      {node, ids} = start()

      try do
        by_id = Map.new(ids, fn {n, id} -> {id, n} end)

        {open, _} =
          Enum.reduce(ops, {[], 1}, fn
            {:activate, n}, {open, _} ->
              activate(node, ids, n)
              {open, n}

            :request, {open, current} ->
              {open ++ [{start_request(node), ids[current]}], current}

            :release, {[], current} ->
              {[], current}

            :release, {[{request, first} | rest], current} ->
              assert finish(request) == {first, first}
              {rest, current}
          end)

        for {request, first} <- open, do: assert(finish(request) == {first, first})
        assert map_size(by_id) == @versions
      after
        Node.stop(node)
      end
    end
  end
end
