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

  # atanor_dio_flag reads /proc/self/cgroup (here a file) and <mount><path>/cpu.max (here a temp tree).
  defp dio_flag(dir, cgroup, cpu_max) do
    File.write!(Path.join(dir, "cgroup"), cgroup)
    File.mkdir_p!(Path.join(dir, "mount/pod"))
    if cpu_max, do: File.write!(Path.join(dir, "mount/pod/cpu.max"), cpu_max)

    {out, 0} =
      System.cmd("sh", ["-c", ". #{@script} && atanor_dio_flag #{dir}/cgroup #{dir}/mount"],
        env: with_env([{"RELEASE_COMMAND", "eval"}])
      )

    String.trim(out)
  end

  @tag :tmp_dir
  test "dirty IO follows the CPU quota, rounded up, at least 1", %{tmp_dir: dir} do
    in_pod = "0::/pod\n"

    assert dio_flag(dir, in_pod, "100000 100000\n") == "+SDio 1"
    assert dio_flag(dir, in_pod, "150000 100000\n") == "+SDio 2"
    assert dio_flag(dir, in_pod, "200000 100000\n") == "+SDio 2"
    assert dio_flag(dir, in_pod, "50000 100000\n") == "+SDio 1"
  end

  @tag :tmp_dir
  test "no quota, no file, no cgroup v2 or a bad file adds no flag", %{tmp_dir: dir} do
    assert dio_flag(dir, "0::/pod\n", "max 100000\n") == ""
    assert dio_flag(dir, "0::/pod\n", nil) == ""
    assert dio_flag(dir, "12:cpu:/pod\n", "100000 100000\n") == ""
    assert dio_flag(dir, "0::/pod\n", "100000 0\n") == ""
    assert dio_flag(dir, "0::/pod\n", "garbage\n") == ""
    assert dio_flag(dir, "0::/pod\n", "") == ""
  end

  test "the script keeps the distribution flags in ERL_AFLAGS" do
    script = ". #{@script} && echo \"$ERL_AFLAGS\""
    env = with_env([{"RELEASE_COMMAND", "start"}, {"ATANOR_ADVERTISE", "n1"}, {"RELEASE_COOKIE", "c"}])
    {out, 0} = System.cmd("sh", ["-c", script], env: env)
    assert out =~ "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9110 net_ticktime 60"
  end

  test "a +SDio of the operator in ERL_FLAGS or ERL_ZFLAGS wins over the one in ERL_AFLAGS" do
    dio = fn env ->
      {out, 0} =
        System.cmd(
          "erl",
          ["-noshell", "-eval", "io:format(\"~p\", [erlang:system_info(dirty_io_schedulers)]), halt()."],
          env: [{"ERL_AFLAGS", "+SDio 1"}, {"ERL_FLAGS", nil}, {"ERL_ZFLAGS", nil}] ++ env
        )

      out
    end

    assert dio.([]) == "1"
    assert dio.([{"ERL_FLAGS", "+SDio 3"}]) == "3"
    assert dio.([{"ERL_ZFLAGS", "+SDio 4"}]) == "4"
  end

  defp eval_in(script, command) do
    {out, status} =
      System.cmd("sh", ["-c", script], env: with_env([{"RELEASE_COMMAND", command}]), stderr_to_stdout: true)

    {String.trim(out), status}
  end
end
