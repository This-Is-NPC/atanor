defmodule Atanor.DashboardTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Phoenix.LiveViewTest
  import Atanor.Test.Await

  alias Atanor.Dashboard.{Auth, Metrics}
  alias Atanor.Test.{AlarmWorker, LineWorker, Manifests, WSClient}
  alias AtanorTestkit.Node
  alias Phoenix.LiveDashboard.TelemetryListener

  @endpoint Atanor.Dashboard.Endpoint
  @token "dash-token"

  defp start(workers \\ [], opts \\ []) do
    node = Node.start([workers: workers, dashboard: [token: @token, port: 0]] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp counter, do: Manifests.counter("counter", routes: [{"127.0.0.1", "/c"}])

  defp clock do
    Manifests.probe("clock",
      module: AlarmWorker,
      alarms: true,
      cells: %{"clock" => AlarmWorker.migrations()},
      routes: [{"127.0.0.1", "/set"}]
    )
  end

  # A browser that presented the token once.
  defp signed_in do
    conn = get(build_conn(), "/workers?token=#{@token}")
    assert redirected_to(conn, 303) == "/workers"
    recycle(conn)
  end

  defp page(path) do
    {:ok, view, html} = live(signed_in(), path)
    {view, html}
  end

  defp touch(node, cell), do: Req.post!("#{node.url}/c/#{cell}", body: "1", retry: false)

  describe "options" do
    test "the dashboard needs a token, like the admin API" do
      for dashboard <- [[], [port: 0], [token: ""], [token: :atom], [token: "t", extra: 1], [token: "t", port: -1]] do
        assert_raise ArgumentError, fn ->
          Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, dashboard: dashboard)
        end
      end
    end

    test "defaults to loopback and keeps the token out of inspect output" do
      config = Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, dashboard: [token: @token])
      assert %{ip: {127, 0, 0, 1}, port: 4002} = config.dashboard
      refute inspect(config) =~ @token
    end

    test "the token and the key base stay out of the application environment" do
      start()
      env = Application.get_all_env(:atanor)
      refute inspect(env) =~ @token
      refute Keyword.has_key?(Application.get_env(:atanor, Atanor.Dashboard.Endpoint, []), :secret_key_base)
      assert html_response(get(signed_in(), "/workers"), 200) =~ "Workers"
    end

    test "without the option nothing listens" do
      node = Node.start()
      on_exit(fn -> Node.stop(node) end)
      assert Process.whereis(Atanor.Dashboard.Endpoint) == nil
    end

    test "names the dependencies to add" do
      assert Atanor.Dashboard.dependencies() =~ "phoenix_live_dashboard"
    end
  end

  describe "authentication" do
    test "a request without the right token is refused, for pages and assets" do
      start()

      for path <- [
            "/",
            "/workers",
            "/cells",
            "/metrics",
            "/css-abc",
            "/workers?token=wrong",
            "/workers?token="
          ] do
        conn = get(build_conn(), path)
        assert response(conn, 401) =~ "?token="
        assert get_resp_header(conn, "set-cookie") == []
      end

      assert response(post(build_conn(), "/workers?token=#{@token}"), 401)
    end

    test "the token opens a session and leaves the URL" do
      start()
      conn = get(build_conn(), "/cells?limit=5&token=#{@token}")
      assert redirected_to(conn, 303) == "/cells?limit=5"
      assert [_] = get_resp_header(conn, "set-cookie")
      assert html_response(get(recycle(conn), "/workers"), 200) =~ "Workers"
    end

    test "a forged cookie is refused" do
      start()
      conn = build_conn() |> put_req_header("cookie", "_atanor_dashboard=forged") |> get("/workers")
      assert response(conn, 401)
    end

    test "the live socket accepts only a signed-in browser from its own origin" do
      start()
      port = Atanor.Dashboard.port()
      origin = {"origin", "http://127.0.0.1:#{port}"}
      url = "/live/websocket?vsn=2.0.0"

      # What the browser sends: the cookie and the CSRF token of the page.
      conn = get(signed_in(), "/workers")
      [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(conn, 200))
      cookie = {"cookie", "_atanor_dashboard=" <> conn.resp_cookies["_atanor_dashboard"].value}
      signed_url = url <> "&_csrf_token=" <> URI.encode_www_form(csrf)

      assert {:error, 403, _} = WSClient.connect(port, signed_url, [origin])
      assert {:error, 403, _} = WSClient.connect(port, signed_url, [origin, {"cookie", "_atanor_dashboard=forged"}])
      assert {:error, 403, _} = WSClient.connect(port, signed_url, [cookie, {"origin", "http://evil.example"}])
      assert {:error, 403, _} = WSClient.connect(port, url, [origin, cookie])
      assert {:ok, _} = WSClient.connect(port, signed_url, [origin, cookie])

      assert :error = Atanor.Dashboard.Socket.connect(%{}, %Phoenix.Socket{}, %{session: %{}})
      assert :error = Atanor.Dashboard.Socket.connect(%{}, %Phoenix.Socket{}, %{})
    end

    test "a LiveView does not mount without the session" do
      socket = %Phoenix.LiveView.Socket{}
      assert {:halt, _} = Auth.on_mount(:default, %{}, %{}, socket)
      assert {:cont, ^socket} = Auth.on_mount(:default, %{}, %{"atanor_dashboard" => true}, socket)
    end
  end

  describe "pages" do
    test "workers: the heads in the store and the manifest a node serves" do
      node = start([counter()])
      {:ok, active} = Atanor.Registry.deployment(node.name, "counter")

      {view, html} = page("/workers")
      assert html =~ "counter"
      assert html =~ String.slice(active.id, 0, 12)

      html = view |> element("a", "counter") |> render_click()
      assert html =~ "Manifest served by"
      assert html =~ "&quot;kind&quot;: &quot;native&quot;"
    end

    test "deployments: what every node applied, with the reason a head failed" do
      node = start([counter()], listeners: %{"smtp" => 0})
      bad = Manifests.probe("bad", module: LineWorker, tcp: ["nolistener"])
      assert %{error: {:listener_not_configured, "nolistener"}} = Manifests.forge_head(node, bad)

      {_view, html} = page("/deployments")
      assert html =~ Atom.to_string(node())
      assert html =~ "serving"
      assert html =~ "failed"
      assert html =~ "listener_not_configured"
    end

    test "routes: HTTP routes and TCP listeners of the node" do
      node = start([counter(), Manifests.probe("lines", module: LineWorker, tcp: ["smtp"])], listeners: %{"smtp" => 0})
      {:ok, smtp} = Atanor.TCP.port(node.name, "smtp")

      {_view, html} = page("/routes")
      assert html =~ "127.0.0.1"
      assert html =~ "/c"
      assert html =~ "smtp"
      assert html =~ Integer.to_string(smtp)
      assert html =~ "lines"
    end

    test "cells: live cells of the node, a page at a time" do
      node = start([counter()])
      for cell <- ~w(a b c), do: touch(node, cell)

      {view, html} = page("/cells?limit=2")
      assert html =~ "Live cells of #{node()} (3)"
      assert html =~ "log.a" and html =~ "log.b"
      refute html =~ "log.c"
      refute html =~ "First page"

      html = view |> element("a", "Next page") |> render_click()
      assert html =~ "log.c"
      refute html =~ "log.a"
      refute html =~ "Next page"
      assert html =~ "First page"

      html = view |> element("a", "First page") |> render_click()
      assert html =~ "log.a"
    end

    test "cells: the automatic refresh shows new cells" do
      node = start([counter()])
      touch(node, "first")
      {view, html} = page("/cells")
      assert html =~ "log.first"
      refute html =~ "log.second"

      touch(node, "second")
      send(view.pid, :refresh)
      assert until(fn -> render(view) =~ "log.second" end)
    end

    test "alarms: the pending alarms of the store index, a page at a time" do
      node = start([clock()])
      at = System.os_time(:millisecond) + 3_600_000

      for key <- ~w(a b c) do
        query = URI.encode_query(key: key, at: at, payload: "x")
        assert Req.get!("#{node.url}/set?#{query}", retry: false).body == ":ok"
      end

      {view, html} = page("/alarms?limit=2")
      assert html =~ "clock"
      assert html =~ Calendar.strftime(DateTime.from_unix!(at, :millisecond), "%Y-%m-%d %H:%M")
      assert length(Regex.scan(~r/clock \/ [abc]/, html)) == 2

      html = view |> element("a", "Next page") |> render_click()
      assert length(Regex.scan(~r/clock \/ [abc]/, html)) == 1
    end

    test "jobs: operations, slots and one cell's jobs" do
      node = start([Manifests.jobs("jobs")], alarms: [tick_ms: 20])
      {:ok, _} = Atanor.Cell.query(node.name, {"jobs", "a"}, "SELECT 1")
      assert {:ok, _} = Atanor.Jobs.enqueue_direct(node.name, "jobs", {"jobs", "a"}, %{kind: "dash", payload: "x"})

      assert until(fn ->
               match?(
                 {:ok, %{rows: [["done"]]}},
                 Atanor.Cell.query(node.name, {"jobs", "a"}, "SELECT state FROM _atanor_jobs")
               )
             end)

      {_view, html} = page("/jobs")
      assert html =~ "Bulk operations"
      assert html =~ "Job slots on this node"
      assert html =~ "Dead letters"

      {_view, html} = page("/jobs?cell=jobs.a")
      assert html =~ "dash"
      assert html =~ "done"
      assert html =~ "jobs"
    end

    test "jobs: an operation, a dead letter, a cell that is not an address and a store that fails" do
      node = start([Manifests.jobs("jobs")], alarms: [tick_ms: 20])
      {:ok, _} = Atanor.Cell.query(node.name, {"jobs", "a"}, "SELECT 1")

      assert {:ok, _} =
               Atanor.Jobs.enqueue_direct(node.name, "jobs", {"jobs", "a"}, %{
                 kind: "fail",
                 payload: "fail",
                 max_attempts: 1
               })

      assert {:ok, %{"id" => operation}} =
               Atanor.Sweeps.start(node.name, %{
                 "selector" => %{"kind" => "namespace", "namespace" => "jobs"},
                 "action" => %{"worker" => "jobs", "kind" => "sweep", "payload_base64" => Base.encode64("x")},
                 "rate_per_s" => 1,
                 "concurrency" => 1,
                 "page_size" => 1
               })

      assert until(fn -> match?({:ok, %{dead: [_]}}, Atanor.Overview.dead_letters(node.name, nil, 10)) end)

      {_view, html} = page("/jobs")
      assert html =~ String.slice(operation, 0, 12)
      assert html =~ "namespace"
      assert html =~ "jobs.a"
      assert html =~ "fail"

      {_view, html} = page("/jobs?cell=nodot")
      assert html =~ "The cell is not namespace.key"

      {_module, config} = node.store
      AlambiqueTestkit.MemoryStore.inject(config, kind: :error, ops: [:list], key: ~r{operations/}, reason: :down)
      {_view, html} = page("/jobs")
      assert html =~ "The store did not answer: :down"
    end

    test "no page has an action" do
      node = start([counter(), clock()])
      touch(node, "a")

      for path <- ~w(/workers /deployments /routes /cells /alarms) do
        {_view, html} = page(path)
        refute html =~ ~r/<button|phx-click="(activate|rollback|kill)/i, path
      end
    end
  end

  describe "metrics" do
    test "the page charts the events of each group" do
      start()
      {:error, {:live_redirect, %{to: to}}} = live(signed_in(), "/metrics")
      assert to =~ "nav="
      {:ok, _view, html} = live(signed_in(), "/metrics?nav=requests")
      assert html =~ "atanor.call.duration"
    end

    test "every native measurement the charts name is polled and emitted" do
      start()
      native = Enum.filter(Metrics.metrics(), &(&1.reporter_options[:nav] in ["wasm_native", "alambique_native"]))
      assert native != []
      id = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach_many(
        id,
        [[:atanor, :wasm, :native, :stats], [:alambique, :native, :stats]],
        fn event, measurements, _meta, _ -> send(parent, {:stats, event, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      # The poller emits both when the dashboard starts.
      for event <- [[:atanor, :wasm, :native, :stats], [:alambique, :native, :stats]] do
        assert_receive {:stats, ^event, measurements}, 5_000

        for metric <- native, metric.event_name == event do
          assert %{} = TelemetryListener.extract_datapoint_for_metric(metric, measurements, %{}), inspect(metric.name)
        end
      end
    end

    test "calls, errors, alarms and connections produce datapoints" do
      call = %{worker: "w", kind: :http, result: :ok, status: 200}
      error = %{worker: "w", kind: :http, result: :error, reason: {:limit, :cpu}}
      metrics = Map.new(Metrics.metrics(), &{{&1.name, &1.__struct__}, &1})

      point = fn name, type, measurements, meta ->
        TelemetryListener.extract_datapoint_for_metric(Map.fetch!(metrics, {name, type}), measurements, meta)
      end

      assert %{label: "w http ok"} = point.([:atanor, :call, :count], Telemetry.Metrics.Counter, %{duration: 1}, call)

      assert %{measurement: ms} =
               point.([:atanor, :call, :duration], Telemetry.Metrics.Summary, %{duration: 1_000_000}, call)

      assert is_number(ms)
      assert %{label: label} = point.([:atanor, :call, :errors], Telemetry.Metrics.Counter, %{duration: 1}, error)
      assert label =~ "limit"
      assert point.([:atanor, :call, :errors], Telemetry.Metrics.Counter, %{duration: 1}, call) == nil

      assert point.([:atanor, :http, :reject, :count], Telemetry.Metrics.Counter, %{count: 1}, %{
               reason: :no_route,
               worker: nil
             })
    end

    test "the evictions for awake max_bytes produce datapoints" do
      metrics = Map.new(Metrics.metrics(), &{{&1.name, &1.__struct__}, &1})
      event = [:alambique, :admission, :evict]
      meta = %{cell: "notes.a", max_bytes: 1_000}

      assert %{} =
               TelemetryListener.extract_datapoint_for_metric(
                 metrics[{event ++ [:count], Telemetry.Metrics.Counter}],
                 %{bytes: 900},
                 meta
               )

      assert %{measurement: 900} =
               TelemetryListener.extract_datapoint_for_metric(
                 metrics[{event ++ [:bytes], Telemetry.Metrics.LastValue}],
                 %{bytes: 900},
                 meta
               )
    end

    test "rejected feed objects produce a datapoint per reason" do
      metrics = Map.new(Metrics.metrics(), &{{&1.name, &1.__struct__}, &1})
      metric = metrics[{[:atanor, :feed, :rejected, :count], Telemetry.Metrics.Counter}]
      meta = %{instance: :x, namespace: nil, key: "k", reason: {:unsupported_format, 9}}

      assert %{label: "{:unsupported_format, 9}", measurement: 1} =
               TelemetryListener.extract_datapoint_for_metric(metric, %{count: 1}, meta)
    end
  end
end
