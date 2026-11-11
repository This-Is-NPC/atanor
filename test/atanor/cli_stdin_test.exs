defmodule Atanor.CLIStdinTest do
  use ExUnit.Case, async: true

  # `CLI.read_line/1` runs in a fresh VM, as `atanor login` does: once with a
  # pseudo-terminal (through `script`) and once with a pipe.
  @moduletag :cli_stdin

  @secret "s3cr3t-token"

  # Prints READY once the terminal has the echo off, then the length of what was read.
  @program """
  spawn(fn -> Process.sleep(20_000) && System.halt(1) end)
  task = Task.async(fn -> Atanor.CLI.read_line("Token: ") end)

  echo_off? = fn ->
    {flags, _} = System.cmd("stty", ["-a", "-F", "/proc/\#{:os.getpid()}/fd/0"], stderr_to_stdout: true)
    flags =~ ~r/\s-echo\s/
  end

  wait = fn wait -> if echo_off?.(), do: :ok, else: (Process.sleep(20); wait.(wait)) end
  wait.(wait)
  IO.puts("READY")
  IO.puts("LEN:" <> to_string(byte_size(Task.await(task))))
  """

  defp command(program) do
    path = Path.join(System.tmp_dir!(), "atanor-stdin-#{System.unique_integer([:positive])}.exs")
    File.write!(path, program)
    on_exit(fn -> File.rm(path) end)
    "elixir -pa #{Mix.Project.compile_path()} #{path}"
  end

  defp collect(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    after
      30_000 -> flunk("the terminal program did not end; got #{inspect(acc)}")
    end
  end

  defp await_output(port, marker, acc \\ "") do
    if acc =~ marker do
      acc
    else
      receive do
        {^port, {:data, data}} -> await_output(port, marker, acc <> data)
      after
        30_000 -> flunk("no #{inspect(marker)}; got #{inspect(acc)}")
      end
    end
  end

  @tag skip:
         not (is_binary(System.find_executable("script")) and File.dir?("/proc/self")) && "needs script(1) and /proc"
  test "at a terminal the token is read with the echo off" do
    # script(1) may start the terminal with the echo off; make it on, as a login shell has it.
    args = ["-qefc", "stty echo && " <> command(@program), "-E", "never", "/dev/null"]
    port = Port.open({:spawn_executable, System.find_executable("script")}, [:binary, :exit_status, args: args])

    before_input = await_output(port, "READY")
    Port.command(port, @secret <> "\r")
    output = before_input <> collect(port)

    assert output =~ "Token: "
    assert output =~ "LEN:#{byte_size(@secret) + 1}"
    refute output =~ @secret
  end

  test "a pipe is read as it is, without a prompt" do
    program = ~s|IO.puts("GOT:" <> String.trim(Atanor.CLI.read_line("Token: ")))|
    {out, 0} = System.cmd("sh", ["-c", "printf '#{@secret}\\n' | " <> command(program)], stderr_to_stdout: true)
    assert out == "GOT:#{@secret}\n"
  end
end
