defmodule Atanor.ClearListenerWarningTest do
  # Not async: `capture_log` sees the logs of every process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AtanorTestkit.Node

  @token String.duplicate("t", 40)

  defp log_of(opts) do
    capture_log([level: :warning], fn ->
      node = Node.start(opts)
      Node.stop(node)
    end)
  end

  test "an admin listener outside loopback warns that its token passes in clear" do
    log = log_of(admin: [token: @token, port: 0, ip: {0, 0, 0, 0}])
    assert log =~ "the admin listener binds 0.0.0.0"
    assert log =~ "ATANOR_BEHIND_TLS_PROXY"
  end

  test "the setting turns the warning off" do
    refute log_of(admin: [token: @token, port: 0, ip: {0, 0, 0, 0}], behind_tls_proxy: true) =~ "without TLS"
  end

  test "a loopback listener does not warn" do
    for ip <- [{127, 0, 0, 1}, {127, 1, 2, 3}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      refute log_of(admin: [token: @token, port: 0, ip: ip]) =~ "without TLS"
    end
  end

  test "the dashboard listener warns too" do
    log = log_of(dashboard: [token: @token, port: 0, ip: {0, 0, 0, 0}])
    assert log =~ "the dashboard listener binds 0.0.0.0"
  end

  test "the daemon maps ATANOR_BEHIND_TLS_PROXY, and the file key, to the option" do
    env = %{"ATANOR_STORE" => "s3://bucket", "AWS_ACCESS_KEY_ID" => "k", "AWS_SECRET_ACCESS_KEY" => "s"}
    refute env |> Atanor.Daemon.load() |> elem(1) |> Map.fetch!(:opts) |> Keyword.has_key?(:behind_tls_proxy)

    {:ok, %{opts: opts}} = Atanor.Daemon.load(Map.put(env, "ATANOR_BEHIND_TLS_PROXY", "true"))
    assert opts[:behind_tls_proxy] == true

    {:ok, %{opts: opts}} = Atanor.Daemon.load(env, ~s({"behind_tls_proxy": "true"}))
    assert opts[:behind_tls_proxy] == true
    assert {:error, [message]} = Atanor.Daemon.load(Map.put(env, "ATANOR_BEHIND_TLS_PROXY", "yes"))
    assert message =~ "ATANOR_BEHIND_TLS_PROXY"
  end

  test "behind_tls_proxy must be a boolean" do
    assert_raise ArgumentError, ~r/behind_tls_proxy/, fn ->
      Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, behind_tls_proxy: "yes")
    end
  end
end
