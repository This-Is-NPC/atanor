defmodule Atanor.Jobs.SlotsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Jobs.Slots
  alias Atanor.Test.Await

  @workers ["w1", "w2", "w3"]
  @holders 0..3

  defp op do
    frequency([
      {8, tuple({constant(:checkout), member_of(@holders), member_of(@workers)})},
      {2, tuple({constant(:release), member_of(@holders), member_of(@workers)})},
      {4, tuple({constant(:transfer), member_of(@holders), member_of(@workers), member_of(@holders)})},
      {2, tuple({constant(:kill), member_of(@holders)})},
      {1, constant(:close)}
    ])
  end

  # A holder runs the calls of the slots API, which key their slot on the calling process.
  defp spawn_holder do
    spawn(fn -> holder_loop() end)
  end

  defp holder_loop do
    receive do
      {:run, from, fun} ->
        send(from, {:result, self(), fun.()})
        holder_loop()
    end
  end

  defp call(pid, fun) do
    send(pid, {:run, self(), fun})
    receive do: ({:result, ^pid, result} -> result)
  end

  # Slots granted and returned against a model: the node and worker limits hold, a dead holder gives its slots back,
  # and a closed node grants nothing.
  property "checkout, release, transfer, kill and close follow a model with the limits" do
    check all(
            total <- integer(1..4),
            per_worker <- integer(1..3),
            ops <- list_of(op(), max_length: 40),
            max_runs: 60
          ) do
      instance = :"slots_#{System.unique_integer([:positive])}"
      config = %{name: instance, jobs: %{concurrency: total, worker_concurrency: per_worker}}
      pid = start_supervised!(Supervisor.child_spec(Slots.child_spec(config), id: instance))
      holders = Map.new(@holders, &{&1, spawn_holder()})

      model =
        Enum.reduce(ops, %{holds: [], closed: false, alive: MapSet.new(@holders)}, fn op, model ->
          step(op, model, instance, holders, total, per_worker)
        end)

      expected = Enum.frequencies_by(model.holds, &elem(&1, 1))
      Await.until(fn -> Slots.stats(instance).workers == expected end)
      stats = Slots.stats(instance)
      assert stats.running == length(model.holds)
      assert stats.running <= total
      assert Enum.all?(stats.workers, fn {_, n} -> n <= per_worker end)
      assert Slots.closed?(instance) == model.closed
      Enum.each(holders, fn {_, h} -> Process.exit(h, :kill) end)
      stop_supervised!(instance)
      refute Process.alive?(pid)
    end
  end

  defp step({:checkout, h, w}, model, instance, holders, total, per_worker) do
    if h in model.alive do
      used = Enum.count(model.holds, &(elem(&1, 1) == w))
      room? = not model.closed and length(model.holds) < total and used < per_worker
      assert call(holders[h], fn -> Slots.checkout(instance, w) end) == if(room?, do: :ok, else: :none)
      if room?, do: %{model | holds: [{h, w} | model.holds]}, else: model
    else
      model
    end
  end

  defp step({:release, h, w}, model, instance, holders, _, _) do
    if h in model.alive do
      call(holders[h], fn -> Slots.release(instance, w) end)
      %{model | holds: List.delete(model.holds, {h, w})}
    else
      model
    end
  end

  defp step({:transfer, from, w, to}, model, instance, holders, _, _) do
    if from in model.alive and to in model.alive do
      call(holders[from], fn -> Slots.transfer(instance, w, holders[to]) end)

      if {from, w} in model.holds,
        do: %{model | holds: [{to, w} | List.delete(model.holds, {from, w})]},
        else: model
    else
      model
    end
  end

  defp step({:kill, h}, model, instance, holders, _, _) do
    Process.exit(holders[h], :kill)
    holds = Enum.reject(model.holds, &(elem(&1, 0) == h))
    # The slots are given back on the exit signal; wait for it before the next call.
    Await.until(fn -> Slots.stats(instance).running == length(holds) end)
    %{model | holds: holds, alive: MapSet.delete(model.alive, h)}
  end

  defp step(:close, model, instance, _, _, _) do
    Slots.close(instance)
    %{model | closed: true}
  end
end
