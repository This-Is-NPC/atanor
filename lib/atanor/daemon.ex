defmodule Atanor.Daemon do
  @moduledoc """
  The configuration of an Atanor node run as a daemon (the release, or an image derived from it):
  environment variables, plus an optional JSON file, turned into the options of `{Atanor, opts}`.

  The reference of every key, with its default, is in `docs/configuration.md`.

      settings = Atanor.Daemon.load!()
      children = [{Atanor, settings.opts}]

  The rules:

    * The environment and the file share one namespace. The file key of `ATANOR_LISTEN` is `listen`
      (the name in lowercase, without `ATANOR_`; `AWS_*` keep their prefix: `aws_access_key_id`).
      The environment overrides the file, key by key. An empty variable counts as unset.
    * A key that is not known fails: an `ATANOR_` variable (the error names it and the closest known
      key) and a key of the file. The variables of the CLI (`cli_variables/0`) are the only
      exceptions.
    * A secret `K` also has `K_FILE`, which names a file that holds the value. Giving both in one
      place is an error. The secrets are `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
      `ATANOR_ADMIN_TOKEN` and `ATANOR_DASHBOARD_TOKEN`.
    * `ATANOR_ADVERTISE`, `ATANOR_NET_TICKTIME` and `ATANOR_COOKIE_FILE` are read by the release's
      start script, before the VM boots (`rel/env.sh.eex`), so they come from the environment only.
    * The options are checked by `Atanor.Config.build/1`, the single validator of an instance.

  `load/3` is a pure function of the environment map and the contents of the file; `load!/1` reads
  the process environment and the file named by `ATANOR_CONFIG`, and logs the effective settings
  once, with the secrets masked.
  """

  require Logger

  @any {0, 0, 0, 0}
  @default_region "us-east-1"
  @default_data_dir "/var/lib/atanor/cells"
  @mask "***"

  # `listen` keys take `ip:port`; `bytes` take a number of bytes, with an optional k, m or g (powers
  # of 1024). `:boot` keys are read by the start script; `:peers` is the list of `cluster/node`.
  @keys [
    {"ATANOR_STORE", :url, "The bucket as `s3://bucket` or `s3://bucket/prefix` (prefix default `atanor`). Required."},
    {"ATANOR_S3_ENDPOINT", :string, "The S3 endpoint URL. Default `https://s3.<region>.amazonaws.com`."},
    {"ATANOR_S3_REGION", :string, "The signing region. Default `#{@default_region}`."},
    {"AWS_ACCESS_KEY_ID", :secret, "The S3 access key id. Required."},
    {"AWS_SECRET_ACCESS_KEY", :secret, "The S3 secret access key. Required."},
    {"ATANOR_LISTEN", :listen, "The cell ingress, `ip:port`. Default `0.0.0.0:4000`."},
    {"ATANOR_ADMIN_LISTEN", :listen, "The admin API, `ip:port`. Default `0.0.0.0:4001`."},
    {"ATANOR_ADMIN_TOKEN", :secret, "The admin token, at least 32 bytes. Without it there is no admin API."},
    {"ATANOR_DASHBOARD_LISTEN", :listen, "The dashboard, `ip:port`. Default `0.0.0.0:4002`."},
    {"ATANOR_DASHBOARD_TOKEN", :secret, "The dashboard token, at least 32 bytes. Without it there is no dashboard."},
    {"ATANOR_ADVERTISE", :boot, "The host or IP the other nodes reach this one at; the Erlang node is `atanor@<it>`."},
    {"ATANOR_NET_TICKTIME", :boot, "Seconds a silent peer goes unnoticed (Erlang's `net_ticktime`). Default 60."},
    {"ATANOR_COOKIE_FILE", :boot, "The file that holds the Erlang cookie (or give `RELEASE_COOKIE`)."},
    {"ATANOR_NODE_ID", :string, "The node's id in the leases. Default: the Erlang node name."},
    {"ATANOR_DATA_DIR", :string, "The directory of the cells' files. Default `#{@default_data_dir}`."},
    {"ATANOR_MEMORY_LIMIT", :bytes, "The memory the node may use. Default: the cgroup limit."},
    {"ATANOR_DISK_LIMIT", :bytes, "The disk budget of the data directory. Default: 80% of its file system."},
    {"ATANOR_WAL_LIMIT", :bytes,
     "The bytes of write-ahead log a node may hold. Default: derived from the disk budget."},
    {"ATANOR_RELEASE", :string, "The release id. Default `atanor-<version>`."},
    {"ATANOR_LEASE_TTL_MS", :integer, "The cell lease time to live. Default: Alambique's."},
    {"ATANOR_SHUTDOWN_MS", :integer, "The bound of a whole drain (`stop.shutdown_ms`). Default 75000."},
    {"ATANOR_DRAIN_TIMEOUT_MS", :integer, "The bound of one cell's handoff in a drain. Default 15000."},
    {"ATANOR_DRAIN_CONCURRENCY", :integer, "The cells handed off at once in a drain. Default 64."},
    {"ATANOR_DETECTOR_PAUSE_MS", :integer, "The pause the failure detector tolerates. Default 2000."},
    {"ATANOR_PEERS", :peers,
     "The host names of the peers, comma separated (`cluster/node`; removed by store discovery)."}
  ]

  @secrets for {name, :secret, _} <- @keys, do: name
  @boot for {name, :boot, _} <- @keys, do: name
  @peers_key "ATANOR_PEERS"
  # The path of the file, read before the loader runs.
  @config_var "ATANOR_CONFIG"
  @session_token "AWS_SESSION_TOKEN"

  # The documented variables of the CLI (`Atanor.CLI`), listed one by one on purpose.
  @cli_variables ~w(ATANOR_URL ATANOR_TOKEN ATANOR_PROFILE ATANOR_CONNECT_TIMEOUT ATANOR_TIMEOUT
                    ATANOR_UPLOAD_TIMEOUT ATANOR_DRAIN_TIMEOUT)

  @file_forms for name <- @secrets, do: name <> "_FILE"
  @known Enum.map(@keys, &elem(&1, 0)) ++ @file_forms ++ [@config_var]

  @type settings :: %{
          opts: keyword,
          peers: [String.t()],
          effective: [{String.t(), String.t()}]
        }

  @doc "The keys: `{variable, type, description}`, in the order of the reference."
  @spec keys() :: [{String.t(), atom, String.t()}]
  def keys, do: @keys

  @doc "The environment variables of the node's keys, the `*_FILE` forms and `ATANOR_CONFIG` included."
  @spec known_variables() :: [String.t()]
  def known_variables, do: @known

  @doc "The `ATANOR_` variables of the CLI, which the daemon does not take as its own and does not refuse."
  @spec cli_variables() :: [String.t()]
  def cli_variables, do: @cli_variables

  @doc "The variables the start script reads before the VM boots."
  @spec boot_variables() :: [String.t()]
  def boot_variables, do: @boot

  @doc """
  The settings from the environment and the contents of the file (a JSON object, or `nil`).

  Returns `{:ok, settings}` with `opts` (for `{Atanor, opts}`), `peers` and `effective`, the list of
  `{variable, text}` in effect, secrets masked; or `{:error, messages}` with every problem found.
  The only option is `:read_file`, a function of a path that returns `{:ok, binary}` or
  `{:error, reason}`, used for the `*_FILE` variables (default `File.read/1`).
  """
  @spec load(%{optional(String.t()) => String.t()}, binary | nil, keyword) ::
          {:ok, settings} | {:error, [String.t()]}
  def load(env, file_contents \\ nil, opts \\ []) when is_map(env) do
    read = Keyword.get(opts, :read_file, &File.read/1)

    with {:ok, file} <- decode(file_contents),
         {:ok, layers} <- layers(env, file),
         {:ok, values} <- resolve(layers, read),
         {:ok, settings} <- build(values, env) do
      {:ok, settings}
    end
  end

  @doc """
  Reads `System.get_env/0` and the file named by `ATANOR_CONFIG`, logs the effective settings and
  returns them. Raises `ArgumentError` with every problem when a setting is wrong.
  """
  @spec load!(%{optional(String.t()) => String.t()}) :: settings
  def load!(env \\ System.get_env()) do
    result =
      case blank(env[@config_var]) do
        nil ->
          load(env)

        path ->
          case File.read(path) do
            {:ok, contents} -> load(env, contents)
            {:error, reason} -> {:error, ["#{@config_var}: cannot read #{path}: #{:file.format_error(reason)}"]}
          end
      end

    case result do
      {:ok, settings} ->
        Logger.info(describe(settings))
        settings

      {:error, messages} ->
        raise ArgumentError, "invalid configuration:\n" <> Enum.map_join(messages, "\n", &("  " <> &1))
    end
  end

  @doc "The effective settings as one log line, secrets masked."
  @spec describe(settings) :: String.t()
  def describe(%{effective: effective}),
    do: "atanor: effective settings " <> Enum.map_join(effective, " ", fn {name, text} -> "#{name}=#{text}" end)

  # The file: a flat JSON object. Values are strings or integers; null counts as unset.
  defp decode(nil), do: {:ok, %{}}

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = object} -> {:ok, object}
      {:ok, _} -> {:error, ["the config file must be a JSON object"]}
      {:error, _} -> {:error, ["the config file is not valid JSON"]}
    end
  end

  # Each layer maps a variable name (the inline form or `*_FILE`) to its text.
  defp layers(env, file) do
    {env_layer, env_errors} = env_layer(env)
    {file_layer, file_errors} = file_layer(file)

    case env_errors ++ file_errors do
      [] -> {:ok, {env_layer, file_layer}}
      errors -> {:error, errors}
    end
  end

  defp env_layer(env) do
    own = Map.new(for {name, value} <- env, name in @known, text = blank(value), do: {name, text})

    errors =
      for {name, _} <- env, String.starts_with?(name, "ATANOR_"), name not in @known, name not in @cli_variables do
        unknown("variable #{name}", name, @known)
      end

    session =
      if blank(env[@session_token]),
        do: ["#{@session_token} is set, but the S3 store takes no session token yet: use static keys"],
        else: []

    {own, Enum.sort(errors) ++ session}
  end

  defp file_layer(file) do
    index = Map.new(@known -- [@config_var], &{file_key(&1), &1})

    Enum.reduce(Enum.sort(file), {%{}, []}, fn {key, value}, {layer, errors} ->
      cond do
        key == "aws_session_token" ->
          {layer, errors ++ ["file key aws_session_token: the S3 store takes no session token yet: use static keys"]}

        not Map.has_key?(index, key) ->
          {layer, errors ++ [unknown("key #{inspect(key)} of the config file", key, Map.keys(index))]}

        index[key] in @boot ->
          {layer, errors ++ ["file key #{key}: #{index[key]} is read before the VM boots: set it in the environment"]}

        is_nil(value) ->
          {layer, errors}

        is_binary(value) or is_integer(value) ->
          {put_text(layer, index[key], to_string(value)), errors}

        true ->
          {layer, errors ++ ["file key #{key}: must be a string or an integer"]}
      end
    end)
  end

  defp put_text(layer, name, text), do: if(blank(text), do: Map.put(layer, name, text), else: layer)

  defp file_key("ATANOR_" <> rest), do: String.downcase(rest)
  defp file_key(name), do: String.downcase(name)

  defp unknown(what, given, candidates) do
    {best, score} =
      candidates
      |> Enum.map(&{&1, String.jaro_distance(String.downcase(given), String.downcase(&1))})
      |> Enum.max_by(&elem(&1, 1))

    hint = if score >= 0.7, do: "; did you mean #{best}?", else: "; see docs/configuration.md"
    "unknown #{what}#{hint}"
  end

  # One value per key: the environment wins over the file; a secret is inline or from a file, not both
  # in the same layer.
  defp resolve({env, file}, read) do
    results =
      for {name, type, _} <- @keys, type != :boot, do: {name, type, pick(name, type, env, file, read)}

    case for({_, _, {:error, message}} <- results, do: message) do
      [] -> {:ok, for({name, type, {:ok, value}} <- results, value != nil, do: {name, type, value})}
      errors -> {:error, errors}
    end
  end

  defp pick(name, :secret, env, file, read) do
    layer = Enum.find([env, file], &(Map.has_key?(&1, name) or Map.has_key?(&1, name <> "_FILE")))

    case layer && {layer[name], layer[name <> "_FILE"]} do
      nil -> {:ok, nil}
      {inline, nil} -> {:ok, inline}
      {nil, path} -> read_secret(name, path, read)
      {_, _} -> {:error, "#{name} and #{name}_FILE are both set: give one"}
    end
  end

  defp pick(name, _type, env, file, _read), do: {:ok, env[name] || file[name]}

  defp read_secret(name, path, read) do
    case read.(path) do
      {:ok, contents} ->
        case blank(String.trim(contents)) do
          nil -> {:error, "#{name}_FILE: #{path} is empty"}
          value -> {:ok, value}
        end

      {:error, reason} ->
        {:error, "#{name}_FILE: cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp build(values, env) do
    {parsed, errors} =
      Enum.reduce(values, {%{}, []}, fn {name, type, text}, {acc, errors} ->
        case parse(type, text) do
          {:ok, value} -> {Map.put(acc, name, value), errors}
          {:error, why} -> {acc, errors ++ ["#{name}: #{why}"]}
        end
      end)

    errors = errors ++ boot_errors(env) ++ missing(parsed)

    with [] <- errors,
         {:ok, opts} <- options(parsed) do
      {:ok, %{opts: opts, peers: Map.get(parsed, @peers_key, []), effective: effective(parsed, env)}}
    else
      [_ | _] = errors -> {:error, errors}
      {:error, _} = error -> error
    end
  end

  defp boot_errors(env) do
    advertise = blank(env["ATANOR_ADVERTISE"])
    ticktime = blank(env["ATANOR_NET_TICKTIME"])

    [
      if(advertise && not (advertise =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/),
        do: "ATANOR_ADVERTISE: must be a host name or an IP address"
      ),
      if(ticktime && not (ticktime =~ ~r/\A[1-9][0-9]*\z/), do: "ATANOR_NET_TICKTIME: must be a positive integer")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp missing(parsed) do
    for name <- ["ATANOR_STORE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"], not Map.has_key?(parsed, name) do
      "#{name} is required"
    end
  end

  defp parse(:secret, text), do: {:ok, text}
  defp parse(:string, text), do: {:ok, text}

  defp parse(:integer, text) do
    if text =~ ~r/\A[0-9]+\z/, do: {:ok, String.to_integer(text)}, else: {:error, "must be a non-negative integer"}
  end

  defp parse(:bytes, text) do
    case Regex.run(~r/\A([0-9]+)([kKmMgG])?\z/, text) do
      [_, n] -> {:ok, String.to_integer(n)}
      [_, n, unit] -> {:ok, String.to_integer(n) * unit_bytes(String.downcase(unit))}
      nil -> {:error, "must be a number of bytes, with an optional k, m or g"}
    end
  end

  defp parse(:listen, text) do
    with [host, port] <- Regex.run(~r/\A(.+):([0-9]+)\z/, text, capture: :all_but_first),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(String.trim(host, "[") |> String.trim("]"))),
         {port, ""} when port in 0..65_535 <- Integer.parse(port) do
      {:ok, {ip, port}}
    else
      _ -> {:error, "must be ip:port, for example 0.0.0.0:4000"}
    end
  end

  defp parse(:url, text) do
    case URI.parse(text) do
      %URI{scheme: "s3", host: bucket, path: path, userinfo: nil, port: nil, query: nil, fragment: nil}
      when is_binary(bucket) and bucket != "" ->
        {:ok, {bucket, String.trim(path || "", "/")}}

      _ ->
        {:error, "must be s3://bucket or s3://bucket/prefix"}
    end
  end

  defp parse(:peers, text), do: {:ok, String.split(text, ",", trim: true) |> Enum.map(&String.trim/1)}

  defp unit_bytes("k"), do: 1_024
  defp unit_bytes("m"), do: 1_048_576
  defp unit_bytes("g"), do: 1_073_741_824

  defp options(v) do
    {bucket, prefix} = v["ATANOR_STORE"]
    region = v["ATANOR_S3_REGION"] || @default_region

    store =
      {Alambique.Store.S3,
       %{
         endpoint: v["ATANOR_S3_ENDPOINT"] || "https://s3.#{region}.amazonaws.com",
         region: region,
         bucket: bucket,
         access_key_id: v["AWS_ACCESS_KEY_ID"],
         secret_access_key: v["AWS_SECRET_ACCESS_KEY"]
       }}

    {ip, port} = v["ATANOR_LISTEN"] || {@any, 4000}

    opts =
      [store: store, data_dir: v["ATANOR_DATA_DIR"] || @default_data_dir, ip: ip, port: port]
      |> put_unless(prefix == "", :prefix, prefix)
      |> put_listener(:admin, v["ATANOR_ADMIN_LISTEN"], 4001, v["ATANOR_ADMIN_TOKEN"])
      |> put_listener(:dashboard, v["ATANOR_DASHBOARD_LISTEN"], 4002, v["ATANOR_DASHBOARD_TOKEN"])
      |> put_group(:release, id: v["ATANOR_RELEASE"])
      |> put_group(:memory, limit_bytes: v["ATANOR_MEMORY_LIMIT"])
      |> put_group(:disk, max_bytes: v["ATANOR_DISK_LIMIT"])
      |> put_group(:alambique,
        lease_ttl_ms: v["ATANOR_LEASE_TTL_MS"],
        node_id: v["ATANOR_NODE_ID"],
        wal: for(bytes <- [v["ATANOR_WAL_LIMIT"]], bytes, do: {:max_bytes, bytes})
      )
      |> put_group(:stop,
        shutdown_ms: v["ATANOR_SHUTDOWN_MS"],
        drain_timeout_ms: v["ATANOR_DRAIN_TIMEOUT_MS"],
        drain_concurrency: v["ATANOR_DRAIN_CONCURRENCY"]
      )
      |> put_group(:detector, acceptable_pause_ms: v["ATANOR_DETECTOR_PAUSE_MS"])

    try do
      _ = Atanor.Config.build(opts)
      {:ok, opts}
    rescue
      error in ArgumentError -> {:error, ["#{Exception.message(error)}"]}
    end
  end

  defp put_unless(opts, true, _key, _value), do: opts
  defp put_unless(opts, false, key, value), do: opts ++ [{key, value}]

  defp put_listener(opts, _name, nil, _port, nil), do: opts

  defp put_listener(opts, name, listen, port, token) do
    {ip, port} = listen || {@any, port}
    opts ++ [{name, [ip: ip, port: port] ++ if(token, do: [token: token], else: [])}]
  end

  # A group with only the options that are set; no group when none is.
  defp put_group(opts, key, group) do
    case Enum.reject(group, fn {_, value} -> value in [nil, []] end) do
      [] -> opts
      group -> opts ++ [{key, group}]
    end
  end

  defp effective(parsed, env) do
    set =
      for {name, type, _} <- @keys, text = shown(name, type, parsed, env), do: {name, text}

    Enum.reject(set ++ [{@config_var, env[@config_var]}], fn {_, text} -> is_nil(blank(text)) end)
  end

  defp shown(name, :secret, parsed, _env), do: if(Map.has_key?(parsed, name), do: @mask)
  defp shown(name, :boot, _parsed, env), do: blank(env[name])
  defp shown(name, :url, parsed, _env), do: with({bucket, prefix} <- parsed[name], do: "s3://#{bucket}/#{prefix}")
  defp shown(name, :listen, parsed, _env), do: with({ip, port} <- parsed[name], do: "#{:inet.ntoa(ip)}:#{port}")
  defp shown(name, :peers, parsed, _env), do: with(peers when is_list(peers) <- parsed[name], do: Enum.join(peers, ","))
  defp shown(name, _type, parsed, _env), do: with(value when value != nil <- parsed[name], do: to_string(value))

  defp blank(nil), do: nil
  defp blank(text), do: if(String.trim(text) == "", do: nil, else: text)
end
