defmodule Atanor.Test.Rolling do
  @moduledoc """
  Helpers of the tests that restart the nodes of a cluster one after another
  under load (`rolling_restart_test.exs`).
  """

  import Atanor.Test.ClusterCase

  alias Atanor.Test.Await
  alias AtanorTestkit.Cluster

  # Each store request of the starting node waits this long, so that the first load of the
  # deployments takes about a second whatever the machine does.
  @latency_ms 300

  @doc "The admin port the restarted instance of `node` binds (chosen by the OS), once it has one."
  def admin_port(node, instance) do
    case :erpc.call(node, Atanor, :admin_port, [instance]) do
      port when is_integer(port) -> port
    end
  catch
    _, _ ->
      Process.sleep(10)
      admin_port(node, instance)
  end

  @doc "The statuses of `/health/ready` in order, without repeats, until the first 200."
  def poll_ready(port) do
    url = "http://127.0.0.1:#{port}/health/ready"
    headers = [{"authorization", "Bearer " <> Cluster.admin_token()}]

    Stream.repeatedly(fn ->
      Process.sleep(10)

      case Req.get(url, headers: headers, retry: false, receive_timeout: 2_000, decode_body: false) do
        {:ok, resp} -> resp.status
        {:error, _} -> :down
      end
    end)
    |> Enum.reduce_while([], fn
      200, acc -> {:halt, Enum.reverse([200 | acc])}
      status, [status | _] = acc -> {:cont, acc}
      status, acc -> {:cont, [status | acc]}
    end)
  end

  @doc "Requests to `url` until `stop` is set: `{{kind, status, error}, at}` of each."
  def load(url, kind, old, stop) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.reduce_while([], fn i, acc ->
      if :atomics.get(stop, 1) == 1 do
        {:halt, acc}
      else
        {path, method, opts} =
          case kind do
            :get_old -> {"/c/" <> Enum.random(old), :get, []}
            :get_new -> {"/c/g#{i}-#{System.unique_integer([:positive])}", :get, []}
            :post_new -> {"/c/p#{i}-#{System.unique_integer([:positive])}", :post, [body: "1"]}
          end

        # Not `request/5`: the cluster process is busy while a peer restarts.
        result =
          case Req.request([method: method, url: url <> path, retry: false, decode_body: false] ++ opts) do
            {:ok, %{status: 200}} -> {kind, 200, nil}
            {:ok, resp} -> {kind, resp.status, error(resp.body)}
            {:error, reason} -> {kind, :error, inspect(reason)}
          end

        Process.sleep(10)
        {:cont, [{result, now()} | acc]}
      end
    end)
  end

  defp error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error, "reason" => reason}} -> "#{error}: #{reason}"
      {:ok, %{"error" => error}} -> error
      _ -> body
    end
  end

  @doc "Starts the loaders through the peers other than `leaving`: `{stop, tasks}`."
  def start_load(cluster, leaving, old) do
    stop = :atomics.new(1, [])

    loaders =
      for via <- Cluster.names(cluster) -- [leaving],
          kind <- [:get_old, :get_new, :post_new],
          url = Cluster.url(cluster, via),
          do: Task.async(fn -> load(url, kind, old, stop) end)

    {stop, loaders}
  end

  @doc "Stops the loaders and returns the results of all of them."
  def stop_load({stop, loaders}) do
    :atomics.put(stop, 1, 1)
    loaders |> Task.await_many(60_000) |> List.flatten()
  end

  @doc """
  Stops `leaving` gracefully, kills its VM and starts it again (`atanor:` replaces its options, as a new
  release does), with its store requests slowed. Returns when the instance runs: `%{health: statuses of
  /health/ready, started: time of the start}`.
  """
  def restart(cluster, leaving, opts \\ []) do
    supervisor = Module.concat(Cluster.instance(cluster), Supervisor)
    {:ok, :ok} = Cluster.call(cluster, leaving, Supervisor, :stop, [supervisor])
    Cluster.kill(cluster, leaving)

    Cluster.inject(cluster, leaving, kind: :latency, ms: @latency_ms, times: 5)
    started = now()
    node = Cluster.node(cluster, leaving)
    instance = Cluster.instance(cluster)
    # Port 0, read back from the new instance: a port picked beforehand could be taken meanwhile.
    watcher = Task.async(fn -> node |> admin_port(instance) |> poll_ready() end)
    :ok = Cluster.restart(cluster, leaving, opts)
    %{health: Task.await(watcher, 60_000), started: started}
  end

  @doc "Waits until the restarted node takes cells again."
  def serving(cluster, leaving),
    do: Await.until(fn -> match?({200, _}, write(cluster, leaving, "back-#{leaving}", 1)) end, 20_000)

  @doc "The requests of the rolling restart that must not fail: `{GET errors, POST errors}`."
  def failures(results) do
    gets = for {kind, status, error} <- results, kind != :post_new, {status, error} != {200, nil}, do: {kind, error}

    # A POST that did not run, or whose outcome is unknown, may be repeated by the client.
    posts =
      for {:post_new, status, error} <- results,
          status != 200 and (status != 503 or error =~ "owner_unreachable"),
          do: {status, error}

    {gets, posts}
  end
end
