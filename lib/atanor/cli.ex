defmodule Atanor.CLI do
  @moduledoc """
  The `atanor` command (design §5.4, docs/cli.md): a client of the admin API
  that logs in to a node, deploys, activates and rolls back workers, reads
  their status and manages scoped tokens. Only `deploy --bucket` touches the
  bucket: it publishes a WASM worker straight to the store, with the node's
  rules for the endpoint, the region and the AWS credentials
  (`Atanor.Daemon.store/3`), and needs no node.

  `main/1` is the escript entry point (`mise run build:cli`); the release runs
  it too (`bin/atanor-entrypoint`). `run/2` does the work for an argument list
  and a context and returns `{exit_code, stdout, stderr}`, so tests run it
  in-process with their own environment, working directory and standard input.
  The context is `%{env:, cwd:, stdin:}`, where `stdin` is a function from a
  prompt to a line (or `:eof`); `open_store:`, a function of the `--bucket` URL
  and the environment that returns `{:ok, store_handle, children}`, replaces the
  bucket for tests.

  Exit codes: 0 done, 1 failed, 2 wrong usage.
  """

  alias Atanor.CLI.{Client, Config}
  alias Atanor.Deployments.Service
  alias Atanor.{Daemon, Manifest, Package, Store}

  @version Mix.Project.config()[:version]
  @default_profile "default"
  @defaults %{connect_timeout: 10, timeout: 30, upload_timeout: 300, drain_timeout: 300}

  @env_vars [
    {"ATANOR_PROFILE", "The profile to use when `--profile` is not given (default `default`)."},
    {"ATANOR_URL",
     "The admin API URL; replaces the URL of the profile. Another URL than the profile's needs ATANOR_TOKEN too, so a stored token is not sent to it."},
    {"ATANOR_TOKEN", "The token; replaces the token of the profile, and is what `login` stores when given."},
    {"ATANOR_CONNECT_TIMEOUT", "Seconds to open the connection (default #{@defaults.connect_timeout})."},
    {"ATANOR_TIMEOUT", "Seconds to wait for an answer (default #{@defaults.timeout})."},
    {"ATANOR_UPLOAD_TIMEOUT", "Seconds to wait for the answer to an upload (default #{@defaults.upload_timeout})."},
    {"ATANOR_DRAIN_TIMEOUT", "Seconds to wait for the answer to `drain` (default #{@defaults.drain_timeout})."},
    {"XDG_CONFIG_HOME", "Where the profiles file lives, `atanor/config.json` inside it (default `~/.config`)."},
    {"MIX_ENV", "The build `deploy` reads native modules from, `_build/$MIX_ENV` (default `dev`)."}
  ]

  @global [
    %{flag: :profile, type: :string, arg: "NAME", doc: "The profile to use (default `default`, or ATANOR_PROFILE)."},
    %{
      flag: :timeout,
      type: :float,
      arg: "SECONDS",
      doc: "Seconds to wait for an answer; overrides ATANOR_TIMEOUT, ATANOR_UPLOAD_TIMEOUT and ATANOR_DRAIN_TIMEOUT."
    },
    %{flag: :help, type: :boolean, doc: "Show the help of the command."}
  ]

  @commands [
    %{
      name: "login",
      args: "--url URL",
      summary: "Check a token against an admin API and store it in a profile.",
      doc:
        "The token comes from ATANOR_TOKEN or, without it, one line on standard input. It is never printed and is stored in the profiles file with mode 0600.",
      options: [
        %{
          flag: :url,
          type: :string,
          arg: "URL",
          doc: "The admin API URL, for example `http://127.0.0.1:5010` (or ATANOR_URL)."
        },
        %{flag: :insecure, type: :boolean, doc: "Send the token over plain http to a host that is not loopback."}
      ]
    },
    %{
      name: "logout",
      args: "",
      summary: "Remove a profile.",
      doc:
        "Removes the stored token of the profile from this machine. It does not revoke the token; use `token revoke` for that.",
      options: []
    },
    %{
      name: "deploy",
      args: "[DIR]",
      summary: "Build the package of a worker project and upload it.",
      doc:
        "Reads the manifest of DIR (default: the current directory), builds the package here, computes its SHA-256 and uploads it, through the admin API of a node or, with `--bucket`, straight to the store. For a native worker the package holds the MD5 of the compiled module, read from the project's `.beam` file. Through the admin API it needs the `deploy` scope of the worker, and `activate` too with `--activate`. `--bucket` needs no node and no token, only write access to the bucket: it takes the endpoint, region and credentials as a node does (docs/configuration.md); it deploys WASM workers only, because a native worker needs its module in the node's release, which only a node can check. `--bucket` cannot be combined with `--url`, `--profile` or `--timeout`. The nodes apply the new head at their next poll.",
      options: [
        %{
          flag: :manifest,
          type: :string,
          arg: "FILE",
          default: "atanor.json",
          doc: "The manifest of the worker, in DIR."
        },
        %{flag: :activate, type: :boolean, doc: "Also make the package the active one."},
        %{
          flag: :bucket,
          type: :string,
          arg: "URL",
          doc:
            "Publish to the store `s3://bucket` or `s3://bucket/prefix` (prefix default `atanor`), not through a node."
        },
        %{
          flag: :url,
          type: :string,
          arg: "URL",
          doc: "The admin API URL; replaces the URL of the profile (or ATANOR_URL)."
        },
        %{
          flag: :ebin,
          type: :keep,
          arg: "DIR",
          default: "_build/$MIX_ENV/lib/*/ebin",
          doc: "A directory with compiled modules; repeatable."
        }
      ]
    },
    %{
      name: "activate",
      args: "WORKER PACKAGE_ID",
      summary: "Make an uploaded package the active one of a worker.",
      doc: "Needs the `activate` scope of the worker. The previous package stays available to `rollback`.",
      options: []
    },
    %{
      name: "rollback",
      args: "WORKER",
      summary: "Return a worker to the package that was active before.",
      doc: "Needs the `rollback` scope of the worker. Repeating it goes one package further back.",
      options: []
    },
    %{
      name: "status",
      args: "[WORKER]",
      summary: "Show the active package of a worker, or of every worker you may read.",
      doc:
        "With a worker it also shows the package the node answering applied and why the head could not be applied, if so. Needs the `read` scope.",
      options: []
    },
    %{
      name: "versions",
      args: "WORKER",
      summary: "List the packages uploaded for a worker, oldest first.",
      doc: "Needs the `read` scope of the worker. Any listed package can be activated.",
      options: [
        %{flag: :limit, type: :integer, arg: "N", doc: "Versions per page (the server's default when omitted)."},
        %{flag: :after, type: :string, arg: "CURSOR", doc: "Continue after the cursor printed by the previous page."}
      ]
    },
    %{
      name: "drain",
      args: "",
      summary: "Hand the node's cells back, then stop the node.",
      doc:
        "Needs `cluster:admin`. The node leaves the load balancer (`/health/serving` fails with `draining`), hibernates every cell it holds and releases each lease, so another node takes it at its next call, then stops itself. It answers when the cells are back, and exits 1 when some stay with their leases. The node's `stop.exit: false` leaves it running, drained. Stop waiting after ATANOR_DRAIN_TIMEOUT seconds; the drain goes on.",
      options: []
    },
    %{
      name: "token create",
      args: "NAME --scope SCOPE",
      summary: "Create a scoped token and print its secret once.",
      doc: "Needs `cluster:admin`. A scope is `cluster:admin` or `worker:<name|*>:<deploy|activate|rollback|read>`.",
      options: [
        %{flag: :scope, type: :keep, arg: "SCOPE", doc: "A scope of the token; repeatable, at least one."},
        %{flag: :description, type: :string, arg: "TEXT", doc: "What the token is for."},
        %{flag: :expires_at, type: :string, arg: "TIME", doc: "When the token stops working, ISO 8601 with an offset."}
      ]
    },
    %{
      name: "token list",
      args: "",
      summary: "List the tokens.",
      doc: "Needs `cluster:admin`. Secrets are never shown.",
      options: [
        %{flag: :limit, type: :integer, arg: "N", doc: "Tokens per page."},
        %{flag: :after, type: :string, arg: "CURSOR", doc: "Continue after the cursor printed by the previous page."}
      ]
    },
    %{
      name: "token revoke",
      args: "TOKEN_ID",
      summary: "Revoke a token.",
      doc: "Needs `cluster:admin`. The token stops working on every node at its next request.",
      options: []
    },
    %{name: "help", args: "[COMMAND]", summary: "Show the commands, or the options of one.", doc: "", options: []},
    %{name: "version", args: "", summary: "Print the version.", doc: "", options: []}
  ]

  @doc "The commands, for help and for the reference (docs/cli.md)."
  def commands, do: @commands

  @doc "The options every command accepts."
  def global_options, do: @global

  @doc "The environment variables the command reads, with what they do."
  def env_vars, do: @env_vars

  @doc "Escript entry point."
  def main(argv) do
    ctx = %{
      env: System.get_env(),
      cwd: File.cwd!(),
      stdin: &read_line/1
    }

    {code, out, err} = run(argv, ctx)
    IO.write(out)
    IO.write(:stderr, err)
    System.halt(code)
  end

  @doc """
  Reads one line from standard input. At a terminal it prompts on standard
  error and reads with the echo off, so a token is not shown; a pipe is read
  as it is, without a prompt.
  """
  @spec read_line(String.t()) :: String.t() | :eof | {:error, term}
  def read_line(prompt) do
    if :prim_tty.isatty(:stdin) == true, do: read_hidden(prompt), else: IO.gets("")
  end

  # The raw mode of the terminal is what lets the driver, not the line discipline, own the echo.
  defp read_hidden(prompt) do
    IO.write(:stderr, prompt)
    :shell.start_interactive({:noshell, :raw})
    :io.setopts(:standard_io, echo: false)

    try do
      IO.gets("")
    after
      :io.setopts(:standard_io, echo: true)
      :shell.start_interactive({:noshell, :cooked})
      IO.write(:stderr, "\n")
    end
  end

  @doc "Runs the command and returns `{exit_code, stdout, stderr}`."
  @spec run([String.t()], map) :: {0 | 1 | 2, String.t(), String.t()}
  def run(argv, ctx) do
    {:ok, _} = Application.ensure_all_started(:req)

    case dispatch(argv, ctx) do
      {:ok, lines} -> {0, lines(lines), ""}
      {:ok, lines, warnings} -> {0, lines(lines), lines(Enum.map(warnings, &("warning: " <> &1)))}
      {:error, message} -> {1, "", "atanor: #{message}\n"}
      {:usage, message} -> {2, "", "atanor: #{message}\nRun `atanor help` for the commands.\n"}
    end
  end

  defp lines(lines), do: Enum.map_join(lines, &(&1 <> "\n"))

  defp dispatch([], _ctx), do: help([])
  defp dispatch(["--help" | _], _ctx), do: help([])
  defp dispatch(["-h" | _], _ctx), do: help([])
  defp dispatch(["--version" | _], _ctx), do: {:ok, ["atanor " <> @version]}

  defp dispatch(argv, ctx) do
    {leading, argv} = leading_options(argv, [])

    {name, rest} =
      case argv do
        ["token", sub | rest] when not is_nil(sub) -> {"token " <> sub, rest}
        [name | rest] -> {name, rest}
      end

    case Enum.find(@commands, &(&1.name == name)) do
      nil -> {:usage, "unknown command #{inspect(name)}"}
      command -> parse_and_run(command, leading ++ rest, ctx)
    end
  end

  # `--profile` and `--timeout` may come before the command.
  defp leading_options([flag, value | rest], acc) when flag in ["--profile", "--timeout"],
    do: leading_options(rest, acc ++ [flag, value])

  defp leading_options(argv, acc), do: {acc, argv}

  defp parse_and_run(command, argv, ctx) do
    switches = for %{flag: flag, type: type} <- @global ++ command.options, do: {flag, switch_type(type)}
    {opts, args, invalid} = OptionParser.parse(argv, strict: switches, aliases: [h: :help])

    cond do
      invalid != [] ->
        {:usage, "invalid option #{invalid |> hd() |> elem(0)} for #{command.name}"}

      opts[:help] ->
        help([command.name])

      true ->
        run_command(command.name, opts, args, ctx)
    end
  end

  defp switch_type(:keep), do: [:string, :keep]
  defp switch_type(type), do: type

  defp run_command("help", _opts, args, _ctx), do: help(args)
  defp run_command("version", _opts, _args, _ctx), do: {:ok, ["atanor " <> @version]}
  defp run_command("login", opts, [], ctx), do: login(opts, ctx)
  defp run_command("logout", opts, [], ctx), do: logout(opts, ctx)

  defp run_command("deploy", opts, args, ctx) when length(args) <= 1 do
    case opts[:bucket] do
      nil -> with_conn(opts, ctx, :upload, &deploy(&1, opts, args, ctx))
      bucket -> with :ok <- exclusive(opts), do: deploy_to_bucket(bucket, opts, args, ctx)
    end
  end

  defp run_command("status", opts, [], ctx), do: with_conn(opts, ctx, :request, &status(&1, nil))
  defp run_command("status", opts, [w], ctx), do: with_conn(opts, ctx, :request, &status(&1, w))
  defp run_command("rollback", opts, [w], ctx), do: with_conn(opts, ctx, :request, &rollback(&1, w))

  defp run_command("activate", opts, [w, id], ctx), do: with_conn(opts, ctx, :request, &activate(&1, w, id))
  defp run_command("versions", opts, [w], ctx), do: with_conn(opts, ctx, :request, &versions(&1, w, opts))

  defp run_command("drain", opts, [], ctx), do: with_conn(opts, ctx, :drain, &drain/1)
  defp run_command("token create", opts, [name], ctx), do: with_conn(opts, ctx, :request, &token_create(&1, name, opts))
  defp run_command("token list", opts, [], ctx), do: with_conn(opts, ctx, :request, &token_list(&1, opts))
  defp run_command("token revoke", opts, [id], ctx), do: with_conn(opts, ctx, :request, &token_revoke(&1, id))

  defp run_command(name, _opts, _args, _ctx) do
    command = Enum.find(@commands, &(&1.name == name))
    {:usage, "usage: atanor #{name} #{command.args}"}
  end

  # Help, generated from the command table.

  defp help([]) do
    width = @commands |> Enum.map(&String.length(&1.name)) |> Enum.max()

    {:ok,
     ["usage: atanor COMMAND [ARGUMENTS] [OPTIONS]", "", "Commands:"] ++
       for(c <- @commands, do: "  #{String.pad_trailing(c.name, width)}  #{c.summary}") ++
       ["", "Run `atanor help COMMAND` for the options. Reference: docs/cli.md."]}
  end

  defp help(words) do
    name = Enum.join(words, " ")

    case Enum.find(@commands, &(&1.name == name)) do
      nil ->
        {:usage, "unknown command #{inspect(name)}"}

      c ->
        {:ok,
         ["usage: atanor #{String.trim("#{c.name} #{c.args}")} [OPTIONS]", "", c.summary] ++
           if(c.doc == "", do: [], else: ["", c.doc]) ++
           ["", "Options:"] ++ Enum.map(c.options ++ @global, &option_line/1)}
    end
  end

  defp option_line(o) do
    flag = "--" <> (o.flag |> Atom.to_string() |> String.replace("_", "-"))
    flag = if o[:arg], do: "#{flag} #{o.arg}", else: flag
    default = if o[:default], do: " (default #{o.default})", else: ""
    "  #{flag}  #{o.doc}#{default}"
  end

  # Connection.

  defp with_conn(opts, ctx, kind, fun) do
    with {:ok, conn} <- connection(opts, ctx, kind) do
      case fun.(conn) do
        {:ok, lines} -> {:ok, lines}
        {:error, message} -> {:error, message}
      end
    end
  end

  defp profile(opts, env), do: opts[:profile] || blank(env["ATANOR_PROFILE"]) || @default_profile

  defp connection(opts, ctx, kind) do
    env = ctx.env
    name = profile(opts, env)

    with {:ok, stored} <- stored_profile(env, name),
         {:ok, url} <- present(opts[:url] || blank(env["ATANOR_URL"]) || stored["url"], name),
         {:ok, token} <- present(blank(env["ATANOR_TOKEN"]) || stored["token"], name),
         :ok <- token_for_url(env, stored, url),
         {:ok, url} <- check_url(url),
         {:ok, connect} <- seconds(env, "ATANOR_CONNECT_TIMEOUT", @defaults.connect_timeout),
         {:ok, timeout} <- request_timeout(opts, env, kind) do
      {:ok, %{url: url, token: token, timeout_ms: timeout, connect_timeout_ms: connect}}
    end
  end

  # A stored token belongs to the URL it was stored with.
  defp token_for_url(env, stored, url) do
    if blank(env["ATANOR_TOKEN"]) || stored["url"] == url,
      do: :ok,
      else: {:usage, "ATANOR_URL differs from the URL of the profile: give ATANOR_TOKEN for #{url} too"}
  end

  defp request_timeout(opts, env, kind) do
    cond do
      opts[:timeout] ->
        if opts[:timeout] > 0, do: {:ok, round(opts[:timeout] * 1000)}, else: {:usage, "--timeout must be positive"}

      kind == :upload ->
        seconds(env, "ATANOR_UPLOAD_TIMEOUT", @defaults.upload_timeout)

      kind == :drain ->
        seconds(env, "ATANOR_DRAIN_TIMEOUT", @defaults.drain_timeout)

      true ->
        seconds(env, "ATANOR_TIMEOUT", @defaults.timeout)
    end
  end

  defp seconds(env, var, default) do
    case blank(env[var]) do
      nil ->
        {:ok, default * 1000}

      text ->
        case Float.parse(text) do
          {n, ""} when n > 0 -> {:ok, round(n * 1000)}
          _ -> {:usage, "#{var} must be a positive number of seconds, got #{inspect(text)}"}
        end
    end
  end

  # Without a file the profile is empty; ATANOR_URL and ATANOR_TOKEN can still complete it.
  defp stored_profile(env, name) do
    with {:ok, path} <- Config.path(env),
         {:ok, profiles} <- Config.profiles(path) do
      {:ok, Map.get(profiles, name, %{})}
    end
  end

  defp present(nil, name),
    do: {:error, "not logged in (profile #{name}): run `atanor login --url URL`, or set ATANOR_URL and ATANOR_TOKEN"}

  defp present(value, _name), do: {:ok, value}

  defp check_url(url) do
    if Regex.match?(~r{\Ahttps?://[^/\s]+}, url),
      do: {:ok, String.trim_trailing(url, "/")},
      else: {:error, "the URL must start with http:// or https://, got #{inspect(url)}"}
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  # Commands.

  defp login(opts, ctx) do
    env = ctx.env
    name = profile(opts, env)

    with {:ok, url} <- present_url(opts[:url] || blank(env["ATANOR_URL"])),
         {:ok, url} <- check_url(url),
         :ok <- login_transport(url, opts),
         {:ok, token} <- login_token(env, ctx),
         {:ok, connect} <- seconds(env, "ATANOR_CONNECT_TIMEOUT", @defaults.connect_timeout),
         {:ok, timeout} <- request_timeout(opts, env, :request),
         {:ok, path} <- Config.path(env),
         conn = %{url: url, token: token, timeout_ms: timeout, connect_timeout_ms: connect},
         {:ok, _} <- Client.request(conn, :get, "/heads"),
         :ok <- Config.put(path, name, url, token) do
      lines = ["logged in to #{url} (profile #{name}); the token is stored in #{path}"]

      if plain_remote?(url),
        do: {:ok, lines, ["#{url} is not https: the token crosses the network in clear"]},
        else: {:ok, lines}
    end
  end

  # The token is sent by the check, so plain http to a remote host is refused before it.
  defp login_transport(url, opts) do
    if plain_remote?(url) and opts[:insecure] != true,
      do: {:usage, "#{url} is not https: the token would cross the network in clear; use https or --insecure"},
      else: :ok
  end

  defp present_url(nil), do: {:usage, "give the admin API URL with --url or ATANOR_URL"}
  defp present_url(url), do: {:ok, url}

  defp login_token(env, ctx) do
    token =
      blank(env["ATANOR_TOKEN"]) ||
        case ctx.stdin.("Token: ") do
          :eof -> nil
          nil -> nil
          line -> blank(String.trim(line))
        end

    if token, do: {:ok, token}, else: {:usage, "give the token in ATANOR_TOKEN or on standard input"}
  end

  @doc false
  def plain_remote?(url) do
    uri = URI.parse(url)
    uri.scheme == "http" and uri.host not in ["localhost", "127.0.0.1", "::1", "[::1]"]
  end

  defp logout(opts, ctx) do
    name = profile(opts, ctx.env)

    with {:ok, path} <- Config.path(ctx.env) do
      case Config.delete(path, name) do
        :ok -> {:ok, ["logged out (profile #{name})"]}
        :absent -> {:ok, ["profile #{name} was not logged in"]}
        {:error, _} = error -> error
      end
    end
  end

  defp deploy(conn, opts, args, ctx) do
    with {:ok, dir, manifest_path} <- project(opts, args, ctx),
         {:ok, map} <- Manifest.read_file(manifest_path),
         {:ok, package} <- build(map, dir, ebin(opts, ctx, dir)),
         {:ok, body} <-
           Client.request(conn, :post, "/workers/#{package.manifest.name}/packages",
             body: package.bytes,
             query: if(opts[:activate], do: [activate: "true"], else: []),
             headers: [{"x-package-sha256", package.id}, {"content-type", "application/octet-stream"}]
           ) do
      head = if body["head"], do: [head_line(body["head"])], else: []
      {:ok, ["package #{body["package_id"]} (#{body["worker"]}, #{body["kind"]}, #{body["size"]} bytes)"] ++ head}
    end
  end

  # The project directory is the argument or the working directory; the manifest is in it, and so are
  # the component and the compiled modules the manifest names.
  defp project(opts, args, ctx) do
    dir = Path.expand(List.first(args) || ".", ctx.cwd)
    manifest = Path.expand(opts[:manifest] || "atanor.json", dir)
    {:ok, Path.dirname(manifest), manifest}
  end

  # The bucket is written without a node, so nothing checks what a node would: a native worker is
  # refused because its module has to be in the node's release (Atanor.Deployments.Service.check_module/1).
  defp deploy_to_bucket(bucket, opts, args, ctx) do
    open_store = ctx[:open_store] || (&open_store/2)

    with {:ok, _dir, manifest_path} <- project(opts, args, ctx),
         {:ok, map} <- Manifest.read_file(manifest_path),
         :ok <- wasm_only(map),
         {:ok, package} <- build(map, Path.dirname(manifest_path), []),
         {:ok, store, children} <- open_store.(bucket, ctx.env) do
      with_children(children, fn ->
        case Service.deploy(store, package, opts[:activate] == true, %{"type" => "bucket"}) do
          {:ok, package, head} -> {:ok, bucket_lines(package, head, bucket)}
          {:error, {stage, reason}} -> {:error, bucket_error(stage, reason, package, bucket)}
        end
      end)
    end
  end

  defp exclusive(opts) do
    case Enum.find([:url, :profile, :timeout], &Keyword.has_key?(opts, &1)) do
      nil ->
        :ok

      flag ->
        {:usage,
         "--bucket writes the store directly and --#{flag} is for the admin API of a node: give one or the other"}
    end
  end

  defp wasm_only(map) do
    case Manifest.parse(map) do
      {:ok, %Manifest{kind: :native, name: name}} ->
        {:error,
         "--bucket deploys WASM workers only: #{name} is native, and a node can run it only if its release holds the module, which the bucket cannot check. Deploy it through a node with --url or a profile, after rolling the nodes to a release that has the module"}

      _ ->
        :ok
    end
  end

  # Credentials, endpoint and region as the node reads them.
  defp open_store(bucket, env) do
    case Daemon.store(bucket, env) do
      {:ok, %{store: store, prefix: prefix, children: children}} ->
        {:ok, Store.open(store, prefix), children}

      {:error, messages} ->
        {:error, Enum.map_join(messages, "; ", &String.replace_prefix(&1, "ATANOR_STORE: ", "--bucket: "))}
    end
  end

  # Renewable credentials are held by a process that has to run while the store is written.
  defp with_children([], fun), do: fun.()

  defp with_children(children, fun) do
    trapping = Process.flag(:trap_exit, true)

    try do
      case Supervisor.start_link(children, strategy: :one_for_one) do
        {:ok, supervisor} ->
          try do
            fun.()
          after
            Supervisor.stop(supervisor)
          end

        {:error, {:shutdown, {:failed_to_start_child, _, {:aws_credentials, source, reason}}}} ->
          {:error, "cannot get the AWS credentials (#{source}): #{inspect(reason)}"}

        {:error, reason} ->
          {:error, "cannot start the AWS credentials: #{inspect(reason)}"}
      end
    after
      Process.flag(:trap_exit, trapping)

      receive do
        {:EXIT, _, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp bucket_lines(package, head, bucket) do
    first =
      "package #{package.id} (#{package.manifest.name}, #{package.manifest.kind}, #{byte_size(package.bytes)} bytes)"

    case head do
      nil ->
        [first, "stored in #{bucket}; this run did not activate it: add --activate"]

      head ->
        [
          first,
          head_line(%{
            "worker" => head.worker,
            "active" => head.active,
            "revision" => head.revision,
            "previous" => head.previous
          }),
          "stored in #{bucket}; the nodes apply it at their next poll"
        ]
    end
  end

  defp bucket_error(:publish, reason, _package, bucket), do: "cannot write the package to #{bucket}: #{inspect(reason)}"

  defp bucket_error(:activate, reason, package, bucket),
    do:
      "package #{package.id} is stored in #{bucket} but cannot be activated: #{inspect(reason)}. Nothing changed for the nodes"

  defp ebin(opts, ctx, dir) do
    case Keyword.get_values(opts, :ebin) do
      [] -> Path.wildcard(Path.join([dir, "_build", blank(ctx.env["MIX_ENV"]) || "dev", "lib", "*", "ebin"]))
      dirs -> Enum.map(dirs, &Path.expand(&1, ctx.cwd))
    end
  end

  # The only place that builds a package: `Atanor.Package.from_project/3`.
  defp build(map, dir, ebin) do
    case Package.from_project(map, dir, ebin: ebin) do
      {:ok, package} ->
        {:ok, package}

      {:error, {:beam_not_found, module, _}} ->
        {:error, "cannot build the package: #{module}.beam not found; compile the project or pass --ebin DIR"}

      {:error, {:component_unreadable, file, reason}} ->
        {:error, "cannot read the component #{file}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, "cannot build the package: #{inspect(reason)}"}
    end
  end

  defp activate(conn, worker, id) do
    with {:ok, head} <- Client.request(conn, :post, "/workers/#{worker}/activate", json: %{package_id: id}),
         do: {:ok, [head_line(head)]}
  end

  defp rollback(conn, worker) do
    with {:ok, head} <- Client.request(conn, :post, "/workers/#{worker}/rollback"), do: {:ok, [head_line(head)]}
  end

  defp status(conn, nil) do
    with {:ok, %{"workers" => heads}} <- Client.request(conn, :get, "/heads") do
      {:ok, if(heads == [], do: ["no workers"], else: Enum.map(heads, &head_line/1))}
    end
  end

  defp status(conn, worker) do
    with {:ok, head} <- Client.request(conn, :get, "/workers/#{worker}/status") do
      {:ok,
       [
         head_line(head),
         "applied by #{head["node"]}: #{head["applied"] || "none"}"
       ] ++ if(head["error"], do: ["error: #{head["error"]}"], else: [])}
    end
  end

  defp versions(conn, worker, opts) do
    query = Enum.reject([limit: opts[:limit], after: opts[:after]], &is_nil(elem(&1, 1)))

    with {:ok, body} <- Client.request(conn, :get, "/workers/#{worker}/versions", query: query) do
      rows =
        for v <- body["versions"] do
          "  #{v["package_id"]}  #{String.pad_trailing(v["state"] || "-", 8)}  #{v["kind"]}  #{v["size"]} bytes  #{v["uploaded_at"]}  by #{uploader(v["uploaded_by"])}"
        end

      next = if body["next"], do: ["more: atanor versions #{worker} --after #{body["next"]}"], else: []
      {:ok, [head_line(body), "versions, oldest first:"] ++ rows ++ next}
    end
  end

  defp uploader(%{"type" => "token", "name" => name, "id" => id}), do: "token #{name} (#{id})"
  defp uploader(%{"type" => type}), do: type
  defp uploader(_), do: "unknown"

  defp drain(conn) do
    with {:ok, body} <- Client.request(conn, :post, "/drain") do
      summary = "#{body["node"]}: #{body["hibernated"]} cells handed back in #{body["duration_ms"]} ms"

      case body["errors"] do
        [] ->
          {:ok, ["drained " <> summary]}

        errors ->
          left = Enum.map_join(errors, ", ", &"#{&1["cell"]} (#{&1["reason"]})")
          {:error, "drain left #{length(errors)} cells to their leases, #{summary}: #{left}"}
      end
    end
  end

  defp token_create(conn, name, opts) do
    scopes = Keyword.get_values(opts, :scope)
    attrs = %{name: name, scopes: scopes, description: opts[:description], expires_at: opts[:expires_at]}

    with {:ok, token} <- Client.request(conn, :post, "/tokens", json: Map.reject(attrs, fn {_, v} -> is_nil(v) end)) do
      {:ok,
       [
         "token #{token["id"]} (#{token["name"]})",
         "scopes: #{Enum.join(token["scopes"], " ")}",
         "expires: #{token["expires_at"] || "never"}",
         "secret: #{token["token"]}",
         "Keep the secret now: it is not shown again."
       ]}
    end
  end

  defp token_list(conn, opts) do
    query = Enum.reject([limit: opts[:limit], after: opts[:after]], &is_nil(elem(&1, 1)))

    with {:ok, body} <- Client.request(conn, :get, "/tokens", query: query) do
      rows =
        for t <- body["tokens"] do
          state = if t["revoked_at"], do: "revoked", else: "active"

          "#{t["id"]}  #{String.pad_trailing(state, 7)}  #{t["name"]}  #{Enum.join(t["scopes"], ",")}  expires #{t["expires_at"] || "never"}"
        end

      next = if body["next"], do: ["more: atanor token list --after #{body["next"]}"], else: []
      {:ok, if(rows == [], do: ["no tokens"], else: rows ++ next)}
    end
  end

  defp token_revoke(conn, id) do
    with {:ok, token} <- Client.request(conn, :post, "/tokens/#{id}/revoke"),
         do: {:ok, ["revoked #{token["id"]} (#{token["name"]})"]}
  end

  defp head_line(h) do
    previous = if h["previous"] in [nil, []], do: "none", else: Enum.join(h["previous"], " ")
    "#{h["worker"]}: active #{h["active"] || "none"}, revision #{h["revision"]}, previous #{previous}"
  end
end
