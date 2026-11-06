defmodule Atanor.CLITest do
  use ExUnit.Case, async: true

  import Atanor.Test.Await

  alias Atanor.CLI
  alias Atanor.CLI.Client
  alias Atanor.Test.{Manifests, ProbeWorker}
  alias AtanorTestkit.Node

  @moduletag :tmp_dir
  @operator "operator-secret"
  @route [{"127.0.0.1", "/"}]

  # A node with the admin API, and a context that only sees temporary directories.
  setup %{tmp_dir: dir} do
    node = Node.start(admin: [token: @operator, port: 0])
    on_exit(fn -> Node.stop(node) end)
    project = Path.join(dir, "project")
    File.mkdir_p!(project)

    env = %{"HOME" => Path.join(dir, "home"), "XDG_CONFIG_HOME" => Path.join(dir, "config")}
    {:ok, node: node, project: project, env: env, admin: "http://127.0.0.1:#{Atanor.admin_port(node.name)}"}
  end

  defp ctx(env, project, stdin \\ :eof), do: %{env: env, cwd: project, stdin: fn _prompt -> stdin end}

  defp cli(context, argv, extra_env \\ %{}) do
    CLI.run(argv, %{context | env: Map.merge(context.env, extra_env)})
  end

  defp ok!(result) do
    assert {0, out, ""} = result
    out
  end

  defp manifest!(project, n, name \\ "w") do
    manifest = Manifests.probe(name, routes: @route, limits: %{"timeout_ms" => n})
    File.write!(Path.join(project, "atanor.json"), Jason.encode!(manifest))
  end

  defp ebin, do: ["--ebin", ProbeWorker |> :code.which() |> to_string() |> Path.dirname()]

  defp serving(node), do: Req.get!(node.url <> "/echo", retry: false).body["deployment"]
  defp package_id(out), do: Regex.run(~r/^package ([0-9a-f]{64}) /m, out) |> List.last()

  defp login!(context, profile, admin, token) do
    out = ok!(cli(%{context | stdin: fn _ -> token <> "\n" end}, ["login", "--url", admin, "--profile", profile]))
    refute out =~ token
    out
  end

  test "login, deploy, activate, call, roll back and read the status through a scoped token",
       %{
         node: node,
         project: project,
         env: env,
         admin: admin
       } do
    context = ctx(env, project)
    config = Path.join([env["XDG_CONFIG_HOME"], "atanor", "config.json"])

    # The operator logs in and creates a token for one worker.
    out = login!(context, "ops", admin, @operator)
    assert out =~ "logged in to #{admin} (profile ops)"
    assert %File.Stat{mode: mode} = File.stat!(config)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert File.read!(config) =~ @operator

    out =
      ok!(
        cli(context, [
          "--profile",
          "ops",
          "token",
          "create",
          "ci",
          "--scope",
          "worker:w:deploy",
          "--scope",
          "worker:w:activate",
          "--scope",
          "worker:w:rollback",
          "--scope",
          "worker:w:read"
        ])
      )

    [_, id, secret] = Regex.run(~r/^secret: (atn_[0-9a-f]+)_(\S+)$/m, out)
    login!(context, "ci", admin, "#{id}_#{secret}")
    assert ok!(cli(context, ["--profile", "ops", "token", "list"])) =~ "#{id}  active   ci"

    # Deploy v1 with --activate.
    manifest!(project, 1)
    out = ok!(cli(context, ["--profile", "ci", "deploy", "--activate"] ++ ebin()))
    v1 = package_id(out)
    assert out =~ "(w, native, "
    assert out =~ "w: active #{v1}, revision 1, previous none"
    assert until(fn -> serving(node) == v1 end)

    # Deploy v2 without activating: what runs does not change.
    manifest!(project, 2)
    v2 = package_id(ok!(cli(context, ["--profile", "ci", "deploy"] ++ ebin())))
    assert v2 != v1
    assert serving(node) == v1

    out = ok!(cli(context, ["--profile", "ci", "versions", "w"]))
    assert out =~ "w: active #{v1}"
    assert out =~ ~r/#{v1}  active\s+native  \d+ bytes .* by token ci \(#{id}\)/
    assert out =~ ~r/#{v2}  -\s+native/
    assert out =~ "oldest first"

    # Paging.
    out = ok!(cli(context, ["--profile", "ci", "versions", "w", "--limit", "1"]))
    assert [_, cursor] = Regex.run(~r/--after (\S+)/, out)
    refute ok!(cli(context, ["--profile", "ci", "versions", "w", "--after", cursor])) =~ v1 <> "  "

    out = ok!(cli(context, ["--profile", "ci", "activate", "w", v2]))
    assert out == "w: active #{v2}, revision 2, previous #{v1}\n"
    assert until(fn -> serving(node) == v2 end)

    out = ok!(cli(context, ["--profile", "ci", "rollback", "w"]))
    assert out == "w: active #{v1}, revision 3, previous none\n"
    assert until(fn -> serving(node) == v1 end)

    assert {1, "", err} = cli(context, ["--profile", "ci", "rollback", "w"])
    assert err == "atanor: the worker has no previous package to return to\n"

    out = ok!(cli(context, ["--profile", "ci", "status"]))
    assert out == "w: active #{v1}, revision 3, previous none\n"
    out = ok!(cli(context, ["--profile", "ci", "status", "w"]))
    assert out =~ "w: active #{v1}, revision 3"
    assert out =~ "applied by #{node()}: #{v1}"

    assert {1, "", err} = cli(context, ["--profile", "ci", "activate", "w", String.duplicate("a", 64)])
    assert err =~ "the package is not stored; deploy it first"

    # The token cannot manage tokens, and the operator revokes it.
    assert {1, "", err} = cli(context, ["--profile", "ci", "token", "list"])
    assert err =~ "forbidden: this token needs the scope cluster:admin"
    assert ok!(cli(context, ["--profile", "ops", "token", "revoke", id])) =~ "revoked #{id} (ci)"
    assert {1, "", err} = cli(context, ["--profile", "ci", "status"])
    assert err =~ "the server did not accept the token"
    assert err =~ "atanor login"
    refute err =~ secret

    # Logout removes the profile and nothing else.
    assert ok!(cli(context, ["--profile", "ci", "logout"])) =~ "logged out (profile ci)"
    assert ok!(cli(context, ["--profile", "ci", "logout"])) =~ "was not logged in"
    assert %{"profiles" => profiles} = config |> File.read!() |> Jason.decode!()
    assert Map.keys(profiles) == ["ops"]
  end

  test "a token scoped to another worker gets a clean 403", %{project: project, env: env, admin: admin} do
    context = ctx(env, project)
    login!(context, "ops", admin, @operator)

    out = ok!(cli(context, ["--profile", "ops", "token", "create", "other", "--scope", "worker:other:deploy"]))
    [token] = Regex.run(~r/^secret: (\S+)$/m, out, capture: :all_but_first)

    manifest!(project, 1)
    before = File.ls!(env["XDG_CONFIG_HOME"])

    assert {1, "", err} = cli(context, ["deploy"] ++ ebin(), %{"ATANOR_URL" => admin, "ATANOR_TOKEN" => token})
    assert err == "atanor: forbidden: this token needs the scope worker:w:deploy\n"

    assert {1, "", err} =
             cli(context, ["status", "w"], %{"ATANOR_URL" => admin, "ATANOR_TOKEN" => token})

    assert err =~ "worker:w:read"
    assert File.ls!(env["XDG_CONFIG_HOME"]) == before

    # Uploading with --activate also needs the activate scope.
    out = ok!(cli(context, ["--profile", "ops", "token", "create", "up", "--scope", "worker:w:deploy"]))
    [up] = Regex.run(~r/^secret: (\S+)$/m, out, capture: :all_but_first)

    assert {1, "", err} =
             cli(context, ["deploy", "--activate"] ++ ebin(), %{"ATANOR_URL" => admin, "ATANOR_TOKEN" => up})

    assert err =~ "worker:w:activate"
  end

  test "the environment replaces the profile and the profile is chosen by ATANOR_PROFILE", %{
    project: project,
    env: env,
    admin: admin
  } do
    context = ctx(env, project)
    assert {1, "", err} = cli(context, ["status"])
    assert err =~ "not logged in (profile default)"

    # URL and token from the environment alone, no file written.
    assert ok!(cli(context, ["status"], %{"ATANOR_URL" => admin <> "/", "ATANOR_TOKEN" => @operator})) == "no workers\n"
    refute File.exists?(env["XDG_CONFIG_HOME"])

    login!(context, "named", admin, @operator)
    assert {1, "", _} = cli(context, ["status"])
    assert ok!(cli(context, ["status"], %{"ATANOR_PROFILE" => "named"})) == "no workers\n"
    assert ok!(cli(context, ["--profile", "named", "status"], %{"ATANOR_PROFILE" => "other"})) == "no workers\n"

    # A wrong token is not stored.
    assert {1, "", err} = cli(%{context | stdin: fn _ -> "wrong\n" end}, ["login", "--url", admin, "--profile", "bad"])
    assert err =~ "did not accept the token"

    assert %{"profiles" => %{"named" => _} = profiles} =
             Path.join([env["XDG_CONFIG_HOME"], "atanor", "config.json"]) |> File.read!() |> Jason.decode!()

    refute Map.has_key?(profiles, "bad")
  end

  test "failures are messages with exit codes", %{project: project, env: env, admin: admin} do
    context = ctx(env, project)
    auth = %{"ATANOR_URL" => admin, "ATANOR_TOKEN" => @operator}

    assert {2, "", err} = cli(context, ["frobnicate"])
    assert err =~ "unknown command \"frobnicate\""
    assert {2, "", err} = cli(context, ["activate", "w"], auth)
    assert err =~ "usage: atanor activate WORKER PACKAGE_ID"
    assert {2, "", err} = cli(context, ["status", "--bogus"], auth)
    assert err =~ "invalid option --bogus for status"
    assert {2, "", err} = cli(context, ["status"], Map.put(auth, "ATANOR_TIMEOUT", "soon"))
    assert err =~ "ATANOR_TIMEOUT must be a positive number of seconds"
    assert {2, "", _} = cli(context, ["login", "--url", admin])
    assert {1, "", err} = cli(context, ["status"], %{"ATANOR_URL" => "ftp://x", "ATANOR_TOKEN" => "t"})
    assert err =~ "must start with http:// or https://"

    assert {1, "", err} = cli(context, ["deploy"], auth)
    assert err =~ "cannot read manifest"

    File.write!(Path.join(project, "atanor.json"), ~s({"name": "w"}))
    assert {1, "", err} = cli(context, ["deploy"], auth)
    assert err =~ "invalid manifest at manifest_version: is required"

    manifest!(project, 1)
    assert {1, "", err} = cli(context, ["deploy"], auth)
    assert err =~ "Elixir.Atanor.Test.ProbeWorker.beam not found"

    assert {1, "", err} = cli(context, ["status", "nope"], auth)
    assert err == "atanor: not found\n"
    assert {1, "", err} = cli(context, ["token", "create", "x", "--scope", "bogus"], auth)
    assert err =~ "the server answered 400 invalid_token: "

    assert {0, out, ""} = cli(context, ["help", "token", "create"])
    assert out =~ "--scope SCOPE"
    assert {0, "atanor " <> _, ""} = cli(context, ["--version"])
  end

  test "a package larger than the node accepts is a 413 message", %{project: project, env: env} do
    node = Node.start(admin: [token: @operator, port: 0, max_package_bytes: 100])
    on_exit(fn -> Node.stop(node) end)
    manifest!(project, 1)
    auth = %{"ATANOR_URL" => "http://127.0.0.1:#{Atanor.admin_port(node.name)}", "ATANOR_TOKEN" => @operator}

    assert {1, "", err} = cli(ctx(env, project), ["deploy"] ++ ebin(), auth)
    assert err == "atanor: the package is larger than the server accepts (100 bytes, the admin max_package_bytes)\n"
  end

  test "timeouts: an unreachable node and a node that does not answer", %{project: project, env: env} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    context = ctx(env, project)
    url = "http://127.0.0.1:#{port}"

    # The socket accepts connections (the backlog) and nobody answers.
    assert {1, "", err} =
             cli(context, ["status", "--timeout", "0.2"], %{"ATANOR_URL" => url, "ATANOR_TOKEN" => "t"})

    assert err =~ "no answer from #{url} in time"

    assert {1, "", err} =
             cli(context, ["status"], %{"ATANOR_URL" => url, "ATANOR_TOKEN" => "t", "ATANOR_TIMEOUT" => "0.2"})

    assert err =~ "no answer"

    :gen_tcp.close(listener)

    assert {1, "", err} = cli(context, ["status"], %{"ATANOR_URL" => url, "ATANOR_TOKEN" => "t"})
    assert err =~ "cannot reach #{url}: econnrefused"
  end

  test "plain http warns unless the host is loopback" do
    assert CLI.plain_remote?("http://admin.example.com")
    refute CLI.plain_remote?("https://admin.example.com")
    refute CLI.plain_remote?("http://127.0.0.1:5010")
    refute CLI.plain_remote?("http://localhost:5010")
  end

  test "login refuses plain http to a remote host before sending the token", %{project: project, env: env} do
    context = %{ctx(env, project) | stdin: fn _ -> "secret\n" end}
    slow = %{"ATANOR_CONNECT_TIMEOUT" => "1", "ATANOR_TIMEOUT" => "1"}

    assert {2, "", err} = cli(context, ["login", "--url", "http://192.0.2.1:1"], slow)
    assert err =~ "--insecure"
    refute File.exists?(Path.join([env["XDG_CONFIG_HOME"], "atanor", "config.json"]))

    # Asked for, it tries (and fails to reach the address, which is not a node).
    assert {1, "", err} = cli(context, ["login", "--url", "http://192.0.2.1:1", "--insecure"], slow)
    assert err =~ ~r/no answer|cannot reach/
  end

  test "another URL does not get the token of a profile", %{project: project, env: env, admin: admin} do
    context = ctx(env, project)
    login!(context, "default", admin, @operator)

    assert {2, "", err} = cli(context, ["status"], %{"ATANOR_URL" => "http://192.0.2.1:1"})
    assert err =~ "ATANOR_TOKEN"

    # The URL of the profile, or a token given with the URL, is fine.
    assert ok!(cli(context, ["status"], %{"ATANOR_URL" => admin})) == "no workers\n"

    assert {1, "", err} =
             cli(context, ["status"], %{
               "ATANOR_URL" => "http://192.0.2.1:1",
               "ATANOR_TOKEN" => "t",
               "ATANOR_CONNECT_TIMEOUT" => "1",
               "ATANOR_TIMEOUT" => "1"
             })

    assert err =~ ~r/no answer|cannot reach/
  end

  test "failure messages by status" do
    assert Client.failure(503, %{"error" => "not_ready", "reason" => "starting"}) =~
             "the server cannot do that now (not_ready: starting)"

    assert Client.failure(422, %{"error" => "invalid_package", "reason" => "bad_magic"}) =~ "bad_magic"
    assert Client.failure(422, %{"error" => "hash_mismatch"}) =~ "hash_mismatch"
    assert Client.failure(422, %{"error" => "package_of_other_worker", "package_worker" => "x"}) =~ "worker x"
    assert Client.failure(409, %{"error" => "conflict"}) =~ "run the command again"
    assert Client.failure(500, %{}) == "the server answered 500"
  end

  test "docs/cli.md documents every command, option and environment variable" do
    docs = File.read!("docs/cli.md")

    for command <- CLI.commands() do
      assert docs =~ "atanor #{command.name}", "docs/cli.md lacks the command #{command.name}"

      for option <- command.options ++ CLI.global_options() do
        flag = "--" <> (option.flag |> Atom.to_string() |> String.replace("_", "-"))
        assert docs =~ flag, "docs/cli.md lacks #{flag}"
      end
    end

    for {var, _} <- CLI.env_vars(), do: assert(docs =~ var, "docs/cli.md lacks #{var}")
  end
end
