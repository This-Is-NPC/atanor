defmodule Atanor.DaemonChildrenTest do
  use ExUnit.Case, async: true

  alias Atanor.Daemon

  @env %{
    "ATANOR_STORE" => "s3://bucket/prefix",
    "AWS_ACCESS_KEY_ID" => "AKIAEXAMPLE",
    "AWS_SECRET_ACCESS_KEY" => "secret",
    "ATANOR_DATA_DIR" => System.tmp_dir!()
  }

  test "the node is the instance, named by instance/0, with the options of the settings" do
    {:ok, settings} = Daemon.load(@env)

    assert [{Atanor, opts}] = Daemon.children(settings)
    assert opts[:name] == Daemon.instance()
    assert opts[:prefix] == "prefix"
  end

  test "the processes that hold renewable credentials come first" do
    marker = %{id: :credentials, start: {Agent, :start_link, [fn -> 1 end]}}
    {:ok, settings} = Daemon.load(@env)

    assert [^marker, {Atanor, _}] = Daemon.children(%{settings | children: [marker]})
  end
end
