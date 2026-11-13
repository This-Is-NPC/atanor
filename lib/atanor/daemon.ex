defmodule Atanor.Daemon do
  @moduledoc """
  The configuration of an Atanor node run as a daemon (the release, or an image derived from it):
  environment variables, plus an optional JSON file, turned into the options of `{Atanor, opts}`.

  The reference of every key, with its default, is in `docs/configuration.md`.

      settings = Atanor.Daemon.load!()
      children = [{Atanor, settings.opts}]

  A node is the processes of `children/1`; an app derived from the release (`mix atanor.release`)
  puts them first in its own supervision tree, so its code and Atanor share one VM.

  The rules:

    * The environment and the file share one namespace. The file key of `ATANOR_LISTEN` is `listen`
      (the name in lowercase, without `ATANOR_`; `AWS_*` keep their prefix: `aws_access_key_id`).
      The environment overrides the file, key by key. An empty variable counts as unset.
    * A key that is not known fails: an `ATANOR_` variable (the error names it and the closest known
      key) and a key of the file. The variables of the CLI (`cli_variables/0`) are the only
      exceptions.
    * A secret `K` also has `K_FILE`, which names a file that holds the value. Giving both in one
      place is an error. The secrets are `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
      `AWS_SESSION_TOKEN`, `AWS_CONTAINER_AUTHORIZATION_TOKEN`, `ATANOR_ADMIN_TOKEN` and
      `ATANOR_DASHBOARD_TOKEN`.
    * The S3 credentials come from the AWS chain (`Atanor.AwsCredentials`): the environment, web
      identity, the shared files, container credentials, then EC2 metadata. Without a region
      `ATANOR_S3_REGION`, `AWS_REGION` and `AWS_DEFAULT_REGION` decide it, in that order.
    * `ATANOR_ADVERTISE`, `ATANOR_NET_TICKTIME` and `ATANOR_COOKIE_FILE` are read by the release's
      start script, before the VM boots (`rel/env.sh.eex`), so they come from the environment only.
    * The options are checked by `Atanor.Config.build/1`, the single validator of an instance.

  `load/3` is a pure function of the environment map and the contents of the file (the shared AWS
  files are the only other thing it reads); `load!/1` reads
  the process environment and the file named by `ATANOR_CONFIG`, and logs the effective settings
  once, with the secrets masked.
  """

  require Logger

  @any {0, 0, 0, 0}
  @default_region "us-east-1"
  @default_data_dir "/var/lib/atanor/cells"
  @default_prefix "atanor"
  @mask "***"
  # The node name of the release (rel/env.sh.eex): `atanor@<ATANOR_ADVERTISE>`.
  @node_base "atanor"
  # A node joins within a renewal; a node that stopped without leaving is forgotten after the TTL plus
  # the skew margin (2 s).
  @registry_ttl_ms 15_000
  @registry_renew_ms 3_000

  # `listen` keys take `ip:port`; `bytes` take a number of bytes, with an optional k, m or g (powers
  # of 1024). `:boot` keys are read by the start script.
  @keys [
    {"ATANOR_STORE", :url, "The bucket as `s3://bucket` or `s3://bucket/prefix` (prefix default `atanor`). Required."},
    {"ATANOR_S3_ENDPOINT", :string,
     "The S3 endpoint URL. Default: Alambique derives `https://s3.<region>.amazonaws.com` from the region."},
    {"ATANOR_S3_REGION", :string, "The signing region. Default `#{@default_region}`."},
    {"AWS_ACCESS_KEY_ID", :secret, "The S3 access key id (first source of the AWS chain)."},
    {"AWS_SECRET_ACCESS_KEY", :secret, "The S3 secret access key."},
    {"AWS_SESSION_TOKEN", :secret, "The token of temporary keys."},
    {"AWS_REGION", :string, "The region when `ATANOR_S3_REGION` is unset."},
    {"AWS_DEFAULT_REGION", :string, "The region when neither `ATANOR_S3_REGION` nor `AWS_REGION` is set."},
    {"AWS_WEB_IDENTITY_TOKEN_FILE", :string, "The web identity token file (with `AWS_ROLE_ARN`)."},
    {"AWS_ROLE_ARN", :string, "The role to assume with the web identity token."},
    {"AWS_ROLE_SESSION_NAME", :string, "The session name of the assumed role. Default `atanor`."},
    {"AWS_ENDPOINT_URL_STS", :string, "The STS endpoint URL. Default: derived from the region."},
    {"AWS_PROFILE", :string, "The profile of the shared files. Default `default`."},
    {"AWS_SHARED_CREDENTIALS_FILE", :string, "The shared credentials file. Default `~/.aws/credentials`."},
    {"AWS_CONFIG_FILE", :string, "The shared config file. Default `~/.aws/config`."},
    {"AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", :string, "The ECS credentials path, on 169.254.170.2."},
    {"AWS_CONTAINER_CREDENTIALS_FULL_URI", :string, "The container credentials URL (EKS Pod Identity)."},
    {"AWS_CONTAINER_AUTHORIZATION_TOKEN", :token, "The authorization token of the container credentials."},
    {"AWS_EC2_METADATA_DISABLED", :string, "`true` turns the EC2 metadata source off."},
    {"AWS_EC2_METADATA_SERVICE_ENDPOINT", :string, "The EC2 metadata endpoint. Default `http://169.254.169.254`."},
    {"ATANOR_LISTEN", :listen, "The cell ingress, `ip:port`. Default `0.0.0.0:4000`."},
    {"ATANOR_ADMIN_LISTEN", :listen, "The admin API, `ip:port`. Default `0.0.0.0:4001`."},
    {"ATANOR_ADMIN_TOKEN", :secret, "The admin token, at least 32 bytes. Without it there is no admin API."},
    {"ATANOR_DASHBOARD_LISTEN", :listen, "The dashboard, `ip:port`. Default `0.0.0.0:4002`."},
    {"ATANOR_DASHBOARD_TOKEN", :secret, "The dashboard token, at least 32 bytes. Without it there is no dashboard."},
    {"ATANOR_ADVERTISE", :boot,
     "The host or IP the other nodes reach this one at; the Erlang node is `atanor@<it>`, which is what the node registry advertises."},
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
    {"ATANOR_GROUP", :group,
     "The discovery group: a node dials only the nodes of its own group. Default none. A node that replaces another in a swap takes one."},
    {"ATANOR_REGISTRY_TTL_MS", :integer,
     "How long the node's entry in the store is live without a renewal. Default #{@registry_ttl_ms}."},
    {"ATANOR_REGISTRY_RENEW_MS", :integer,
     "How often the node renews its entry and reads the peers. Default #{@registry_renew_ms}."}
  ]

  @secrets for {name, type, _} <- @keys, type in [:secret, :token], do: name
  @boot for {name, :boot, _} <- @keys, do: name
  @store_key "ATANOR_STORE"
  # The path of the file, read before the loader runs.
  @config_var "ATANOR_CONFIG"

  # The documented variables of the CLI (`Atanor.CLI`), listed one by one on purpose.
  @cli_variables ~w(ATANOR_URL ATANOR_TOKEN ATANOR_PROFILE ATANOR_CONNECT_TIMEOUT ATANOR_TIMEOUT
                    ATANOR_UPLOAD_TIMEOUT ATANOR_DRAIN_TIMEOUT)

  @file_forms for name <- @secrets, do: name <> "_FILE"
  @known Enum.map(@keys, &elem(&1, 0)) ++ @file_forms ++ [@config_var]

  # `children` are the processes to start before `{Atanor, opts}`: the holder of renewable credentials.
  @type settings :: %{
          opts: keyword,
          children: [Supervisor.child_spec()],
          effective: [{String.t(), String.t()}]
        }

  # The name of the node's Atanor instance (`Atanor.port/1`, `Atanor.Registry`, ...).
  @instance AtanorDaemon.Atanor

  @doc "The name of the Atanor instance that `children/1` starts."
  @spec instance() :: atom
  def instance, do: @instance

  @doc """
  The processes of a node, in start order: the renewable credentials and the instance named `instance/0`
  (which finds the other nodes through the store, `Atanor.Discovery`). The default settings are those of `load!/0`.
  """
  @spec children(settings) :: [Supervisor.child_spec()]
  def children(settings \\ load!()) do
    settings.children ++ [{Atanor, Keyword.put(settings.opts, :name, @instance)}]
  end

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

  Returns `{:ok, settings}` with `opts` (for `{Atanor, opts}`), `children` and `effective`, the list of
  `{variable, text}` in effect, secrets masked, and the source of the credentials; or `{:error, messages}` with every problem found.
  The options are `:read_file`, a function of a path that returns `{:ok, binary}` or
  `{:error, reason}`, used for the `*_FILE` variables and the shared AWS files (default `File.read/1`),
  `:home` (default `HOME` of `env`) and `:ecs_endpoint` (the host of the relative container URI).
  """
  @spec load(%{optional(String.t()) => String.t()}, binary | nil, keyword) ::
          {:ok, settings} | {:error, [String.t()]}
  def load(env, file_contents \\ nil, opts \\ []) when is_map(env) do
    read = Keyword.get(opts, :read_file, &File.read/1)

    with {:ok, file} <- decode(file_contents),
         {:ok, layers} <- layers(env, file),
         {:ok, values} <- resolve(layers, read),
         {:ok, settings} <- build(values, env, read, opts) do
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

  @doc """
  The store of an `s3://bucket/prefix` URL under the rules of the node, for tools that run without one
  (`atanor deploy --bucket`): the same endpoint, region and AWS credential chain, read from `env` (the
  config file is not read). Returns `{:ok, %{store: {module, config}, prefix: prefix, children:
  children, credentials: source}}`, where `children` hold renewable credentials and must be running
  while the store is used, or `{:error, messages}`. The prefix is `atanor` when the URL has none, as
  for the node. Takes the options of `load/3`.
  """
  @spec store(String.t(), %{optional(String.t()) => String.t()}, keyword) ::
          {:ok,
           %{store: {module, map}, prefix: String.t(), children: [Supervisor.child_spec()], credentials: String.t()}}
          | {:error, [String.t()]}
  def store(url, env, opts \\ []) when is_binary(url) and is_map(env) do
    read = Keyword.get(opts, :read_file, &File.read/1)

    with {:ok, layers} <- layers(Map.put(env, @store_key, url), %{}),
         {:ok, values} <- resolve(layers, read),
         {parsed, []} <- parse_all(Enum.filter(values, &store_value?/1)),
         {:ok, aws} <- credentials(parsed, env, read, opts) do
      {store, prefix} = s3_store(parsed, aws)
      prefix = if prefix == "", do: @default_prefix, else: prefix

      with {:ok, _} <- validate(store: store, prefix: prefix, data_dir: @default_data_dir) do
        {:ok, %{store: store, prefix: prefix, children: credential_children(aws), credentials: aws.source}}
      end
    else
      {_, [_ | _] = errors} -> {:error, errors}
      {:error, _} = error -> error
    end
  end

  # What the S3 store and its credentials read: the bucket, the endpoint, the region and every AWS_ variable.
  defp store_value?({name, _type, _text}),
    do: name in [@store_key, "ATANOR_S3_ENDPOINT", "ATANOR_S3_REGION"] or String.starts_with?(name, "AWS_")

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

    {own, Enum.sort(errors)}
  end

  defp file_layer(file) do
    index = Map.new(@known -- [@config_var], &{file_key(&1), &1})

    Enum.reduce(Enum.sort(file), {%{}, []}, fn {key, value}, {layer, errors} ->
      cond do
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

  defp pick(name, type, env, file, read) when type in [:secret, :token] do
    layer = Enum.find([env, file], &(Map.has_key?(&1, name) or Map.has_key?(&1, name <> "_FILE")))

    case layer && {layer[name], layer[name <> "_FILE"]} do
      nil -> {:ok, nil}
      {inline, nil} -> {:ok, inline}
      {nil, path} -> read_secret(name, path, read, type)
      {_, _} -> {:error, "#{name} and #{name}_FILE are both set: give one"}
    end
  end

  defp pick(name, _type, env, file, _read), do: {:ok, env[name] || file[name]}

  # A `:token` keeps its path, because the holder of the credentials reads it again (it rotates).
  defp read_secret(name, path, read, type) do
    case read.(path) do
      {:ok, contents} ->
        case blank(String.trim(contents)) do
          nil -> {:error, "#{name}_FILE: #{path} is empty"}
          value -> {:ok, if(type == :token, do: {:file, path}, else: value)}
        end

      {:error, reason} ->
        {:error, "#{name}_FILE: cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp build(values, env, read, opts) do
    {parsed, errors} = parse_all(values)
    errors = errors ++ boot_errors(env) ++ missing(parsed)

    with [] <- errors,
         {:ok, aws} <- credentials(parsed, env, read, opts),
         {:ok, store_opts} <- options(parsed, aws, blank(env["ATANOR_ADVERTISE"])) do
      {:ok,
       %{
         opts: store_opts,
         children: credential_children(aws),
         effective: effective(parsed, env) ++ [{"credentials", aws.source}]
       }}
    else
      [_ | _] = errors -> {:error, errors}
      {:error, _} = error -> error
    end
  end

  defp parse_all(values) do
    Enum.reduce(values, {%{}, []}, fn {name, type, text}, {acc, errors} ->
      case parse(type, text) do
        {:ok, value} -> {Map.put(acc, name, value), errors}
        {:error, why} -> {acc, errors ++ ["#{name}: #{why}"]}
      end
    end)
  end

  defp credential_children(%{provider: nil}), do: []

  defp credential_children(%{provider: provider, source: source}),
    do: [{Atanor.AwsCredentials, {provider, source: source}}]

  defp credentials(parsed, env, read, opts) do
    detect_opts =
      [home: Keyword.get(opts, :home, blank(env["HOME"])), read_file: read] ++
        Keyword.take(opts, [:ecs_endpoint])

    case Atanor.AwsCredentials.detect(parsed, detect_opts) do
      {:ok, aws} -> {:ok, aws}
      {:error, message} -> {:error, [message]}
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
    for name <- ["ATANOR_STORE"], not Map.has_key?(parsed, name) do
      "#{name} is required"
    end
  end

  defp parse(:secret, text), do: {:ok, text}
  defp parse(:token, text), do: {:ok, text}
  defp parse(:string, text), do: {:ok, text}

  defp parse(:group, text),
    do:
      if(text =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/,
        do: {:ok, text},
        else: {:error, "must be 1 to 64 letters, digits, '.', '_' or '-'"}
      )

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

  defp unit_bytes("k"), do: 1_024
  defp unit_bytes("m"), do: 1_048_576
  defp unit_bytes("g"), do: 1_073_741_824

  # The bucket under the prefix, with the region and credentials rules of the node. Without an endpoint
  # Alambique derives the AWS one from the region. Renewable credentials are a function Alambique caches
  # by its identity.
  defp s3_store(v, aws) do
    {bucket, prefix} = v["ATANOR_STORE"]
    region = v["ATANOR_S3_REGION"] || v["AWS_REGION"] || v["AWS_DEFAULT_REGION"] || @default_region
    config = Map.merge(%{region: region, bucket: bucket}, credential_options(aws))

    {{Alambique.Store.S3,
      if(v["ATANOR_S3_ENDPOINT"], do: Map.put(config, :endpoint, v["ATANOR_S3_ENDPOINT"]), else: config)}, prefix}
  end

  defp options(v, aws, advertise) do
    {store, prefix} = s3_store(v, aws)

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
        wal: for(bytes <- [v["ATANOR_WAL_LIMIT"]], bytes, do: {:max_bytes, bytes}),
        registry: registry(v, advertise)
      )
      |> put_group(:stop,
        shutdown_ms: v["ATANOR_SHUTDOWN_MS"],
        drain_timeout_ms: v["ATANOR_DRAIN_TIMEOUT_MS"],
        drain_concurrency: v["ATANOR_DRAIN_CONCURRENCY"]
      )
      |> put_group(:detector, acceptable_pause_ms: v["ATANOR_DETECTOR_PAUSE_MS"])

    validate(opts)
  end

  defp validate(opts) do
    _ = Atanor.Config.build(opts)
    {:ok, opts}
  rescue
    error in ArgumentError -> {:error, ["#{Exception.message(error)}"]}
  end

  defp credential_options(%{static: {id, secret, token}}) do
    %{access_key_id: id, secret_access_key: secret}
    |> then(&if(token, do: Map.put(&1, :session_token, token), else: &1))
  end

  defp credential_options(%{provider: _}), do: %{credentials: &Atanor.AwsCredentials.credentials/0}

  # The node registry: this node is found at its Erlang node name (`Atanor.Discovery`). Without an
  # advertised host (a pure load) there is no registry.
  defp registry(_v, nil), do: []

  defp registry(v, advertise) do
    [
      advertise: "#{@node_base}@#{advertise}",
      ttl_ms: v["ATANOR_REGISTRY_TTL_MS"] || @registry_ttl_ms,
      renew_ms: v["ATANOR_REGISTRY_RENEW_MS"] || @registry_renew_ms
    ] ++ if(v["ATANOR_GROUP"], do: [meta: %{"group" => v["ATANOR_GROUP"]}], else: [])
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

  defp shown(name, type, parsed, _env) when type in [:secret, :token], do: if(Map.has_key?(parsed, name), do: @mask)
  defp shown(name, :boot, _parsed, env), do: blank(env[name])

  defp shown(name, :url, parsed, _env),
    do: with({bucket, prefix} <- parsed[name], do: Path.join("s3://" <> bucket, prefix))

  defp shown(name, :listen, parsed, _env), do: with({ip, port} <- parsed[name], do: "#{:inet.ntoa(ip)}:#{port}")
  defp shown(name, _type, parsed, _env), do: with(value when value != nil <- parsed[name], do: to_string(value))

  defp blank(nil), do: nil
  defp blank(text), do: if(String.trim(text) == "", do: nil, else: text)
end
