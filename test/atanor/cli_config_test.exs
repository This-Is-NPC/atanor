defmodule Atanor.CLIConfigTest do
  use ExUnit.Case, async: true

  alias Atanor.CLI.Config

  @moduletag :tmp_dir

  test "the path follows XDG_CONFIG_HOME, then HOME, and fails when neither is set" do
    assert {:ok, "/x/atanor/config.json"} = Config.path(%{"XDG_CONFIG_HOME" => "/x", "HOME" => "/h"})
    assert {:ok, "/h/.config/atanor/config.json"} = Config.path(%{"HOME" => "/h"})
    assert {:ok, "/h/.config/atanor/config.json"} = Config.path(%{"XDG_CONFIG_HOME" => "", "HOME" => "/h"})
    assert {:error, "cannot find the config directory" <> _} = Config.path(%{"XDG_CONFIG_HOME" => "", "HOME" => ""})
    assert {:error, _} = Config.path(%{})
  end

  test "profiles are stored with a private mode, replaced and deleted", %{tmp_dir: dir} do
    path = Path.join([dir, "cfg", "config.json"])
    assert {:ok, %{}} = Config.profiles(path)
    assert :absent = Config.delete(path, "a")

    assert :ok = Config.put(path, "a", "http://a", "t1")
    assert :ok = Config.put(path, "b", "http://b", "t2")
    assert :ok = Config.put(path, "a", "http://a2", "t3")

    assert {:ok, %{"a" => %{"url" => "http://a2", "token" => "t3"}, "b" => %{"url" => "http://b", "token" => "t2"}}} =
             Config.profiles(path)

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700

    assert :ok = Config.delete(path, "a")
    assert {:ok, %{"b" => _} = profiles} = Config.profiles(path)
    refute Map.has_key?(profiles, "a")
    assert Path.wildcard(path <> ".*") == []
  end

  test "a file that is not a profiles file, or cannot be read or written, is an error", %{tmp_dir: dir} do
    bad = Path.join(dir, "bad.json")

    for body <- ["not json", "[]", ~s({"profiles": []}), "{}"] do
      File.write!(bad, body)
      assert {:error, message} = Config.profiles(bad)
      assert message == "#{bad} is not a profiles file"
      assert {:error, ^message} = Config.put(bad, "a", "u", "t")
      assert {:error, ^message} = Config.delete(bad, "a")
    end

    assert {:error, "cannot read " <> rest} = Config.profiles(dir)
    assert rest =~ dir

    locked = Path.join(dir, "locked")
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)
    assert {:error, "cannot write " <> _} = Config.put(Path.join([locked, "sub", "config.json"]), "a", "u", "t")
  end
end
