defmodule Atanor.DaemonConsentTest do
  # Not async: `capture_log` sees the logs of every process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Atanor.{Daemon, Overview}
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @operator "operator-secret"
  @three ~w(ATANOR_HOSTS ATANOR_HTTP_ALLOW ATANOR_NAMESPACES)

  defp env(extra \\ %{}) do
    Map.merge(
      %{
        "ATANOR_STORE" => "s3://bucket",
        "AWS_ACCESS_KEY_ID" => "AKIAEXAMPLE",
        "AWS_SECRET_ACCESS_KEY" => "s3cr3t-access-key-value",
        "ATANOR_DATA_DIR" => System.tmp_dir!()
      },
      extra
    )
  end

  defp opts(extra), do: Daemon.load(env(extra)) |> then(fn {:ok, settings} -> settings.opts end)

  describe "parsing" do
    test "a ceiling is a map from a name to a list" do
      opts =
        opts(%{
          "ATANOR_HOSTS" => "a=127.0.0.1, b.test ;c=*.example.com",
          "ATANOR_NAMESPACES" => "notes=a,b",
          "ATANOR_HTTP_ALLOW" => "a=api.example.com"
        })

      assert opts[:hosts] == %{"a" => ["127.0.0.1", "b.test"], "c" => ["*.example.com"]}
      assert opts[:namespaces] == %{"notes" => ["a", "b"]}
      assert opts[:http_allow] == %{"a" => ["api.example.com"]}
      assert %Atanor.Config{hosts: %{"a" => _}} = Atanor.Config.build(opts)
    end

    test "unset, the three stay out of the options (no restriction)" do
      opts = opts(%{})
      for key <- [:hosts, :namespaces, :http_allow], do: refute(Keyword.has_key?(opts, key))
    end

    test "the file keys are the names in lowercase" do
      file = Jason.encode!(%{"hosts" => "a=a.test", "namespaces" => "n=a", "http_allow" => "a=x.test"})
      assert {:ok, %{opts: opts}} = Daemon.load(env(), file)
      assert opts[:hosts] == %{"a" => ["a.test"]}
      assert opts[:namespaces] == %{"n" => ["a"]}
      assert opts[:http_allow] == %{"a" => ["x.test"]}
    end

    test "a malformed value or an entry the library refuses fails the start, naming the variable" do
      for {name, bad} <- [
            {"ATANOR_HOSTS", "a"},
            {"ATANOR_HOSTS", "a="},
            {"ATANOR_HOSTS", "a=x,,y"},
            {"ATANOR_HOSTS", ";"}
          ] do
        assert {:error, [message]} = Daemon.load(env(%{name => bad}))
        assert message =~ name
      end

      assert {:error, [message]} = Daemon.load(env(%{"ATANOR_HOSTS" => "a=Not A Host"}))
      assert message =~ ":hosts"
    end

    test "the effective settings show them" do
      {:ok, settings} = Daemon.load(env(%{"ATANOR_HOSTS" => "b=y.test;a=x.test,z.test"}))
      assert {"ATANOR_HOSTS", "a=x.test,z.test;b=y.test"} in settings.effective
    end
  end

  describe "the startup warning" do
    defp warnings(extra) do
      capture_log([level: :warning], fn -> Daemon.load!(env(extra)) end)
    end

    test "appears when none of the three is set, and names them" do
      log = warnings(%{})
      assert log =~ "trusts every deployer"
      for name <- @three, do: assert(log =~ name)
    end

    test "does not appear when any of them is set" do
      for {name, value} <- [
            {"ATANOR_HOSTS", "a=a.test"},
            {"ATANOR_NAMESPACES", "n=a"},
            {"ATANOR_HTTP_ALLOW", "a=x.test"}
          ] do
        refute warnings(%{name => value}) =~ "trusts every deployer"
      end
    end
  end

  describe "on a node" do
    defp start(opts) do
      node = Node.start([admin: [token: @operator, port: 0]] ++ opts)
      on_exit(fn -> Node.stop(node) end)
      node
    end

    test "GET /runtime shows which ceilings are set" do
      open = start([])
      assert Overview.runtime(open.name).consent == %{hosts: false, http_allow: false, namespaces: false, open: true}

      closed =
        start(Keyword.take(opts(%{"ATANOR_HOSTS" => "a=a.test", "ATANOR_NAMESPACES" => "n=a"}), [:hosts, :namespaces]))

      assert Overview.runtime(closed.name).consent == %{hosts: true, http_allow: false, namespaces: true, open: false}

      response =
        Req.get!("http://127.0.0.1:#{Atanor.admin_port(closed.name)}/runtime",
          headers: [{"authorization", "Bearer " <> @operator}],
          retry: false
        )

      assert response.body["consent"] == %{
               "hosts" => true,
               "http_allow" => false,
               "namespaces" => true,
               "open" => false
             }
    end

    test "with ATANOR_HOSTS set, a deploy that claims another host is refused" do
      node = start(Keyword.take(opts(%{"ATANOR_HOSTS" => "a=a.test"}), [:hosts]))

      upload = fn manifest ->
        package = Manifests.package(manifest)

        Req.post!(
          "http://127.0.0.1:#{Atanor.admin_port(node.name)}/workers/#{package.manifest.name}/packages?activate=true",
          body: package.bytes,
          headers: [{"authorization", "Bearer " <> @operator}, {"x-package-sha256", package.id}],
          retry: false
        )
      end

      assert %{status: 422, body: %{"error" => "host_not_allowed", "subject" => "b.test"}} =
               upload.(Manifests.probe("a", routes: [{"b.test", "/"}]))

      assert upload.(Manifests.probe("a", routes: [{"a.test", "/"}])).status in [200, 201]
    end
  end
end
