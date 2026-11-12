defmodule Atanor.AdmissionTest do
  @moduledoc """
  The ingress refuses with 503 `overloaded` instead of growing until the container is killed: by the requests
  in flight, and by the working set of the cgroup (design §7.1).
  """
  use ExUnit.Case, async: true

  alias Atanor.Admission
  alias Atanor.Test.{Await, Manifests, RawHTTP, SocketWorker, WSClient}
  alias AtanorTestkit.Node

  @moduletag :tmp_dir

  defp probe, do: Manifests.probe("w", routes: [{"127.0.0.1", "/"}])

  defp chat do
    Manifests.probe("chat",
      module: SocketWorker,
      sockets: true,
      cells: %{"rooms" => []},
      routes: [{"127.0.0.1", "/ws"}]
    )
  end

  defp start(opts) do
    node = Node.start(opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  # Holds in the worker until the test sends it `:go`.
  defp gate(node, test) do
    pid = Base.encode64(:erlang.term_to_binary(test))
    RawHTTP.get(node.port, "/gate", "127.0.0.1", [{"x-test-pid", pid}])
  end

  def report(_event, _measurements, meta, test), do: send(test, {:reject, meta})

  defp echo(node), do: RawHTTP.get(node.port, "/echo", "127.0.0.1")
  defp in_flight(node), do: Admission.stats(node.name).in_flight

  describe "requests in flight" do
    test "a flood runs at most max_in_flight handlers and the rest get 503 overloaded" do
      node = start(workers: [probe()], http: [max_in_flight: 20, retry_after_s: 3])
      test = self()

      for _ <- 1..200, do: spawn_link(fn -> send(test, {:response, gate(node, test)}) end)

      for _ <- 1..180 do
        assert_receive {:response, {503, headers, body}}, 10_000
        assert {"retry-after", "3"} in headers
        assert Jason.decode!(body) == %{"error" => "overloaded", "reason" => "overloaded"}
      end

      handlers =
        for _ <- 1..20 do
          assert_receive {:in_handler, pid}, 5_000
          pid
        end

      refute_receive {:in_handler, _}, 200
      assert in_flight(node) == 20
      assert Admission.stats(node.name).refused == %{memory: 0, in_flight: 180}

      Enum.each(handlers, &send(&1, :go))
      for _ <- 1..20, do: assert_receive({:response, {200, _, _}}, 5_000)

      Await.until(fn -> in_flight(node) == 0 end)
      assert {200, _, _} = echo(node)
    end

    test "a refused request is reported with its reason" do
      node = start(workers: [probe()], http: [max_in_flight: 1])
      ref = make_ref()

      :telemetry.attach(
        {__MODULE__, ref},
        [:atanor, :http, :reject],
        &__MODULE__.report/4,
        self()
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      test = self()
      task = Task.async(fn -> gate(node, test) end)
      assert_receive {:in_handler, handler}, 5_000

      assert {503, _, _} = echo(node)
      assert_receive {:reject, %{reason: :in_flight, status: 503, worker: nil}}

      send(handler, :go)
      assert {200, _, _} = Task.await(task)
    end

    test "a handler that is killed gives its slot back" do
      node = start(workers: [probe()], http: [max_in_flight: 2])
      listener = Atanor.Registry.http_listener(node.name)
      test = self()

      for _ <- 1..2, do: spawn_link(fn -> send(test, {:response, gate(node, test)}) end)
      for _ <- 1..2, do: assert_receive({:in_handler, _}, 5_000)
      assert in_flight(node) == 2
      assert {503, _, _} = echo(node)

      {:ok, connections} = ThousandIsland.connection_pids(listener)
      Enum.each(connections, &Process.exit(&1, :kill))

      Await.until(fn -> in_flight(node) == 0 end)
      assert {200, _, _} = echo(node)
    end

    test "a client that goes away gives its slot back when the worker answers" do
      node = start(workers: [probe()], http: [max_in_flight: 5])
      pid = Base.encode64(:erlang.term_to_binary(self()))

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", node.port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /gate HTTP/1.1\r\nhost: 127.0.0.1\r\nx-test-pid: #{pid}\r\n\r\n")
      assert_receive {:in_handler, handler}, 5_000
      :gen_tcp.close(socket)
      send(handler, :go)

      Await.until(fn -> in_flight(node) == 0 end)
    end
  end

  describe "memory" do
    setup %{tmp_dir: dir} do
      paths = %{current_path: Path.join(dir, "memory.current"), stat_path: Path.join(dir, "memory.stat")}
      write(paths, 100_000)

      node =
        start(
          workers: [probe(), chat()],
          memory: [limit_bytes: 1_000_000, refuse_fraction: 0.85, sample_ms: 20] ++ Map.to_list(paths)
        )

      %{node: node, paths: paths}
    end

    defp write(paths, current, inactive_file \\ 0) do
      File.write!(paths.current_path, "#{current}\n")
      File.write!(paths.stat_path, "anon 1\ninactive_file #{inactive_file}\nactive_file 2\n")
    end

    defp refusing?(node, value), do: Await.until(fn -> Admission.stats(node.name).refusing == value end)

    test "refuses above the threshold, keeps open sockets, and resumes below the resume mark", %{
      node: node,
      paths: paths
    } do
      assert {200, _, _} = echo(node)
      assert {:ok, client} = WSClient.connect(node.port, "/ws")
      on_exit(fn -> WSClient.close(client) end)

      write(paths, 900_000)
      refusing?(node, true)

      assert {503, headers, body} = echo(node)
      assert {"retry-after", "1"} in headers
      assert Jason.decode!(body) == %{"error" => "overloaded", "reason" => "overloaded"}
      assert {:error, 503, _} = WSClient.connect(node.port, "/ws")
      assert %{working_set_bytes: 900_000, refused: %{memory: 2}} = Admission.stats(node.name)

      client = WSClient.send_frame(client, {:text, "echo hello"})
      assert {{:text, "hello"}, _} = WSClient.recv(client, 5_000)

      # Between the marks the gate keeps refusing.
      write(paths, 820_000)
      Await.until(fn -> Admission.stats(node.name).working_set_bytes == 820_000 end)
      assert Admission.stats(node.name).refusing

      write(paths, 700_000)
      refusing?(node, false)
      assert {200, _, _} = echo(node)
      assert {:ok, _} = WSClient.connect(node.port, "/ws")
    end

    test "reclaimable page cache does not count", %{node: node, paths: paths} do
      write(paths, 950_000, 400_000)
      Await.until(fn -> Admission.stats(node.name).working_set_bytes == 550_000 end)
      refute Admission.stats(node.name).refusing
      assert {200, _, _} = echo(node)
    end

    test "a stale sample is ignored: the gate fails open, and closes again with a fresh one", %{
      node: node,
      paths: paths
    } do
      write(paths, 900_000)
      refusing?(node, true)

      sampler = sampler(node)
      :sys.suspend(sampler)
      on_exit(fn -> if Process.alive?(sampler), do: :sys.resume(sampler) end)

      # Ten sample periods without a sample.
      Await.until(fn -> match?({200, _, _}, echo(node)) end)
      refute Admission.stats(node.name).refusing

      :sys.resume(sampler)
      refusing?(node, true)
    end

    test "a sample that cannot be read is skipped", %{node: node, paths: paths} do
      write(paths, 900_000)
      refusing?(node, true)

      File.rm!(paths.current_path)
      Await.until(fn -> match?({200, _, _}, echo(node)) end)
    end
  end

  test "the memory gate is off without a limit, or with refuse_fraction nil", %{tmp_dir: dir} do
    current = Path.join(dir, "memory.current")
    File.write!(current, "999999999\n")

    for memory <- [[cgroup_path: Path.join(dir, "none")], [limit_bytes: 1_000, refuse_fraction: nil]] do
      node = start(workers: [probe()], memory: [current_path: current, sample_ms: 20] ++ memory)
      refute Admission.stats(node.name).refusing
      assert Admission.stats(node.name).working_set_bytes == nil
      assert {200, _, _} = echo(node)
    end
  end

  defp sampler(node) do
    {_, pid, _, _} =
      node.name
      |> Module.concat(Supervisor)
      |> Supervisor.which_children()
      |> List.keyfind(Atanor.Admission, 0)

    pid
  end
end
