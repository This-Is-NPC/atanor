defmodule Atanor.Cluster.TakeoverTest do
  @moduledoc """
  The early takeover of a lost node's cells (design §8.10 to §8.12): the cells
  serve again in about the detection time and not the lease time, a node that
  was only slow is fenced, concurrent takeovers have one winner, and a node
  that stops gracefully hands its cells off without client errors.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Lease, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 180_000

  # A lease far longer than detection: serving again earlier proves the takeover.
  @ttl_ms 20_000
  @detector [
    interval_ms: 200,
    phi_threshold: 8,
    min_std_ms: 50,
    acceptable_pause_ms: 600,
    indirect: [k: 2, timeout_ms: 500]
  ]

  defp start(opts \\ []) do
    cluster =
      start_cluster(
        names: [:n1, :n2, :n3],
        ttl_ms: @ttl_ms,
        skew_margin_ms: 400,
        atanor: [detector: @detector] ++ opts,
        workers: [Manifests.counter("counter")]
      )

    for via <- Cluster.names(cluster), do: Await.until(fn -> map_size(views(cluster, via)) == 2 end)

    # Every node has applied the worker once it can serve a write.
    for via <- Cluster.names(cluster),
        do: Await.until(fn -> match?({200, _}, write(cluster, via, "warm-#{via}", 0)) end)

    cluster
  end

  # 503 `unavailable` means the call did not run, so a client repeats it (design §8.4).
  defp write_again(cluster, via, cell, n, tries \\ 5) do
    case write(cluster, via, cell, n) do
      {503, _} when tries > 1 -> write_again(cluster, via, cell, n, tries - 1)
      other -> other
    end
  end

  defp lease(cluster, via, cell) do
    {:ok, {:ok, lease}} = Cluster.call(cluster, via, Lease, :read, [Cluster.instance(cluster), "log." <> cell])
    lease
  end

  defp rows(cluster, via, cell) do
    {:ok, resp} = request(cluster, via, :get, "/c/#{cell}")
    Jason.decode!(resp.body)["rows"]
  end

  defp take_overs(cluster, observer, cell, result \\ :ok) do
    events(cluster, [:atanor, :cell, :take_over], &(&1.cell == "log." <> cell and &1.result == result))
    |> Enum.filter(&(&1.node == observer))
  end

  defp inject(cluster, :sigstop, victim, _survivor), do: Cluster.pause(cluster, victim)
  defp inject(cluster, :sigkill, victim, _survivor), do: Cluster.kill_process(cluster, victim)

  defp inject(cluster, :hint, victim, survivor) do
    Cluster.pause(cluster, victim)
    url = Cluster.admin_url(cluster, survivor) <> "/nodes/#{Cluster.node(cluster, victim)}/gone"
    Req.post!(url, headers: [{"authorization", "Bearer " <> Cluster.admin_token()}], retry: false)
  end

  for fault <- [:sigstop, :sigkill, :hint] do
    test "#{fault}: the cell is served again in the detection time, not the lease time" do
      cluster = start()
      {cell, victim} = owned_cell(cluster, "t")
      [one, two] = Cluster.names(cluster) -- [victim]
      {200, _} = write(cluster, one, cell, 1)
      before = lease(cluster, one, cell)
      assert before.owner == Atom.to_string(Cluster.node(cluster, victim))

      t0 = now()
      inject(cluster, unquote(fault), victim, one)
      down = await_event(cluster, one, :down, victim)
      served = serve_again(cluster, one, cell, t0)

      IO.puts(
        "#{unquote(fault)}: down after #{ms_since(t0, down)} ms, served again after #{served} ms (lease ttl #{@ttl_ms} ms)"
      )

      assert served < 10_000

      # One takeover raised the epoch once; the other survivor finds the cell on `one`.
      after_ = lease(cluster, one, cell)
      assert after_.epoch == before.epoch + 1
      assert after_.owner == Atom.to_string(Cluster.node(cluster, one))
      assert [event] = take_overs(cluster, one, cell)
      assert event.meta.node == Cluster.node(cluster, victim)
      assert event.measurements.duration > 0
      assert {200, _} = write(cluster, two, cell, 2)
      assert [0, 1, 2] -- rows(cluster, two, cell) == []

      if unquote(fault) != :sigkill do
        Cluster.resume(cluster, victim)
        for observer <- [one, two], do: await_state(cluster, observer, victim, :alive)
      end

      assert lease(cluster, one, cell).epoch == after_.epoch
    end
  end

  test "a GET in flight when the owner freezes is repeated and served after the takeover" do
    cluster = start()
    {cell, victim} = owned_cell(cluster, "i")
    [one, _two] = Cluster.names(cluster) -- [victim]

    Cluster.pause(cluster, victim)
    t0 = now()
    assert {:ok, %{status: 200, body: body}} = request(cluster, one, :get, "/c/#{cell}")
    waited = div(now() - t0, 1_000)
    IO.puts("GET in flight: served after #{waited} ms")
    assert waited < 10_000
    assert Jason.decode!(body)["node"] == Atom.to_string(Cluster.node(cluster, one))
    assert [_] = take_overs(cluster, one, cell)
    Cluster.resume(cluster, victim)
  end

  # The owner of a cell is frozen until a survivor has it down, the survivors
  # write to the cell (taking it over), and the owner wakes up believing it still
  # holds the cell.
  defp false_positive do
    cluster = start()
    {cell, victim} = owned_cell(cluster, "f")
    [one, two] = Cluster.names(cluster) -- [victim]
    {200, _} = write(cluster, one, cell, 1)

    Cluster.pause(cluster, victim)
    await_event(cluster, one, :down, victim)
    {200, _} = write(cluster, one, cell, 2)
    {200, _} = write(cluster, two, cell, 3)
    Cluster.resume(cluster, victim)

    sql = fn sql -> [Module.concat(Cluster.instance(cluster), Cells), "log." <> cell, sql] end
    {cluster, cell, victim, [one, two], sql}
  end

  test "a node that was only slow is fenced: no acknowledged write is lost or applied twice" do
    {cluster, cell, victim, [one, two], sql} = false_positive()

    # The old owner writes to a cell it lost: the new epoch's fence refuses it.
    stale = Cluster.call(cluster, victim, Alambique, :execute, sql.("INSERT INTO log (n) VALUES (99)"))
    IO.puts("false positive: a write on the old owner after it woke up: #{inspect(stale, limit: 6)}")

    for observer <- [one, two], do: await_state(cluster, observer, victim, :alive)

    acked =
      [0, 1, 2, 3] ++
        for(n <- 10..14, {200, _} <- [write(cluster, Enum.at([one, two, victim], rem(n, 3)), cell, n)], do: n)

    stored = rows(cluster, one, cell)
    assert stored == Enum.uniq(stored)
    assert acked -- stored == []
    assert stored -- [99 | acked] == []

    # An acknowledged write on the old owner would be in the cell; a refused one is not.
    case stale do
      {:ok, {:ok, _}} -> assert 99 in stored
      _ -> refute 99 in stored
    end

    assert lease(cluster, one, cell).epoch == 2
  end

  test "a read with verify_lease sees what the new owner acknowledged; a plain read may not" do
    {cluster, _cell, victim, _survivors, sql} = false_positive()

    {:ok, plain} = Cluster.call(cluster, victim, Alambique, :query, sql.("SELECT n FROM log ORDER BY id") ++ [[]])
    IO.puts("false positive: plain read on the old owner #{inspect(plain, limit: 20)}")

    # Until it is back in the membership the old owner cannot even route to the new one.
    verified =
      Await.until(fn ->
        case Cluster.call(
               cluster,
               victim,
               Alambique,
               :query,
               sql.("SELECT n FROM log ORDER BY id") ++ [[], [verify_lease: true]]
             ) do
          {:ok, {:ok, result}} -> result
          _ -> nil
        end
      end)

    assert [0, 1, 2, 3] -- List.flatten(verified.rows) == []
  end

  test "two nodes that take the same cells over have one winner each and no thrash" do
    cluster = start()
    cells = for i <- 1..40, do: "c#{i}"
    for cell <- cells, do: {200, _} = write(cluster, :n1, cell, 0)

    victim = :n2
    mine = for cell <- cells, name_of(cluster, elem(owner(cluster, :n1, "log", cell), 1)) == victim, do: cell
    assert length(mine) >= 3
    epochs = Map.new(mine, &{&1, lease(cluster, :n1, &1).epoch})

    Cluster.pause(cluster, victim)
    for observer <- [:n1, :n3], do: await_event(cluster, observer, :down, victim)

    results =
      for cell <- mine, via <- [:n1, :n3], n <- 1..4 do
        Task.async(fn -> write_again(cluster, via, cell, n) end)
      end
      |> Task.await_many(60_000)

    assert Enum.all?(results, &match?({200, _}, &1)),
           "some requests failed: #{inspect(Enum.reject(results, &match?({200, _}, &1)))}"

    for cell <- mine do
      lease = lease(cluster, :n1, cell)
      assert lease.epoch == epochs[cell] + 1, "cell #{cell}: epoch #{epochs[cell]} to #{lease.epoch}"
      assert lease.owner in ["#{Cluster.node(cluster, :n1)}", "#{Cluster.node(cluster, :n3)}"]
      assert Enum.sort(rows(cluster, :n1, cell)) == Enum.sort([0, 1, 2, 3, 4, 1, 2, 3, 4])
    end

    IO.puts("concurrent takeovers: #{length(mine)} cells, #{length(results)} requests, every epoch raised once")
    Cluster.resume(cluster, victim)
  end

  test "a link that is only broken does not move the cell" do
    cluster = start()
    {cell, owner} = owned_cell(cluster, "b", [:n2])
    before = lease(cluster, :n1, cell)

    Cluster.partition_nodes(cluster, :n1, owner)
    await_event(cluster, :n1, :link_broken, owner)
    assert {503, body} = write(cluster, :n1, cell, 1)
    assert Jason.decode!(body)["error"] == "unavailable"
    assert {200, _} = write(cluster, :n3, cell, 2)

    assert lease(cluster, :n3, cell).epoch == before.epoch
    assert events(cluster, [:atanor, :cell, :take_over]) == []
    Cluster.heal_nodes(cluster, :n1, owner)
  end

  test "a node cut off from the others is a minority and takes nothing" do
    cluster = start()
    {cell, owner} = owned_cell(cluster, "m", [:n2])
    before = lease(cluster, :n2, cell)

    # n1 loses both peers; they still reach each other and the store.
    Cluster.partition_nodes(cluster, :n1, :n2)
    Cluster.partition_nodes(cluster, :n1, :n3)
    for peer <- [:n2, :n3], do: await_event(cluster, :n1, :down, peer)
    for peer <- [:n2, :n3], do: await_event(cluster, peer, :down, :n1)

    # The first request after the cut may find the peers still in the membership; the next one takes the quorum check.
    Await.until(fn ->
      assert {503, _} = write(cluster, :n1, cell, 1)
      Enum.any?(events(cluster, [:atanor, :cell, :take_over]), &(&1.meta.result == :no_quorum))
    end)

    # Nothing was taken by the minority, not even in the moments between its two verdicts.
    assert cluster
           |> events([:atanor, :cell, :take_over])
           |> Enum.filter(&(&1.node == :n1))
           |> Enum.all?(&(&1.meta.result == :no_quorum))

    # Refusals are rate-limited: many requests, one event per interval (10 s by default).
    for i <- 1..20, do: assert({503, _} = write(cluster, :n1, cell, i))
    refused = cluster |> events([:atanor, :cell, :take_over]) |> Enum.filter(&(&1.node == :n1))
    assert length(refused) <= 2

    assert lease(cluster, :n2, cell).epoch == before.epoch
    assert lease(cluster, :n2, cell).owner == Atom.to_string(Cluster.node(cluster, owner))

    # The majority side serves it.
    assert {200, _} = write(cluster, :n3, cell, 2)
    Cluster.heal_all(cluster)
  end

  describe "a node that was not told it lost a cell" do
    # n2 is cut off from the others, which take its cell over. n2 is not told, and it can still reach the store.
    defp uninformed(options) do
      cluster = start(options)
      {cell, owner} = owned_cell(cluster, "u", [:n2])
      {200, _} = write(cluster, owner, cell, 1)
      Process.sleep(400)
      {200, _} = write(cluster, owner, cell, 2)

      Cluster.partition_nodes(cluster, :n2, :n1)
      Cluster.partition_nodes(cluster, :n2, :n3)
      cells = Module.concat(Cluster.instance(cluster), Cells)
      assert {:ok, {:ok, _}} = Cluster.call(cluster, :n1, Alambique, :take_over, [cells, "log." <> cell, :test])
      # Longer than owner_check_ms (300): the lease it last read is too old to start a handler on.
      Process.sleep(700)

      t0 = now()
      result = write(cluster, :n2, cell, 3)
      # Events reach the cluster process asynchronously.
      Process.sleep(500)

      started =
        for e <- events(cluster, [:atanor, :call]), e.node == :n2 and e.at > t0 and e.meta.cell == {"log", cell}, do: e

      {result, started}
    end

    test "starts no handler for it once the lease it read is older than owner_check_ms" do
      {result, started} = uninformed(routing: [owner_check_ms: 300])
      assert started == []
      refute match?({200, _}, result)
    end

    test "starts one when the check is turned off (the cell's own fencing then refuses the write)" do
      {result, started} = uninformed(routing: [owner_check: false])
      assert [_ | _] = started
      refute match?({200, _}, result)
    end
  end

  test "takeover can be turned off: the cell waits for its lease" do
    cluster = start(takeover: [enabled: false])
    {cell, victim} = owned_cell(cluster, "o")
    [one, _two] = Cluster.names(cluster) -- [victim]
    {200, _} = write(cluster, one, cell, 1)

    Cluster.pause(cluster, victim)
    await_event(cluster, one, :down, victim)
    assert {503, _} = write(cluster, one, cell, 2)
    assert events(cluster, [:atanor, :cell, :take_over]) == []
    Cluster.resume(cluster, victim)
  end

  test "a node that stops gracefully hands its cells off without errors for idempotent requests" do
    cluster = start()
    cells = for i <- 1..30, do: "g#{i}"
    for cell <- cells, do: {200, _} = write(cluster, :n1, cell, 0)
    leaving = :n2
    mine = for cell <- cells, name_of(cluster, elem(owner(cluster, :n1, "log", cell), 1)) == leaving, do: cell
    assert length(mine) >= 3

    stop_at = System.monotonic_time(:millisecond) + 4_000
    survivors = [:n1, :n3]

    loaders =
      for via <- survivors, kind <- [:get, :post] do
        Task.async(fn -> load(cluster, via, kind, mine, stop_at) end)
      end

    Process.sleep(1_000)
    t0 = now()
    supervisor = Module.concat(Cluster.instance(cluster), Supervisor)
    assert {:ok, :ok} = Cluster.call(cluster, leaving, Supervisor, :stop, [supervisor])
    stopped = div(now() - t0, 1_000)

    # A stopped node stays stopped: one that came back would answer before it applied the worker.
    Process.sleep(300)
    assert {:ok, nil} = Cluster.call(cluster, leaving, Process, :whereis, [supervisor])

    [get1, post1, get3, post3] = Task.await_many(loaders, 30_000)
    gets = get1 ++ get3
    posts = post1 ++ post3
    get_errors = Enum.reject(gets, &(&1 == 200))
    post_errors = Enum.reject(posts, &(&1 == 200))

    IO.puts(
      "graceful stop: stop took #{stopped} ms, GET #{length(gets)} requests #{length(get_errors)} errors, " <>
        "POST #{length(posts)} requests #{length(post_errors)} errors #{inspect(Enum.frequencies(post_errors))}"
    )

    assert get_errors == []

    assert [drain] = Enum.filter(Cluster.events(cluster), &(&1.event == [:atanor, :node, :drain]))
    assert drain.measurements.errors == 0
    assert drain.measurements.hibernated >= length(mine)
  end

  # Requests until `stop_at`; the status of each, or the error.
  defp load(cluster, via, kind, cells, stop_at) do
    Stream.repeatedly(fn -> Enum.random(cells) end)
    |> Enum.reduce_while([], fn cell, acc ->
      if System.monotonic_time(:millisecond) > stop_at do
        {:halt, acc}
      else
        status =
          case kind do
            :get ->
              request(cluster, via, :get, "/c/#{cell}")

            :post ->
              request(cluster, via, :post, "/c/#{cell}", body: Integer.to_string(System.unique_integer([:positive])))
          end

        Process.sleep(10)
        {:cont, [(match?({:ok, _}, status) && elem(status, 1).status) || :error | acc]}
      end
    end)
  end
end
