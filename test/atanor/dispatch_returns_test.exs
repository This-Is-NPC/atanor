defmodule Atanor.DispatchReturnsTest do
  @moduledoc "What the dispatcher accepts from the callbacks of a native worker, and what it calls a bad return."
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Atanor.{Dispatch, Env, Response}
  alias Atanor.Test.{Manifests, ScriptedWorker}
  alias AtanorTestkit.Node

  setup_all do
    node =
      Node.start(
        workers: [
          Manifests.probe("scripted", module: ScriptedWorker, cells: %{"notes" => Manifests.notes_migrations()})
        ]
      )

    on_exit(fn -> Node.stop(node) end)
    {:ok, deployment} = Atanor.Registry.deployment(node.name, "scripted")
    {:ok, env: Env.new(node.name, deployment)}
  end

  defp run(env, answer, call, cell \\ nil) do
    ScriptedWorker.script(answer)
    Dispatch.execute(env, cell, call)
  end

  @bad {:error, :bad_return}
  @cell {"notes", "a"}

  test "tcp_init and handle_tcp accept the documented shapes and refuse the others", %{env: env} do
    init = {:tcp_init, %{}}
    data = {:tcp_data, "x", :state}

    for answer <- [{:ok, 1}, {:reply, "hello", 1}, {:reply, ["a", ["b"]], 1}, {:close, ["bye"]}] do
      assert {:ok, ^answer} = run(env, answer, init)
    end

    for answer <- [{:continue, 1}, {:reply, "x", 1}, {:close, "x"}, {:starttls, ["x"], 1}] do
      assert {:ok, ^answer} = run(env, answer, data)
    end

    for answer <- [{:reply, :atom, 1}, {:reply, [1.5], 1}, {:reply, [256], 1}, {:close, 5}, :ok, {:continue}] do
      assert @bad = run(env, answer, init)
    end

    for answer <- [{:reply, {:a}, 1}, {:close, :atom}, {:starttls, 5, 1}, {:ok, 1}, :continue] do
      assert @bad = run(env, answer, data)
    end
  end

  test "the websocket callbacks accept text and binary frames only", %{env: env} do
    open = {:ws_init, %Atanor.Request{}}
    message = {:ws_in, {:text, "x"}, :state}

    assert {:ok, {:ok, 1}} = run(env, {:ok, 1}, open)
    response = %Response{status: 403}
    assert {:ok, {:reject, ^response}} = run(env, {:reject, response}, open)
    assert @bad = run(env, {:reject, %Response{status: 99}}, open)
    assert @bad = run(env, {:reject, 5}, open)

    for answer <- [{:ok, 1}, {:stop, 1}, {:reply, [{:text, "a"}, {:binary, <<0>>}], 1}, {:reply, [], 1}] do
      assert {:ok, ^answer} = run(env, answer, message)
    end

    for answer <- [
          {:reply, [{:ping, "x"}], 1},
          {:reply, [{:text, :atom}], 1},
          {:reply, {:text, "a"}, 1},
          {:reply, ["a"], 1}
        ] do
      assert @bad = run(env, answer, message)
    end
  end

  test "a local websocket call is judged pass or drop, an alarm or a job ok or an error", %{env: env} do
    ScriptedWorker.script(:pass)
    assert {:ok, :pass} = Dispatch.execute_local(env, nil, {:ws_local, "m", :state})
    ScriptedWorker.script(:drop)
    assert {:ok, :drop} = Dispatch.execute_local(env, nil, {:ws_local, "m", :state})
    ScriptedWorker.script(:keep)
    assert @bad = Dispatch.execute_local(env, nil, {:ws_local, "m", :state})

    for call <- [{:alarm, @cell, "payload"}, {:job, %{id: "j", worker: "scripted", operation_id: nil, attempt: 1}}] do
      assert {:ok, :ok} = run(env, :ok, call, @cell)
      assert {:ok, {:error, :why}} = run(env, {:error, :why}, call, @cell)
      assert @bad = run(env, :done, call, @cell)
      assert @bad = run(env, {:ok, 1}, call, @cell)
    end
  end

  test "a routing key names a granted cell and may declare a bounded read", %{env: env} do
    route = fn key, input ->
      ScriptedWorker.script(key)
      Dispatch.route(env, input)
    end

    request = %Atanor.Request{}
    assert :none = route.(:none, request)
    assert {:ok, @cell, :strong} = route.({:cell, "notes", "a"}, request)
    assert {:ok, @cell, :strong} = route.({:cell, "notes", "a", []}, request)
    assert {:ok, @cell, {:bounded, 50}} = route.({:cell, "notes", "a", [consistency: {:bounded, 50}]}, request)

    for key <- [
          {:cell, "other", "a"},
          {:cell, "notes", "a", [consistency: :eventual]},
          {:cell, "notes", "a", [consistency: {:bounded, 0}]},
          {:cell, "notes", "a", [other: 1]}
        ] do
      assert {:error, {:bad_route_key, ^key}} = route.(key, request)
    end

    assert {:error, :invalid_key} = route.({:cell, "notes", "bad key!"}, request)
    assert {:error, {:bad_route_key, 5}} = route.(5, request)
    assert {:error, :crashed} = route.({:raise, "boom"}, request)
    # A connection is bound to its owner for good: it takes no bounded read.
    key = {:cell, "notes", "a", [consistency: {:bounded, 50}]}
    assert {:error, {:bad_route_key, ^key}} = route.(key, {:tcp, %{}})
    assert {:ok, @cell, :strong} = route.({:cell, "notes", "a"}, {:tcp, %{}})
  end
end
