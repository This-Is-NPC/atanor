defmodule Atanor.AwsCredentialsTest do
  # The holder registers a name; the tests that start the daemon's one run one at a time.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Atanor.AwsCredentials
  alias Atanor.Daemon

  @secret "SECRETKEYVALUE0123456789"
  @token "SESSIONTOKENVALUE0123456789"
  @web_token "WEBIDENTITYJWTVALUE0123456789"

  ## A fake endpoint for STS, the container agent, IMDS and S3. `handler` is an Agent holding a function
  ## of the connection and its body that answers it; every request is reported to the test.

  defmodule Fake do
    @behaviour Plug
    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, {test, agent}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:hit, conn.method, conn.request_path, conn.req_headers, body})
      Agent.get(agent, & &1).(conn, body)
    end
  end

  defp fake(handler) do
    {:ok, agent} = Agent.start_link(fn -> handler end)
    {:ok, pid} = Bandit.start_link(plug: {Fake, {self(), agent}}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {"http://127.0.0.1:#{port}", agent}
  end

  defp in_seconds(n), do: DateTime.utc_now() |> DateTime.add(n, :second) |> DateTime.to_iso8601()

  defp creds_json(id, expires_in),
    do:
      Jason.encode!(%{
        "AccessKeyId" => id,
        "SecretAccessKey" => @secret,
        "Token" => @token,
        "Expiration" => in_seconds(expires_in)
      })

  defp sts_xml(id, expires_in) do
    "<AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult><Credentials>" <>
      "<AccessKeyId>#{id}</AccessKeyId><SecretAccessKey>#{@secret}</SecretAccessKey>" <>
      "<SessionToken>#{@token}</SessionToken><Expiration>#{in_seconds(expires_in)}</Expiration>" <>
      "</Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>"
  end

  defp container_handler(id_fun) do
    fn conn, _ -> Plug.Conn.send_resp(conn, 200, id_fun.()) end
  end

  defp holder(url, id, expires_in, opts \\ []) do
    handler = container_handler(fn -> creds_json(id, expires_in) end)
    {base, agent} = fake(handler)
    provider = {:container, %{url: base <> url, token: nil}}
    {:ok, pid} = AwsCredentials.start_link(provider, [name: nil, source: "container credentials"] ++ opts)
    {pid, agent, base}
  end

  defp hits(acc \\ 0) do
    receive do
      {:hit, _, _, _, _} -> hits(acc + 1)
    after
      0 -> acc
    end
  end

  describe "the sources" do
    test "the environment, with an optional session token" do
      assert {:ok, %{source: "env", static: {"AK", "SK", nil}, provider: nil}} =
               AwsCredentials.detect(%{"AWS_ACCESS_KEY_ID" => "AK", "AWS_SECRET_ACCESS_KEY" => "SK"})

      assert {:ok, %{static: {"AK", "SK", "TOK"}}} =
               AwsCredentials.detect(%{
                 "AWS_ACCESS_KEY_ID" => "AK",
                 "AWS_SECRET_ACCESS_KEY" => "SK",
                 "AWS_SESSION_TOKEN" => "TOK"
               })

      assert {:error, message} = AwsCredentials.detect(%{"AWS_ACCESS_KEY_ID" => "AK"})
      assert message =~ "without AWS_SECRET_ACCESS_KEY"
    end

    test "web identity needs the token file and the role" do
      assert {:error, message} = AwsCredentials.detect(%{"AWS_WEB_IDENTITY_TOKEN_FILE" => "/t"})
      assert message =~ "without AWS_ROLE_ARN"
      assert {:error, message} = AwsCredentials.detect(%{"AWS_ROLE_ARN" => "arn:aws:iam::1:role/r"})
      assert message =~ "without AWS_WEB_IDENTITY_TOKEN_FILE"

      config = %{
        "AWS_WEB_IDENTITY_TOKEN_FILE" => "/t",
        "AWS_ROLE_ARN" => "arn:aws:iam::1:role/r",
        "AWS_REGION" => "eu-west-1"
      }

      assert {:ok, %{source: "web identity", provider: {:web_identity, p}}} = AwsCredentials.detect(config)
      assert p.endpoint == "https://sts.eu-west-1.amazonaws.com"
      assert p.session_name == "atanor"
    end

    defp files(map), do: fn path -> with :error <- Map.fetch(map, path), do: {:error, :enoent} end

    test "the shared files: the default profile, a named one and the config file" do
      creds =
        "[default]\naws_access_key_id = A1\naws_secret_access_key = S1\n\n[work]\n# c\naws_access_key_id=A2\naws_secret_access_key=S2\naws_session_token=T2\n"

      conf = "[default]\nregion = x\n[profile team]\naws_access_key_id = A3\naws_secret_access_key = S3\n"
      opts = [home: "/h", read_file: files(%{"/h/.aws/credentials" => creds, "/h/.aws/config" => conf})]

      assert {:ok, %{source: "profile default", static: {"A1", "S1", nil}}} = AwsCredentials.detect(%{}, opts)
      assert {:ok, %{static: {"A2", "S2", "T2"}}} = AwsCredentials.detect(%{"AWS_PROFILE" => "work"}, opts)
      assert {:ok, %{static: {"A3", "S3", nil}}} = AwsCredentials.detect(%{"AWS_PROFILE" => "team"}, opts)
    end

    test "the shared file variables name other files" do
      creds = "[p]\naws_access_key_id = A\naws_secret_access_key = S\n"
      config = %{"AWS_PROFILE" => "p", "AWS_SHARED_CREDENTIALS_FILE" => "/c/creds", "AWS_CONFIG_FILE" => "/c/config"}
      opts = [read_file: files(%{"/c/creds" => creds, "/c/config" => ""})]
      assert {:ok, %{static: {"A", "S", nil}}} = AwsCredentials.detect(config, opts)

      assert {:error, message} = AwsCredentials.detect(config, read_file: files(%{"/c/creds" => creds}))
      assert message =~ "cannot read /c/config"
    end

    test "SSO, credential_process and roles are unsupported, with a clear error" do
      for {section, what} <- [
            {"sso_session = s\nsso_account_id = 1", "SSO"},
            {"credential_process = /bin/x", "credential_process"},
            {"role_arn = arn:aws:iam::1:role/r\nsource_profile = d", "assumed roles"}
          ] do
        opts = [home: "/h", read_file: files(%{"/h/.aws/config" => "[default]\n" <> section <> "\n"})]
        assert {:error, message} = AwsCredentials.detect(%{}, opts)
        assert message =~ "profile default uses #{what}, which the daemon does not support"
      end
    end

    test "a named profile that does not exist is an error; the default one is skipped" do
      opts = [home: "/h", read_file: files(%{})]

      assert {:error, message} =
               AwsCredentials.detect(%{"AWS_PROFILE" => "nope", "AWS_EC2_METADATA_DISABLED" => "true"}, opts)

      assert message =~ "AWS_PROFILE nope"
      assert {:ok, %{source: "EC2 metadata"}} = AwsCredentials.detect(%{}, opts)
    end

    test "container credentials: the relative URI is on the agent's address, the full one is as given" do
      assert {:ok, %{source: "container credentials", provider: {:container, p}}} =
               AwsCredentials.detect(%{"AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" => "/v2/credentials/x"})

      assert p.url == "http://169.254.170.2/v2/credentials/x"

      assert {:ok, %{provider: {:container, %{url: "http://h/creds", token: "t"}}}} =
               AwsCredentials.detect(%{
                 "AWS_CONTAINER_CREDENTIALS_FULL_URI" => "http://h/creds",
                 "AWS_CONTAINER_AUTHORIZATION_TOKEN" => "t"
               })
    end

    test "EC2 metadata is the last source and can be turned off" do
      assert {:ok, %{source: "EC2 metadata", provider: {:imds, %{endpoint: "http://169.254.169.254"}}}} =
               AwsCredentials.detect(%{})

      assert {:error, message} = AwsCredentials.detect(%{"AWS_EC2_METADATA_DISABLED" => "TRUE"})
      assert message =~ "no AWS credentials"
    end
  end

  describe "the chain order" do
    @sources [
      {"env", %{"AWS_ACCESS_KEY_ID" => "A", "AWS_SECRET_ACCESS_KEY" => "S"}},
      {"web identity", %{"AWS_WEB_IDENTITY_TOKEN_FILE" => "/t", "AWS_ROLE_ARN" => "arn"}},
      {"profile p", %{"AWS_PROFILE" => "p"}},
      {"container credentials", %{"AWS_CONTAINER_CREDENTIALS_FULL_URI" => "http://h/c"}}
    ]
    @profile "[p]\naws_access_key_id = A\naws_secret_access_key = S\n"

    property "the first configured source supplies the credentials" do
      check all(on <- list_of(boolean(), length: 4)) do
        configured = for {{label, vars}, true} <- Enum.zip(@sources, on), do: {label, vars}

        config =
          Enum.reduce(configured, %{"AWS_SHARED_CREDENTIALS_FILE" => "/c", "AWS_CONFIG_FILE" => "/n"}, fn {_, vars},
                                                                                                          acc ->
            Map.merge(acc, vars)
          end)

        # A named profile makes the shared files "configured"; otherwise they are absent.
        opts = [read_file: files(%{"/c" => @profile, "/n" => ""})]
        expected = with [{label, _} | _] <- configured, do: label, else: (_ -> "EC2 metadata")

        assert {:ok, %{source: ^expected}} = AwsCredentials.detect(config, opts)
      end
    end
  end

  describe "web identity" do
    test "assumes the role with an unsigned request and reads the token file each time" do
      dir = Path.join(System.tmp_dir!(), "aws-web-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      token_file = Path.join(dir, "token")
      File.write!(token_file, @web_token <> "\n")

      {base, agent} = fake(fn conn, _ -> Plug.Conn.send_resp(conn, 200, sts_xml("AKSTS1", 120)) end)

      provider =
        {:web_identity,
         %{token_file: token_file, role_arn: "arn:aws:iam::1:role/r", session_name: "sess", endpoint: base}}

      {:ok, pid} = AwsCredentials.start_link(provider, name: nil, source: "web identity")

      assert_receive {:hit, "POST", "/", headers, body}
      form = URI.decode_query(body)
      assert form["Action"] == "AssumeRoleWithWebIdentity"
      assert form["RoleArn"] == "arn:aws:iam::1:role/r"
      assert form["RoleSessionName"] == "sess"
      assert form["WebIdentityToken"] == @web_token
      refute List.keymember?(headers, "authorization", 0)

      File.write!(token_file, "rotated-token")
      Agent.update(agent, fn _ -> fn conn, _ -> Plug.Conn.send_resp(conn, 200, sts_xml("AKSTS2", 120)) end end)
      assert {"AKSTS2", _, _, _} = AwsCredentials.credentials(pid)
      assert_receive {:hit, "POST", "/", _, body}
      assert URI.decode_query(body)["WebIdentityToken"] == "rotated-token"
    end

    test "a refused assumption stops the holder with the STS error code" do
      {base, _} =
        fake(fn conn, _ ->
          Plug.Conn.send_resp(conn, 403, "<ErrorResponse><Error><Code>AccessDenied</Code></Error></ErrorResponse>")
        end)

      file = Path.join(System.tmp_dir!(), "aws-web-#{System.unique_integer([:positive])}")
      File.write!(file, @web_token)
      on_exit(fn -> File.rm(file) end)
      provider = {:web_identity, %{token_file: file, role_arn: "arn", session_name: "s", endpoint: base}}

      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          assert {:error, {{:aws_credentials, "web identity", {:sts, 403, "AccessDenied"}}, _}} =
                   start_supervised({AwsCredentials, {provider, name: nil, source: "web identity"}})
        end)

      refute log =~ @web_token
    end
  end

  describe "container credentials" do
    test "the authorization token is inline or read from its file again each time" do
      {base, _} = fake(fn conn, _ -> Plug.Conn.send_resp(conn, 200, creds_json("AKC", 600)) end)

      assert {:ok, %{provider: provider}} =
               AwsCredentials.detect(
                 %{
                   "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" => "/v2/c",
                   "AWS_CONTAINER_AUTHORIZATION_TOKEN" => "inline-token"
                 },
                 ecs_endpoint: base
               )

      {:ok, pid} = AwsCredentials.start_link(provider, name: nil)
      assert_receive {:hit, "GET", "/v2/c", headers, _}
      assert {"authorization", "inline-token"} in headers
      assert {"AKC", @secret, @token, _} = AwsCredentials.credentials(pid)

      file = Path.join(System.tmp_dir!(), "aws-pod-#{System.unique_integer([:positive])}")
      File.write!(file, "pod-1\n")
      on_exit(fn -> File.rm(file) end)
      file_provider = {:container, %{url: base <> "/pod", token: {:file, file}}}
      {:ok, pid2} = AwsCredentials.start_link(file_provider, name: nil, margin_ms: 700_000)
      assert_receive {:hit, "GET", "/pod", h1, _}
      assert {"authorization", "pod-1"} in h1

      File.write!(file, "pod-2")
      AwsCredentials.credentials(pid2)
      assert_receive {:hit, "GET", "/pod", h2, _}
      assert {"authorization", "pod-2"} in h2
    end
  end

  describe "EC2 metadata (IMDSv2)" do
    test "a token PUT, then the role name, then the credentials with the token" do
      {base, _} =
        fake(fn conn, _ ->
          case {conn.method, conn.request_path} do
            {"PUT", "/latest/api/token"} ->
              Plug.Conn.send_resp(conn, 200, "imds-token")

            {"GET", "/latest/meta-data/iam/security-credentials/"} ->
              Plug.Conn.send_resp(conn, 200, "my-role\n")

            {"GET", "/latest/meta-data/iam/security-credentials/my-role"} ->
              Plug.Conn.send_resp(conn, 200, creds_json("AKIMDS", 3600))
          end
        end)

      assert {:ok, %{source: "EC2 metadata", provider: provider}} =
               AwsCredentials.detect(%{"AWS_EC2_METADATA_SERVICE_ENDPOINT" => base})

      {:ok, pid} = AwsCredentials.start_link(provider, name: nil)

      assert_receive {:hit, "PUT", "/latest/api/token", put_headers, _}
      assert {"x-aws-ec2-metadata-token-ttl-seconds", "21600"} in put_headers
      assert_receive {:hit, "GET", "/latest/meta-data/iam/security-credentials/", h1, _}
      assert {"x-aws-ec2-metadata-token", "imds-token"} in h1
      assert_receive {:hit, "GET", "/latest/meta-data/iam/security-credentials/my-role", h2, _}
      assert {"x-aws-ec2-metadata-token", "imds-token"} in h2
      assert {"AKIMDS", @secret, @token, _} = AwsCredentials.credentials(pid)
    end

    test "an unreachable endpoint fails within a short time" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      :gen_tcp.close(listener)

      started = System.monotonic_time(:millisecond)
      Process.flag(:trap_exit, true)
      provider = {:imds, %{endpoint: "http://127.0.0.1:#{port}"}}
      assert {:error, _} = start_supervised({AwsCredentials, {provider, name: nil}})
      assert System.monotonic_time(:millisecond) - started < 3_000
    end
  end

  describe "refresh" do
    test "credentials with more than the margin left are cached; with less they are fetched again" do
      {pid, _agent, _} = holder("/c", "AKLONG", 6 * 60)
      assert hits() == 1
      for _ <- 1..3, do: assert({"AKLONG", _, _, _} = AwsCredentials.credentials(pid))
      assert hits() == 0

      {pid, _agent, _} = holder("/c", "AKSHORT", 4 * 60)
      assert hits() == 1
      assert {"AKSHORT", _, _, _} = AwsCredentials.credentials(pid)
      assert hits() == 1
    end

    test "the new keys replace the old ones" do
      {pid, agent, _} = holder("/c", "AKOLD", 4 * 60)
      Agent.update(agent, fn _ -> container_handler(fn -> creds_json("AKNEW", 3600) end) end)
      assert {"AKNEW", _, _, _} = AwsCredentials.credentials(pid)
      assert {"AKNEW", _, _, _} = AwsCredentials.credentials(pid)
      assert hits() == 2
    end

    test "concurrent callers share one refresh" do
      {pid, agent, _} = holder("/c", "AKOLD", 4 * 60)
      assert hits() == 1

      Agent.update(agent, fn _ ->
        fn conn, _ ->
          Process.sleep(300)
          Plug.Conn.send_resp(conn, 200, creds_json("AKNEW", 3600))
        end
      end)

      results =
        1..25
        |> Task.async_stream(fn _ -> AwsCredentials.credentials(pid) end, max_concurrency: 25)
        |> Enum.map(&elem(&1, 1))

      assert Enum.all?(results, &match?({"AKNEW", _, _, _}, &1))
      assert hits() == 1
    end

    test "a failed refresh keeps the old keys, logs a warning and waits before trying again" do
      {pid, agent, _} = holder("/c", "AKOLD", 4 * 60)
      assert hits() == 1
      Agent.update(agent, fn _ -> fn conn, _ -> Plug.Conn.send_resp(conn, 500, "boom #{@secret} #{@token}") end end)

      log =
        capture_log(fn ->
          assert {"AKOLD", @secret, @token, _} = AwsCredentials.credentials(pid)
          assert {"AKOLD", @secret, @token, _} = AwsCredentials.credentials(pid)
        end)

      assert hits() == 1
      assert log =~ "refreshing the AWS credentials (container credentials) failed"
      assert log =~ "keeping the current ones"
      for value <- [@secret, @token, "AKOLD"], do: refute(log =~ value)
    end

    test "expired keys and a failed refresh are an error" do
      {pid, agent, _} = holder("/c", "AKOLD", 1)
      Agent.update(agent, fn _ -> fn conn, _ -> Plug.Conn.send_resp(conn, 500, "") end end)
      Process.sleep(1_100)
      log = capture_log(fn -> assert {:error, {:http, 500}} = AwsCredentials.credentials(pid) end)
      refute log =~ @secret
    end

    test "a holder that is gone answers an error" do
      assert {:error, :credentials_unavailable} = AwsCredentials.credentials(:no_such_aws_holder)
    end
  end

  describe "the daemon hands Alambique the renewable function" do
    test "the S3 store signs with the temporary keys and sends the token" do
      {base, _} = fake(fn conn, _ -> Plug.Conn.send_resp(conn, 200, creds_json("AKDAEMON", 3600)) end)

      env = %{
        "ATANOR_STORE" => "s3://bucket/p",
        "ATANOR_DATA_DIR" => System.tmp_dir!(),
        "AWS_CONTAINER_CREDENTIALS_FULL_URI" => base <> "/creds",
        "AWS_REGION" => "eu-west-1"
      }

      assert {:ok, %{opts: opts, children: [child], effective: effective}} = Daemon.load(env)
      assert {"credentials", "container credentials"} in effective
      assert {Alambique.Store.S3, %{credentials: fun, region: "eu-west-1"} = config} = opts[:store]
      assert is_function(fun, 0)
      refute Map.has_key?(config, :access_key_id)

      start_supervised!(child)
      assert {"AKDAEMON", _, _, _} = fun.()

      {s3, _} = fake(fn conn, _ -> Plug.Conn.send_resp(conn, 200, "") end)
      store = %{config | region: "eu-west-1"} |> Map.put(:endpoint, s3)
      assert {:ok, _, _} = Alambique.Store.S3.head(store, "k")

      assert_receive {:hit, "HEAD", "/bucket/k", headers, _}
      assert {"x-amz-security-token", @token} in headers

      assert Enum.any?(headers, fn {k, v} ->
               k == "authorization" and v =~ "Credential=AKDAEMON/" and v =~ "/eu-west-1/s3/"
             end)
    end
  end
end
