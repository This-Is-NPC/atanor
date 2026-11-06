defmodule Atanor.Cluster.IngressTest do
  @moduledoc """
  What runs on the ingress node and what reaches the owner of the cell (design §8.5).
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests, OIDCProvider, WSClient}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  describe "HTTP with a protected route" do
    setup do
      provider = OIDCProvider.start()
      OIDCProvider.add_key(provider, "k1")
      on_exit(fn -> OIDCProvider.stop(provider) end)

      auth = [[host: "127.0.0.1", path: "/c", issuer: provider.issuer, audience: "api"]]

      cluster =
        start_cluster(
          workers: [Manifests.counter("counter")],
          atanor: [auth: auth, oidc: [allow_http: true]]
        )

      %{cluster: cluster, provider: provider}
    end

    defp calls(cluster, cell, kind \\ :http),
      do: events(cluster, [:atanor, :call], &(&1.cell == {"log", cell} and &1.kind == kind))

    defp post(cluster, via, cell, n, token) do
      {:ok, resp} =
        request(cluster, via, :post, "/c/#{cell}", body: Integer.to_string(n), auth: {:bearer, token})

      resp
    end

    test "a request is authenticated on the ingress; only a valid one reaches the owner", %{
      cluster: c,
      provider: p
    } do
      token = OIDCProvider.token(p, "k1")
      assert %{status: 200} = post(c, :n1, "a", 1, token)
      {:ok, owner} = owner(c, :n1, "log", "a")
      ingress = Enum.find(Cluster.names(c), &(&1 != name_of(c, owner)))
      forwarded = fn -> length(events(c, [:atanor, :forward], &(&1.cell == {"log", "a"}))) end

      # Nodes forward their events to the cluster asynchronously: wait for those of the first request, a forward
      # only when :n1 is not the owner, before counting.
      first_forwards = if name_of(c, owner) == :n1, do: 0, else: 1
      Await.until(fn -> length(calls(c, "a")) == 1 and forwarded.() == first_forwards end)
      before = {length(calls(c, "a")), forwarded.()}

      for bad <- ["not-a-token", OIDCProvider.token(p, "k1", %{"aud" => "other"})],
          do: assert(%{status: 401} = post(c, ingress, "a", 2, bad))

      assert %{status: 200} = resp = post(c, ingress, "a", 3, token)
      body = Jason.decode!(resp.body)
      assert body["node"] == Atom.to_string(owner)
      assert {:ok, %{"sub" => "u1"}} = Atanor.Auth.decode_claims(body["claims"])

      # Two rejected requests left no trace on the owner or in the forwarding; the valid one is one call.
      {calls_before, forwards_before} = before
      Await.until(fn -> length(calls(c, "a")) >= calls_before + 1 and forwarded.() >= forwards_before + 1 end)
      assert length(calls(c, "a")) == calls_before + 1
      assert forwarded.() == forwards_before + 1
    end
  end

  describe "WebSockets" do
    setup do
      chat =
        Manifests.probe("chat",
          module: Atanor.Test.SocketWorker,
          sockets: true,
          cells: %{"rooms" => []},
          routes: [{"127.0.0.1", "/room"}]
        )

      %{cluster: start_cluster(workers: [chat])}
    end

    test "the socket process lives on the ingress node and each frame is one call on the owner", %{cluster: c} do
      {:ok, owner} = Cluster.call(c, :n1, Atanor.Cell, :owner, [Cluster.instance(c), {"rooms", "r1"}]) |> elem(1)
      ingress = Enum.find(Cluster.names(c), &(&1 != name_of(c, owner)))
      port = c |> Cluster.url(ingress) |> URI.parse() |> Map.fetch!(:port)

      clients = for _ <- 1..3, do: elem(WSClient.connect(port, "/room/r1"), 1)
      ws_calls = fn kind -> events(c, [:atanor, :call], &(&1.cell == {"rooms", "r1"} and &1.kind == kind)) end

      Await.until(fn -> length(events(c, [:atanor, :ws, :connect])) == 3 end, 5_000)
      assert Enum.all?(events(c, [:atanor, :ws, :connect]), &(&1.node == ingress))
      assert length(ws_calls.(:ws_init)) == 3

      [one | rest] = clients
      one = WSClient.send_frame(one, {:text, "socket"})
      assert {{:text, socket_node}, one} = WSClient.recv(one, 5_000)
      one = WSClient.send_frame(one, {:text, "node"})
      assert {{:text, callback_node}, one} = WSClient.recv(one, 5_000)
      assert socket_node == Atom.to_string(Cluster.node(c, ingress))
      assert callback_node == Atom.to_string(owner)

      # Frame handling and ws_init ran on the owner; the ingress ran none of the worker's code.
      assert Enum.all?(ws_calls.(:ws_in) ++ ws_calls.(:ws_init), &(&1.meta.node == owner))
      Await.until(fn -> length(ws_calls.(:ws_in)) == 2 end, 5_000)

      # A message to the cell reaches the three sockets on their node, but the worker's handle_ws/3 runs
      # once for each of them on the owner (one `say` and three cell messages).
      [two, three] = rest

      [one, two, three] =
        for client <- [one, two, three] do
          client = WSClient.send_frame(client, {:text, "join r1"})
          assert {{:text, ":ok"}, client} = WSClient.recv(client, 5_000)
          client
        end

      Await.until(fn -> length(ws_calls.(:ws_in)) == 5 end, 5_000)
      joined = 5
      one = WSClient.send_frame(one, {:text, "say r1 hi"})
      assert {{:text, ":ok"}, one} = WSClient.recv(one, 5_000)

      [one, two, three] =
        for client <- [one, two, three] do
          assert {{:text, "cell:hi"}, client} = WSClient.recv(client, 5_000)
          client
        end

      Await.until(fn -> length(ws_calls.(:ws_in)) == joined + 4 end, 5_000)
      assert Enum.all?(ws_calls.(:ws_in), &(&1.meta.node == owner))
      Enum.each([one, two, three], &WSClient.close/1)
    end
  end
end
