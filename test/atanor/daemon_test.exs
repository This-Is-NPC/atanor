defmodule Atanor.DaemonTest do
  use ExUnit.Case, async: true

  alias Atanor.Daemon

  @token String.duplicate("t", 40)
  @secret "s3cr3t-access-key-value"

  defp env(extra \\ %{}) do
    Map.merge(
      %{
        "ATANOR_STORE" => "s3://bucket/some/prefix",
        "AWS_ACCESS_KEY_ID" => "AKIAEXAMPLE",
        "AWS_SECRET_ACCESS_KEY" => @secret,
        "ATANOR_DATA_DIR" => System.tmp_dir!()
      },
      extra
    )
  end

  defp errors(env, file \\ nil, opts \\ []) do
    assert {:error, messages} = Daemon.load(env, file, opts)
    Enum.join(messages, "\n")
  end

  describe "defaults" do
    test "a store and keys are enough" do
      assert {:ok, %{opts: opts}} = Daemon.load(env())
      assert opts[:prefix] == "some/prefix"
      assert opts[:port] == 4000 and opts[:ip] == {0, 0, 0, 0}
      assert opts[:data_dir] == System.tmp_dir!()
      refute opts[:admin] || opts[:dashboard] || opts[:release] || opts[:stop]

      assert {Alambique.Store.S3, %{region: "us-east-1", bucket: "bucket"} = s3} = opts[:store]
      refute Map.has_key?(s3, :endpoint)

      assert %Atanor.Config{} = Atanor.Config.build(opts)
    end

    test "the release id defaults to the Atanor version" do
      {:ok, %{opts: opts}} = Daemon.load(env())
      assert Atanor.Config.build(opts).release.id == Atanor.Release.default_id()
    end

    test "a bucket without a prefix keeps the default prefix" do
      {:ok, %{opts: opts}} = Daemon.load(env(%{"ATANOR_STORE" => "s3://bucket"}))
      assert Atanor.Config.build(opts).prefix == "atanor"
    end

    test "the endpoint is left to Alambique, which derives it from the region" do
      {:ok, %{opts: opts}} = Daemon.load(env(%{"ATANOR_S3_REGION" => "eu-west-1"}))
      assert {_, %{region: "eu-west-1"} = s3} = opts[:store]
      refute Map.has_key?(s3, :endpoint)
    end

    test "only the store is required: the credentials come from the chain" do
      assert errors(%{"AWS_EC2_METADATA_DISABLED" => "true"}) =~ "ATANOR_STORE"

      assert {:ok, %{children: [_]}} =
               Daemon.load(Map.delete(env(), "AWS_ACCESS_KEY_ID") |> Map.delete("AWS_SECRET_ACCESS_KEY"))
    end
  end

  describe "keys" do
    test "every key reaches its option" do
      env =
        env(%{
          "ATANOR_S3_ENDPOINT" => "http://store:8333",
          "ATANOR_LISTEN" => "127.0.0.1:5000",
          "ATANOR_ADMIN_LISTEN" => "127.0.0.1:5001",
          "ATANOR_ADMIN_TOKEN" => @token,
          "ATANOR_NODE_ID" => "node-a",
          "ATANOR_RELEASE" => "r1",
          "ATANOR_MEMORY_LIMIT" => "512m",
          "ATANOR_DISK_LIMIT" => "2g",
          "ATANOR_WAL_LIMIT" => "64m",
          "ATANOR_LEASE_TTL_MS" => "20000",
          "ATANOR_SHUTDOWN_MS" => "50000",
          "ATANOR_DRAIN_TIMEOUT_MS" => "9000",
          "ATANOR_DRAIN_CONCURRENCY" => "8",
          "ATANOR_DETECTOR_PAUSE_MS" => "3000",
          "ATANOR_ADVERTISE" => "node-a.example",
          "ATANOR_REGISTRY_TTL_MS" => "9000",
          "ATANOR_REGISTRY_RENEW_MS" => "1500"
        })

      assert {:ok, %{opts: opts}} = Daemon.load(env)
      config = Atanor.Config.build(opts)
      assert {Alambique.Store.S3, %{endpoint: "http://store:8333"}} = opts[:store]
      assert {config.ip, config.port} == {{127, 0, 0, 1}, 5000}
      assert {config.admin.ip, config.admin.port, config.admin.token} == {{127, 0, 0, 1}, 5001, @token}
      assert config.release.id == "r1"
      assert config.memory.limit_bytes == 512 * 1_048_576
      assert config.disk.max_bytes == 2 * 1_073_741_824
      assert opts[:alambique][:wal][:max_bytes] == 64 * 1_048_576
      assert opts[:alambique][:node_id] == "node-a"
      assert opts[:alambique][:lease_ttl_ms] == 20_000
      assert opts[:alambique][:registry] == [advertise: "atanor@node-a.example", ttl_ms: 9_000, renew_ms: 1_500]

      assert {config.stop.shutdown_ms, config.stop.drain_timeout_ms, config.stop.drain_concurrency} ==
               {50_000, 9_000, 8}

      assert config.detector.acceptable_pause_ms == 3_000
    end

    test "the registry advertises the node name, with a join time of seconds by default" do
      {:ok, %{opts: opts}} = Daemon.load(env(%{"ATANOR_ADVERTISE" => "10.0.0.7"}))
      assert opts[:alambique][:registry] == [advertise: "atanor@10.0.0.7", ttl_ms: 15_000, renew_ms: 3_000]
      assert %Atanor.Config{} = Atanor.Config.build(opts)
    end

    test "a group goes to the registry's meta, and only a valid one" do
      {:ok, %{opts: opts}} = Daemon.load(env(%{"ATANOR_ADVERTISE" => "h", "ATANOR_GROUP" => "blue-2"}))
      assert opts[:alambique][:registry][:meta] == %{"group" => "blue-2"}
      assert errors(env(%{"ATANOR_GROUP" => "no spaces"})) =~ "ATANOR_GROUP"
    end

    test "the registry times are checked at load" do
      advertise = %{"ATANOR_ADVERTISE" => "h"}
      assert errors(env(Map.put(advertise, "ATANOR_REGISTRY_TTL_MS", "3000"))) =~ "twice :skew_margin_ms"
      assert errors(env(Map.put(advertise, "ATANOR_REGISTRY_RENEW_MS", "15000"))) =~ ":renew_ms must be less"
    end

    test "the retired peers list is refused" do
      assert errors(env(%{"ATANOR_PEERS" => "node-1"})) =~ "unknown variable ATANOR_PEERS"
    end

    test "an empty variable counts as unset" do
      assert {:ok, %{opts: opts}} = Daemon.load(env(%{"ATANOR_SHUTDOWN_MS" => "", "ATANOR_REGISTRY_TTL_MS" => ""}))
      refute opts[:stop]
    end

    test "Config.build is the validator" do
      assert errors(env(%{"ATANOR_ADMIN_TOKEN" => "short", "ATANOR_ADMIN_LISTEN" => "0.0.0.0:1"})) =~
               "at least 32 bytes"

      assert errors(env(%{"ATANOR_STORE" => "s3://bucket/Bad Prefix"})) =~ ":prefix"
      assert errors(env(%{"ATANOR_ADMIN_LISTEN" => "127.0.0.1:1"})) =~ "token"
    end

    test "bad values name their variable" do
      assert errors(env(%{"ATANOR_LISTEN" => "nope"})) =~ "ATANOR_LISTEN: must be ip:port"
      assert errors(env(%{"ATANOR_SHUTDOWN_MS" => "1.5"})) =~ "ATANOR_SHUTDOWN_MS"
      assert errors(env(%{"ATANOR_DISK_LIMIT" => "2t"})) =~ "ATANOR_DISK_LIMIT"
      assert errors(env(%{"ATANOR_STORE" => "http://bucket"})) =~ "ATANOR_STORE"
      assert errors(env(%{"ATANOR_STORE" => "s3://bucket?x=1"})) =~ "ATANOR_STORE"
      assert errors(env(%{"ATANOR_ADVERTISE" => "a@b"})) =~ "ATANOR_ADVERTISE"
      assert errors(env(%{"ATANOR_NET_TICKTIME" => "0"})) =~ "ATANOR_NET_TICKTIME"
    end

    test "the boot keys come from the environment only" do
      assert {:ok, _} = Daemon.load(env(%{"ATANOR_ADVERTISE" => "10.0.0.1", "ATANOR_NET_TICKTIME" => "30"}))
      assert errors(env(), ~s({"advertise": "10.0.0.1"})) =~ "set it in the environment"
    end

    test "a session token goes to the store with the keys" do
      {:ok, %{opts: opts}} = Daemon.load(env(%{"AWS_SESSION_TOKEN" => "tok"}))
      assert {_, %{session_token: "tok"}} = opts[:store]
      {:ok, %{opts: opts}} = Daemon.load(env(), ~s({"aws_session_token": "tok2"}))
      assert {_, %{session_token: "tok2"}} = opts[:store]
    end
  end

  describe "strictness" do
    # Regression: before Atanor.Daemon, the node read its variables one by one and ignored the rest.
    test "an unknown ATANOR_ variable fails, names itself and suggests the closest key" do
      message = errors(env(%{"ATANOR_LISTN" => "0.0.0.0:1"}))
      assert message =~ "variable ATANOR_LISTN"
      assert message =~ "did you mean ATANOR_LISTEN?"
    end

    test "the old node names fail" do
      assert errors(env(%{"ATANOR_NODE_BUCKET" => "x"})) =~ "ATANOR_NODE_BUCKET"
    end

    test "the CLI variables are the only exceptions" do
      cli = Map.new(Daemon.cli_variables(), &{&1, "x"})
      assert {:ok, _} = Daemon.load(Map.merge(env(), cli))
      assert errors(env(%{"ATANOR_NEW_TIMEOUT" => "1"})) =~ "ATANOR_NEW_TIMEOUT"
    end

    test "variables outside ATANOR_ are not ours" do
      assert {:ok, _} = Daemon.load(env(%{"PATH" => "/bin", "AWS_REGION" => "x", "RELEASE_COOKIE" => "c"}))
    end

    test "an unknown key of the file fails" do
      message = errors(env(), ~s({"lisen": "0.0.0.0:1"}))
      assert message =~ ~s(key "lisen")
      assert message =~ "did you mean listen?"
    end

    test "the file must be a flat object of strings and integers" do
      assert errors(env(), "[]") =~ "JSON object"
      assert errors(env(), "{") =~ "not valid JSON"
      assert errors(env(), ~s({"listen": ["x"]})) =~ "string or an integer"
    end

    test "every problem is reported at once" do
      message = errors(env(%{"ATANOR_A" => "1", "ATANOR_B" => "2"}))
      assert message =~ "ATANOR_A" and message =~ "ATANOR_B"
    end

    test "the variables of the start script are known" do
      script = File.read!("daemon/rel/env.sh.eex")

      names = Regex.scan(~r/ATANOR_[A-Z_]+/, script) |> List.flatten() |> Enum.uniq()
      assert names != []
      assert names -- Daemon.known_variables() == []
      assert Enum.all?(Daemon.boot_variables(), &(&1 in names))
    end
  end

  describe "file and environment" do
    test "the file gives the values" do
      file =
        ~s({"store": "s3://bucket", "aws_access_key_id": "k", "aws_secret_access_key": "s", "listen": "127.0.0.1:5000", "shutdown_ms": 60000})

      assert {:ok, %{opts: opts}} = Daemon.load(%{"ATANOR_DATA_DIR" => System.tmp_dir!()}, file)
      assert opts[:port] == 5000 and opts[:stop][:shutdown_ms] == 60_000
    end

    test "the environment overrides the file" do
      file = ~s({"listen": "127.0.0.1:5000", "release": "from-file", "shutdown_ms": 60000})
      assert {:ok, %{opts: opts}} = Daemon.load(env(%{"ATANOR_LISTEN" => "127.0.0.1:6000"}), file)
      assert opts[:port] == 6000
      assert opts[:release][:id] == "from-file"
    end
  end

  describe "secrets" do
    defp reader(files),
      do: fn path ->
        Map.fetch(files, path)
        |> then(fn
          :error -> {:error, :enoent}
          ok -> ok
        end)
      end

    test "a *_FILE variant reads the value, without its newline" do
      env = env(%{"AWS_SECRET_ACCESS_KEY_FILE" => "/s/key"}) |> Map.delete("AWS_SECRET_ACCESS_KEY")
      assert {:ok, %{opts: opts}} = Daemon.load(env, nil, read_file: reader(%{"/s/key" => "from-file\n"}))
      assert {_, %{secret_access_key: key}} = opts[:store]
      assert key == "from-file"
    end

    test "both forms in one place are an error" do
      assert errors(env(%{"AWS_SECRET_ACCESS_KEY_FILE" => "/s/key"})) =~
               "AWS_SECRET_ACCESS_KEY and AWS_SECRET_ACCESS_KEY_FILE"

      file = ~s({"admin_token": "x", "admin_token_file": "/t"})
      assert errors(env(), file) =~ "ATANOR_ADMIN_TOKEN and ATANOR_ADMIN_TOKEN_FILE"
    end

    test "the environment's form replaces the file's" do
      file = ~s({"admin_token": "inline-in-file"})
      env = env(%{"ATANOR_ADMIN_TOKEN_FILE" => "/t", "ATANOR_ADMIN_LISTEN" => "0.0.0.0:1"})
      assert {:ok, %{opts: opts}} = Daemon.load(env, file, read_file: reader(%{"/t" => @token}))
      assert opts[:admin][:token] == @token
    end

    test "an unreadable or empty file is an error" do
      env = env(%{"ATANOR_ADMIN_TOKEN_FILE" => "/missing"})
      assert errors(env, nil, read_file: reader(%{})) =~ "ATANOR_ADMIN_TOKEN_FILE: cannot read /missing"
      assert errors(env, nil, read_file: reader(%{"/missing" => "\n"})) =~ "is empty"
    end

    test "the log line masks every secret" do
      env = env(%{"ATANOR_ADMIN_TOKEN" => @token, "ATANOR_ADMIN_LISTEN" => "0.0.0.0:1"})
      assert {:ok, settings} = Daemon.load(env)
      line = Daemon.describe(settings)
      assert line =~ "ATANOR_STORE=s3://bucket/some/prefix"
      assert line =~ "AWS_SECRET_ACCESS_KEY=***"
      refute line =~ @secret
      refute line =~ @token
      refute line =~ "AKIAEXAMPLE"
    end
  end

  describe "store/3" do
    test "is the store the node builds from the same URL, endpoint, region and keys" do
      extra = %{
        "ATANOR_S3_ENDPOINT" => "http://s3.test:9000",
        "AWS_REGION" => "eu-west-1",
        "AWS_SESSION_TOKEN" => "temporary"
      }

      {:ok, %{opts: opts}} = Daemon.load(env(extra))
      {:ok, found} = Daemon.store("s3://bucket/some/prefix", env(extra))

      assert found.store == opts[:store]
      assert found.prefix == opts[:prefix]
      assert found.children == [] and found.credentials == "env"
      assert {_, %{region: "eu-west-1", endpoint: "http://s3.test:9000", session_token: "temporary"}} = found.store
    end

    test "gives the bucket the default prefix, and the region the node's precedence" do
      assert {:ok, %{prefix: "atanor", store: {_, %{region: "us-east-1", bucket: "b"}}}} = Daemon.store("s3://b", env())

      for {extra, region} <- [
            {%{"AWS_DEFAULT_REGION" => "d"}, "d"},
            {%{"AWS_DEFAULT_REGION" => "d", "AWS_REGION" => "r"}, "r"},
            {%{"AWS_DEFAULT_REGION" => "d", "AWS_REGION" => "r", "ATANOR_S3_REGION" => "a"}, "a"}
          ] do
        assert {:ok, %{store: {_, %{region: ^region}}}} = Daemon.store("s3://b", env(extra))
      end
    end

    test "the URL given wins over ATANOR_STORE of the environment" do
      assert {:ok, %{prefix: "other", store: {_, %{bucket: "elsewhere"}}}} =
               Daemon.store("s3://elsewhere/other", env())
    end

    test "keeps the renewable credentials of the chain in a child to start" do
      env = Map.drop(env(), ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])

      assert {:ok, %{children: [{Atanor.AwsCredentials, {{:imds, _}, _}}], credentials: "EC2 metadata"} = found} =
               Daemon.store("s3://b", env)

      assert {_, %{credentials: fun}} = found.store
      assert is_function(fun, 0)
    end

    test "reads a secret from its file, and ignores a setting that is not the store's" do
      assert {:error, [message]} =
               Daemon.store("s3://b", env(%{"ATANOR_LISTEN" => "nowhere"}) |> Map.put("ATANOR_X", "1"))

      assert message =~ "unknown variable ATANOR_X"

      files = %{"/run/key" => "from-file\n"}

      env =
        env(%{"ATANOR_LISTEN" => "nowhere", "AWS_SECRET_ACCESS_KEY_FILE" => "/run/key"})
        |> Map.delete("AWS_SECRET_ACCESS_KEY")

      assert {:ok, %{store: {_, %{secret_access_key: "from-file"}}}} =
               Daemon.store("s3://b", env,
                 read_file: fn path -> with :error <- Map.fetch(files, path), do: {:error, :enoent} end
               )
    end

    test "refuses what the node refuses" do
      assert {:error, [message]} = Daemon.store("http://bucket", env())
      assert message =~ "ATANOR_STORE: must be s3://bucket"

      assert {:error, [message]} = Daemon.store("s3://b/Not A Prefix", env())
      assert message =~ ":prefix"

      assert {:error, [message]} =
               Daemon.store(
                 "s3://b",
                 Map.drop(env(), ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])
                 |> Map.put("AWS_EC2_METADATA_DISABLED", "true")
               )

      assert message =~ "no AWS credentials"
    end
  end

  describe "load!/1" do
    test "reads the file named by ATANOR_CONFIG and logs once" do
      path = Path.join(System.tmp_dir!(), "atanor-daemon-#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"listen": "127.0.0.1:5000"}))
      on_exit(fn -> File.rm(path) end)

      log =
        ExUnit.CaptureLog.capture_log(fn -> assert %{opts: _} = Daemon.load!(env(%{"ATANOR_CONFIG" => path})) end)

      assert log =~ "effective settings"
      assert log =~ "ATANOR_LISTEN=127.0.0.1:5000"
      refute log =~ @secret
    end

    test "raises with every problem" do
      assert_raise ArgumentError, ~r/invalid configuration:\n  unknown variable ATANOR_X/, fn ->
        Daemon.load!(env(%{"ATANOR_X" => "1"}))
      end

      assert_raise ArgumentError, ~r/cannot read/, fn -> Daemon.load!(env(%{"ATANOR_CONFIG" => "/no/such/file"})) end
    end
  end
end
