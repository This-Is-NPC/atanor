defmodule Atanor.DaemonPropertyTest do
  @moduledoc "Rules of the daemon configuration that hold for any input: strictness, precedence, secrets."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Daemon

  @secret_vars ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]

  defp base,
    do: %{
      "ATANOR_STORE" => "s3://bucket/p",
      "AWS_ACCESS_KEY_ID" => "AKIAEXAMPLE",
      "AWS_SECRET_ACCESS_KEY" => "secret",
      "ATANOR_DATA_DIR" => System.tmp_dir!()
    }

  defp unknown_suffix do
    gen all(name <- string([?A..?Z, ?_], min_length: 1, max_length: 12)) do
      "ATANOR_" <> name
    end
    |> filter(&(&1 not in Daemon.known_variables() and &1 not in Daemon.cli_variables()))
  end

  property "an unknown ATANOR_ variable always fails and is named" do
    check all(name <- unknown_suffix(), value <- string(:alphanumeric)) do
      assert {:error, messages} = Daemon.load(Map.put(base(), name, value))
      assert Enum.any?(messages, &String.contains?(&1, "variable " <> name))
    end
  end

  property "an unknown key of the file always fails" do
    check all(key <- string([?a..?z, ?_], min_length: 1, max_length: 12), value <- string(:alphanumeric)) do
      known = for name <- Daemon.known_variables(), do: String.downcase(String.replace_prefix(name, "ATANOR_", ""))
      check_unknown = key not in known

      if check_unknown do
        assert {:error, [message]} = Daemon.load(base(), Jason.encode!(%{key => value}))
        assert message =~ inspect(key)
      end
    end
  end

  property "the environment overrides the file, key by key" do
    check all(
            file_port <- integer(1..65_535),
            env_port <- integer(1..65_535),
            release <- string(:alphanumeric, min_length: 1)
          ) do
      file = Jason.encode!(%{"listen" => "127.0.0.1:#{file_port}", "release" => release})
      env = Map.put(base(), "ATANOR_LISTEN", "127.0.0.1:#{env_port}")
      assert {:ok, %{opts: opts}} = Daemon.load(env, file)
      assert opts[:port] == env_port
      assert opts[:release][:id] == release
    end
  end

  property "a *_FILE variant is equivalent to the inline value" do
    check all(
            secret <- string(:alphanumeric, min_length: 1),
            var <- member_of(@secret_vars),
            newline <- member_of(["", "\n"])
          ) do
      inline = Map.put(base(), var, secret)
      from_file = base() |> Map.delete(var) |> Map.put(var <> "_FILE", "/secret")
      read = fn "/secret" -> {:ok, secret <> newline} end

      assert Daemon.load(inline) == Daemon.load(from_file, nil, read_file: read)
    end
  end

  property "no secret is in the log line" do
    check all(
            key_id <- string(:alphanumeric, min_length: 12),
            secret <- string(:alphanumeric, min_length: 12),
            token <- string(:alphanumeric, min_length: 32)
          ) do
      env =
        Map.merge(base(), %{
          "AWS_ACCESS_KEY_ID" => key_id,
          "AWS_SECRET_ACCESS_KEY" => secret,
          "ATANOR_ADMIN_TOKEN" => token
        })

      assert {:ok, settings} = Daemon.load(env)
      line = Daemon.describe(settings)

      for value <- [key_id, secret, token], do: refute(String.contains?(line, value))
    end
  end
end
