defmodule Atanor.Scripts.NodeEnvTest do
  @moduledoc "The start script of the node release (daemon/rel/env.sh.eex): name and cookie, before the VM boots."
  use ExUnit.Case, async: true

  @script Path.expand("../../daemon/rel/env.sh.eex", __DIR__)

  # Sources the script in a clean environment and prints the node, the distribution and the cookie.
  defp run(env) do
    System.cmd("sh", ["-c", ". #{@script} && echo \"$RELEASE_NODE $RELEASE_DISTRIBUTION $RELEASE_COOKIE\""],
      env: env,
      stderr_to_stdout: true
    )
    |> then(fn {out, status} -> {String.trim(out), status} end)
  end

  defp clean, do: [{"RELEASE_COOKIE", nil}, {"ATANOR_COOKIE_FILE", nil}, {"ATANOR_ADVERTISE", nil}]
  defp with_env(extra), do: Enum.reduce(extra, clean(), &List.keystore(&2, elem(&1, 0), 0, &1))

  @tag :tmp_dir
  test "the node is atanor@<advertise> with long names, and the cookie comes from the file", %{tmp_dir: dir} do
    file = Path.join(dir, "cookie")
    File.write!(file, "from-file\n")

    assert run(with_env([{"ATANOR_ADVERTISE", "10.0.0.7"}, {"ATANOR_COOKIE_FILE", file}])) ==
             {"atanor@10.0.0.7 name from-file", 0}
  end

  test "an inline cookie is used as it is" do
    assert run(with_env([{"ATANOR_ADVERTISE", "n1.example"}, {"RELEASE_COOKIE", "inline"}])) ==
             {"atanor@n1.example name inline", 0}
  end

  test "the node does not start without a cookie, and never uses the build's" do
    assert {message, 1} = run(with_env([{"ATANOR_ADVERTISE", "n1"}]))
    assert message =~ "no cookie"
  end

  @tag :tmp_dir
  test "both cookie forms, a missing file, a dash and a missing advertise refuse", %{tmp_dir: dir} do
    file = Path.join(dir, "cookie")
    File.write!(file, "x")
    advertise = {"ATANOR_ADVERTISE", "n1"}

    assert {message, 1} = run(with_env([advertise, {"RELEASE_COOKIE", "a"}, {"ATANOR_COOKIE_FILE", file}]))
    assert message =~ "both set"
    assert {message, 1} = run(with_env([advertise, {"ATANOR_COOKIE_FILE", Path.join(dir, "missing")}]))
    assert message =~ "cannot read"
    assert {message, 1} = run(with_env([advertise, {"RELEASE_COOKIE", "-dash"}]))
    assert message =~ "must not start with"
    assert {message, 1} = run(with_env([{"RELEASE_COOKIE", "a"}]))
    assert message =~ "ATANOR_ADVERTISE is required"
  end

  test "`eval` needs neither an advertise address nor a cookie: the CLI runs through it" do
    # The release's script sets RELEASE_COMMAND before it sources env.sh; nothing else is exported.
    script = ". #{@script} && echo \"ran node=${RELEASE_NODE:-none} dist=${RELEASE_DISTRIBUTION:-none}\""

    assert {"ran node=none dist=none", 0} = eval_in(script, "eval")
    assert {message, 1} = eval_in(script, "start")
    assert message =~ "ATANOR_ADVERTISE is required"
  end

  defp eval_in(script, command) do
    {out, status} =
      System.cmd("sh", ["-c", script], env: with_env([{"RELEASE_COMMAND", command}]), stderr_to_stdout: true)

    {String.trim(out), status}
  end
end
