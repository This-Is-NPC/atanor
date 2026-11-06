defmodule Atanor.EgressFetchTest do
  use ExUnit.Case, async: true

  alias Atanor.{Env, Request}
  alias Atanor.Test.{HTTPTarget, Manifests}
  alias AtanorTestkit.Node

  # An env of a worker that may fetch `allow`, on a node that lets loopback through.
  defp env(allow, opts \\ []) do
    node = Node.start([workers: [Manifests.probe("w", allow: allow)], allow_private_hosts: ["127.0.0.0/8"]] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    {:ok, deployment} = Atanor.Registry.deployment(node.name, "w")
    Env.new(node.name, deployment)
  end

  defp request(port, path, opts \\ []),
    do: struct!(%Request{host: Keyword.get(opts, :host, "127.0.0.1"), port: port, path: path}, opts)

  # The fetch runs in a task so that a fetch that never returns fails the test instead of hanging it.
  defp fetch(env, request, wait_ms \\ 10_000) do
    task = Task.async(fn -> Env.fetch(env, request) end)
    Task.yield(task, wait_ms) || Task.shutdown(task, :brutal_kill) || :still_running
  end

  describe "response body" do
    setup do
      {_target, port} = HTTPTarget.start(self())
      %{port: port, env: env(["127.0.0.1"])}
    end

    test "is refused above the default cap", %{env: env, port: port} do
      assert {:ok, {:error, :response_too_large}} = fetch(env, request(port, "/big", query: "bytes=20000000"))
    end

    test "is refused above the configured cap, and read below it", %{port: port} do
      env = env(["127.0.0.1"], calls: [fetch_max_bytes: 100_000])
      assert {:ok, {:error, :response_too_large}} = fetch(env, request(port, "/big", query: "bytes=1000000"))
      assert {:ok, {:ok, %{status: 200, body: body}}} = fetch(env, request(port, "/big", query: "bytes=65536"))
      assert byte_size(body) == 65_536
    end
  end

  describe "deadline" do
    setup do
      {_target, port} = HTTPTarget.start(self())
      %{port: port, env: env(["127.0.0.1"], calls: [fetch_timeout_ms: 300])}
    end

    test "ends a response that never completes", %{env: env, port: port} do
      assert {:ok, {:error, :timeout}} = fetch(env, request(port, "/hang"))
    end

    test "is for the whole response, not for each read", %{env: env, port: port} do
      assert {:ok, {:error, :timeout}} = fetch(env, request(port, "/drip"))
    end

    test "is also bounded by the timeout the caller gives", %{port: port} do
      env = env(["127.0.0.1"])
      task = Task.async(fn -> Env.fetch(env, request(port, "/hang"), timeout_ms: 200) end)
      assert {:ok, {:error, :timeout}} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
    end
  end

  describe "connections" do
    test "to many host names do not start a pool each" do
      {:ok, server} = Bandit.start_link(plug: {HTTPTarget, self()}, port: 0, ip: :any, startup_log: false)
      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      hosts = for i <- 1..40, do: "127.0.1.#{i}"
      env = env(hosts)

      pools = DynamicSupervisor.count_children(Req.FinchSupervisor).active

      for host <- hosts, do: assert({:ok, %{status: 200}} = Env.fetch(env, request(port, "/ok", host: host)))

      assert DynamicSupervisor.count_children(Req.FinchSupervisor).active - pools < 5
    end
  end

  describe "redirects" do
    setup do
      {_a, a} = HTTPTarget.start(self())
      {_b, b} = HTTPTarget.start(self())
      %{a: a, b: b, env: env(["127.0.0.1"])}
    end

    @credentials [{"authorization", "secret"}, {"cookie", "k=v"}, {"proxy-authorization", "p"}, {"x-keep", "1"}]

    test "to another origin do not carry credentials", %{env: env, a: a, b: b} do
      to = URI.encode_www_form("http://127.0.0.1:#{b}/ok")

      assert {:ok, {:ok, %{status: 200}}} =
               fetch(env, request(a, "/redirect-to", query: "to=" <> to, headers: @credentials))

      assert_receive {:target_headers, "/redirect-to", first}
      assert_receive {:target_headers, "/ok", second}
      assert List.keymember?(first, "authorization", 0)

      assert second |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 in ~w(authorization cookie proxy-authorization))) ==
               []

      assert {"x-keep", "1"} in second
    end

    test "within an origin keep them", %{env: env, a: a} do
      assert {:ok, {:ok, %{status: 200}}} = fetch(env, request(a, "/redirect-in", headers: @credentials))
      assert_receive {:target_headers, "/ok", headers}
      assert {"authorization", "secret"} in headers
    end
  end
end
