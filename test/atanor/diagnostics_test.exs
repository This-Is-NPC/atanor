defmodule Atanor.DiagnosticsTest do
  use ExUnit.Case, async: false

  import Atanor.Test.Await

  alias AlambiqueTestkit.MemoryStore
  alias Atanor.Diagnostics
  alias Atanor.Diagnostics.Breadcrumb
  alias Atanor.Registry
  alias AtanorTestkit.Node

  @token "diagnostics-token"

  defp store do
    {:ok, pid} = MemoryStore.start_link()
    {MemoryStore, MemoryStore.config(pid)}
  end

  defp busy_file(dir, body) do
    units = Path.join(dir, "diagnostics/units")
    File.mkdir_p!(units)
    path = Path.join(units, "test-#{System.unique_integer([:positive])}")
    File.write!(path, <<1>> <> Jason.encode!(body))
    path
  end

  test "a busy file from a previous boot becomes a report after the next start" do
    dir = Path.join(System.tmp_dir!(), "atanor-diagnostics-#{System.pid()}-#{System.unique_integer([:positive])}")
    source = store()

    node = Node.start(data_dir: dir, store: source, release: [id: "image-sha"])
    Node.stop(node)

    path =
      busy_file(dir, %{
        "unit_id" => "u1",
        "kind" => "job",
        "worker" => "jobs",
        "deployment" => "package-sha",
        "cell" => "jobs.alice",
        "job_id" => "job-1",
        "operation_id" => "op-1",
        "release" => "image-sha",
        "started_at_ms" => 1
      })

    node =
      Node.start(
        data_dir: dir,
        store: source,
        release: [id: "image-sha"],
        admin: [token: @token, port: 0],
        diagnostics: [settle_ms: 2_000]
      )

    on_exit(fn -> Node.stop(node) end)

    record_crash(node.name, "jobs.alice")

    report = wait_report(node.name)
    assert report["node"] == Atom.to_string(node())
    assert report["release"]["id"] == "image-sha"
    assert [unit] = report["units"]
    assert unit["kind"] == "job"
    assert unit["worker"] == "jobs"
    assert unit["cell"] == "jobs.alice"
    assert unit["job_id"] == "job-1"
    assert unit["operation_id"] == "op-1"
    assert unit["release"] == "image-sha"

    assert %{"crashes" => %{"total" => 1, "recent" => [%{"kinds" => ["cell"]}]}, "frozen" => false} =
             unit["alambique"]

    refute File.exists?(path)

    body = admin_get(node, "/crashes")
    assert %{"crashes" => [^report], "next" => nil} = body

    id = report["id"]
    assert %{"id" => ^id} = admin_get(node, "/crashes/#{report["node"]}/#{id}")
    assert admin_get(node, "/crashes/#{report["node"]}/missing").status == 404

    response =
      Req.post!(
        "http://127.0.0.1:#{Atanor.admin_port(node.name)}/cells/jobs/alice/unfreeze",
        headers: [{"authorization", "Bearer " <> @token}],
        retry: false
      )

    assert response.status == 200
    assert %{"cell" => "jobs.alice", "frozen" => false} = response.body
  end

  defp previous_boot(seed \\ fn _node -> :ok end) do
    dir = Path.join(System.tmp_dir!(), "atanor-diagnostics-#{System.pid()}-#{System.unique_integer([:positive])}")
    source = store()
    first = Node.start(data_dir: dir, store: source)
    seed.(first)
    Node.stop(first)
    File.mkdir_p!(Path.join(dir, "diagnostics/units"))
    {dir, source}
  end

  defp restart(dir, source, diagnostics) do
    node = Node.start(data_dir: dir, store: source, diagnostics: [settle_ms: 0] ++ diagnostics)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  test "a damaged marker is reported with what is wrong, and a clean one is dropped" do
    {dir, source} = previous_boot()
    units = Path.join(dir, "diagnostics/units")
    File.mkdir_p!(units)
    File.write!(Path.join(units, "a-wrong-byte"), <<2, "{}">>)
    File.write!(Path.join(units, "b-empty"), "")
    File.write!(Path.join(units, "c-no-body"), <<1>>)
    File.write!(Path.join(units, "d-not-json"), <<1, "[1, 2">>)
    File.write!(Path.join(units, "e-idle"), <<0, "{}">>)

    node = restart(dir, source, [])
    report = wait_report(node.name)

    errors = for %{"error" => error, "path" => path} <- report["units"], into: %{}, do: {Path.basename(path), error}

    assert errors == %{
             "a-wrong-byte" => "{:invalid_busy_byte, <<2>>}",
             "b-empty" => ":empty_file",
             "c-no-body" => ":empty_body",
             "d-not-json" => ":invalid_body"
           }

    assert File.ls!(units) == []
  end

  test "a report the store refuses is kept on disk and stored by a later retry" do
    {dir, source} = previous_boot()
    File.write!(Path.join([dir, "diagnostics/units", "busy"]), <<1, ~s({"kind":"job"})>>)
    {_module, config} = source
    MemoryStore.inject(config, kind: :error, ops: [:put], key: ~r{crashes/}, reason: :down, times: 2)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        node = restart(dir, source, pending_retry_ms: 10)
        assert %{"units" => [%{"kind" => "job"}]} = wait_report(node.name)
      end)

    assert log =~ "could not store crash report"
    assert File.ls!(Path.join(dir, "diagnostics/pending")) == []
  end

  test "a report older than the retention is removed and a recent one kept" do
    now = System.os_time(:millisecond)

    {dir, source} =
      previous_boot(fn first ->
        store = Atanor.Store.handle(first.name)

        put = fn id, report ->
          {:ok, _} = Atanor.Store.put(store, "crashes/n/#{id}", Jason.encode!(report), :if_none_match)
        end

        put.("old", %{"id" => "old", "detected_at_ms" => now - 10_000_000})
        put.("recent", %{"id" => "recent", "detected_at_ms" => now})
      end)

    node = restart(dir, source, retention_ms: 1_000_000, cleanup_ms: 10)

    assert until(fn -> match?({:error, :not_found}, Diagnostics.get(node.name, "n", "old")) end)
    assert {:ok, %{"id" => "recent"}} = Diagnostics.get(node.name, "n", "recent")
  end

  test "the tracker removes a marker when its process ends, and a clean unit leaves none" do
    node = Node.start([])
    on_exit(fn -> Node.stop(node) end)

    parent = self()

    pid =
      spawn(fn ->
        breadcrumb = Breadcrumb.open(node.name, %{kind: "job", worker: "w", cell: "jobs.a"})
        Breadcrumb.hold(breadcrumb)
        send(parent, {:path, breadcrumb.path})
        Process.sleep(:infinity)
      end)

    path = receive do: ({:path, path} -> path)
    assert File.exists?(path)
    assert <<1, _::binary>> = File.read!(path)

    Process.exit(pid, :kill)

    wait_until(fn -> not File.exists?(path) end)
    assert {:ok, %{crashes: []}} = Diagnostics.list(node.name)
  end

  test "a node that stops removes the markers of the units it still tracks" do
    dir = Path.join(System.tmp_dir!(), "atanor-diagnostics-#{System.pid()}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    node = Node.start(data_dir: dir, store: store())
    on_exit(fn -> Node.stop(node) end)
    parent = self()

    holder =
      spawn(fn ->
        breadcrumb = Breadcrumb.open(node.name, %{kind: "job", worker: "w", cell: "jobs.a"})
        Breadcrumb.hold(breadcrumb)
        send(parent, {:path, breadcrumb.path})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    path = receive do: ({:path, path} -> path)
    assert File.exists?(path)

    # Only the supervisor stops: `Node.stop/1` would also remove the data directory.
    Supervisor.stop(node.pid)
    refute File.exists?(path)
  end

  test "a clean unit removes its own marker" do
    node = Node.start([])
    on_exit(fn -> Node.stop(node) end)

    :ok =
      Breadcrumb.wrap(node.name, %{kind: "alarm", worker: "w", cell: "clock.k"}, fn ->
        :ok
      end)

    assert {:ok, %{crashes: []}} = Diagnostics.list(node.name)
  end

  test "a unit runs without a marker when breadcrumbs are off" do
    node = Node.start(diagnostics: [breadcrumbs: :off])
    on_exit(fn -> Node.stop(node) end)
    meta = %{kind: "alarm", worker: "w", cell: "clock.k"}

    assert Breadcrumb.open(node.name, meta) == nil
    assert :ok = Breadcrumb.hold(nil)
    assert :ok = Breadcrumb.release(nil)
    assert :ok = Breadcrumb.close(nil)
    assert :result = Breadcrumb.wrap(node.name, meta, fn -> :result end)
    assert File.ls(Path.join(Registry.config(node.name).diagnostics.dir, "units")) in [{:ok, []}, {:error, :enoent}]
  end

  test "a unit still runs when its marker cannot be created" do
    blocker = Path.join(System.tmp_dir!(), "atanor-blocker-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.write!(blocker, "not a directory")
    on_exit(fn -> File.rm(blocker) end)

    node = Node.start(diagnostics: [dir: Path.join(blocker, "diagnostics")])
    on_exit(fn -> Node.stop(node) end)
    meta = %{kind: "job", worker: "w", cell: "jobs.a"}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Breadcrumb.open(node.name, meta) == nil
        assert :ran = Breadcrumb.wrap(node.name, meta, fn -> :ran end)
      end)

    assert log =~ "could not create a crash breadcrumb"
  end

  test "invalid diagnostics options raise and defaults are documented values" do
    config = Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil})
    assert config.diagnostics.enabled
    assert config.diagnostics.breadcrumbs == :durable
    assert config.diagnostics.dir == "/tmp/x/diagnostics"
    assert config.diagnostics.max_files == 10_000

    for diagnostics <- [
          [breadcrumbs: :sometimes],
          [enabled: :yes],
          [max_files: 0],
          [dir: ""],
          [unknown: 1]
        ] do
      assert_raise ArgumentError, fn ->
        Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, diagnostics: diagnostics)
      end
    end
  end

  defp wait_report(name, timeout \\ 5_000) do
    until(
      fn ->
        case Diagnostics.list(name) do
          {:ok, %{crashes: [report | _]}} -> report
          _ -> nil
        end
      end,
      timeout
    )
  end

  defp record_crash(name, cell) do
    config = Atanor.Registry.config(name)
    opts = config.alambique_opts
    ctx = Alambique.Replication.ctx(store: opts[:store], prefix: opts[:prefix], node: Atom.to_string(node()))
    {:ok, _} = Alambique.Quarantine.record(ctx, cell, %{threshold: 3, window_ms: 3_600_000}, ["cell"])
    :ok
  end

  defp wait_until(fun), do: until(fun, 5_000)

  defp admin_get(node, path) do
    response =
      Req.request!(
        method: :get,
        url: "http://127.0.0.1:#{Atanor.admin_port(node.name)}" <> path,
        headers: [{"authorization", "Bearer " <> @token}],
        retry: false,
        decode_body: false
      )

    if response.status == 200, do: Jason.decode!(response.body), else: response
  end
end
