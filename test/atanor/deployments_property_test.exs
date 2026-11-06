defmodule Atanor.DeploymentsPropertyTest do
  @moduledoc "Guarantee D1 (design §5): a request runs entirely on the deployment it started on."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.{Deployments, Registry}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @versions 4

  defp manifest(n), do: Manifests.probe("w", routes: [{"span.test", "/"}], limits: %{"timeout_ms" => n})

  defp operation,
    do:
      one_of([
        tuple({constant(:activate), integer(1..@versions)}),
        constant(:rollback),
        constant(:request),
        constant(:release)
      ])

  # Starts a request and waits until its handler is running. The response is
  # produced after `:go`.
  defp start_request(node) do
    pid = Base.encode64(:erlang.term_to_binary(self()))

    task =
      Task.async(fn ->
        Req.get!(node.url <> "/span", headers: [{"host", "span.test"}, {"x-test-pid", pid}], retry: false)
      end)

    assert_receive {:in_handler, handler}, 5_000
    {task, handler}
  end

  property "every request reports one deployment at its start and end, and it was active during the request" do
    check all(ops <- list_of(operation(), max_length: 25), max_runs: 40) do
      node = Node.start()

      try do
        packages = Map.new(1..@versions, fn n -> {n, Manifests.package(manifest(n))} end)
        ids = Map.new(packages, fn {n, package} -> {n, package.id} end)
        for {_, package} <- packages, do: {:ok, _} = Deployments.publish(node.name, package)

        {:ok, _} = Deployments.activate(node.name, "w", ids[1])
        :ok = Deployments.sync(node.name)

        # timeline: every deployment that was active, oldest last.
        state = %{timeline: [ids[1]], open: [], versions: Map.new(ids, fn {n, id} -> {id, n} end)}
        final = Enum.reduce(ops, state, &run(&1, &2, node, ids))

        # Release what is still open, then check every request.
        final = Enum.reduce(final.open, final, fn _, acc -> run(:release, acc, node, ids) end)
        assert final.open == []
      after
        Node.stop(node)
      end
    end
  end

  defp run({:activate, n}, state, node, ids),
    do: switch(state, node, fn -> Deployments.activate(node.name, "w", ids[n]) end)

  defp run(:rollback, state, node, _ids), do: switch(state, node, fn -> Deployments.rollback(node.name, "w") end)

  defp run(:request, state, node, _ids) do
    {task, handler} = start_request(node)

    %{
      state
      | open: state.open ++ [%{task: task, handler: handler, seen: hd(state.timeline), since: length(state.timeline)}]
    }
  end

  defp run(:release, %{open: []} = state, _node, _ids), do: state

  defp run(:release, %{open: [request | rest]} = state, _node, _ids) do
    send(request.handler, :go)
    body = Task.await(request.task, 5_000).body

    # Active at some moment of the request: the timeline since it started.
    during = Enum.take(state.timeline, length(state.timeline) - request.since + 1)

    assert body["start"] == body["end"]
    assert body["start"] in during
    assert body["start"] == request.seen
    assert body["limit"] == state.versions[body["start"]]
    %{state | open: rest}
  end

  defp switch(state, node, change) do
    change.()
    :ok = Deployments.sync(node.name)
    {:ok, current} = Registry.deployment(node.name, "w")
    if current.id == hd(state.timeline), do: state, else: %{state | timeline: [current.id | state.timeline]}
  end
end
