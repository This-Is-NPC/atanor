defmodule Atanor.HTTPTest do
  use ExUnit.Case, async: true

  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  setup do
    node = Node.start()
    on_exit(fn -> Node.stop(node) end)
    %{node: node}
  end

  test "answers 404 with a JSON body when there are no routes", %{node: node} do
    for path <- ["/", "/anything/at/all"] do
      resp = Req.get!(node.url <> path, retry: false)
      assert resp.status == 404
      assert ["application/json" <> _] = resp.headers["content-type"]
      assert resp.body == %{"error" => "not_found"}
    end
  end

  test "has no routes registered", %{node: node} do
    assert Atanor.Registry.routes(node.name) == []
  end

  describe "expected unavailability" do
    setup do
      node =
        Node.start(
          workers: [Manifests.probe("w", routes: [{"127.0.0.1", "/"}])],
          http: [retry_after_s: 7]
        )

      on_exit(fn -> Node.stop(node) end)
      %{node: node}
    end

    test "answers 503 with the reason and Retry-After, also when the worker mapped the error to 500", %{node: node} do
      for reason <- Atanor.Unavailable.reasons() -- [:overloaded] do
        resp = Req.get!(node.url <> "/unavailable?reason=#{reason}&status=500", retry: false)

        assert resp.status == 503
        assert resp.headers["retry-after"] == ["7"]
        assert resp.body == %{"error" => "unavailable", "reason" => Atom.to_string(reason)}
      end
    end

    test "overloaded names itself", %{node: node} do
      resp = Req.get!(node.url <> "/unavailable?reason=overloaded&status=500", retry: false)

      assert resp.status == 503
      assert resp.headers["retry-after"] == ["7"]
      assert resp.body == %{"error" => "overloaded", "reason" => "overloaded"}
    end

    test "a worker that handled the error below 500 is left alone", %{node: node} do
      resp = Req.get!(node.url <> "/unavailable?reason=no_quorum&status=404", retry: false)
      assert resp.status == 404
      assert resp.body == %{"handled" => true}
    end

    test "unknown outcome wins when both were marked", %{node: node} do
      resp = Req.get!(node.url <> "/unavailable?reason=no_quorum&status=500&unknown=1", retry: false)

      assert resp.status == 503
      assert resp.body == %{"error" => "unknown_outcome", "reason" => "unknown_outcome"}
    end

    test "a crash after an unavailable cell call is a 503", %{node: node} do
      resp = Req.get!(node.url <> "/unavailable?reason=fenced&status=500&crash=1", retry: false)

      assert resp.status == 503
      assert resp.body == %{"error" => "unavailable", "reason" => "fenced"}
    end

    test "a worker crash without a cause is still a 500", %{node: node} do
      assert Req.get!(node.url <> "/crash", retry: false).status == 500
    end
  end

  test "the default Retry-After is one second" do
    node = Node.start(workers: [Manifests.probe("w", routes: [{"127.0.0.1", "/"}])])
    on_exit(fn -> Node.stop(node) end)

    resp = Req.get!(node.url <> "/unavailable?reason=owner_down&status=500", retry: false)
    assert resp.status == 503
    assert resp.headers["retry-after"] == ["1"]
  end
end
