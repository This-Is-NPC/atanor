defmodule Atanor.AwsCredentials do
  @moduledoc """
  The AWS credential chain of the daemon (`Atanor.Daemon`), in the order of the AWS SDKs. The first
  source that is configured supplies the credentials:

    1. the environment: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, with an optional
       `AWS_SESSION_TOKEN` (static);
    2. web identity: `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` (STS `AssumeRoleWithWebIdentity`,
       which is unsigned);
    3. the shared files, `AWS_PROFILE` (default `default`): static keys only; SSO, `credential_process`
       and roles are reported as unsupported;
    4. container credentials (ECS, EKS Pod Identity): `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` or
       `AWS_CONTAINER_CREDENTIALS_FULL_URI`;
    5. EC2 IMDSv2, unless `AWS_EC2_METADATA_DISABLED=true`.

  `detect/2` is pure: it picks the source from the settings and reads only the shared files. A
  source that is configured but fails is an error; the chain does not fall through to the next one.

  Temporary credentials (sources 2, 4 and 5) are held by this process. `credentials/1` is the function
  handed to `Alambique.Store.S3` as `:credentials`. It returns the cached keys and refreshes them when
  they expire in less than 5 minutes. The calls queue on the process, so one refresh runs at a time.
  A failed refresh keeps the old keys until they expire, logs a warning and is not retried for 30
  seconds. Nothing here logs or returns a key, a token or the web identity token.
  """
  use GenServer
  require Logger

  @margin_ms 300_000
  @backoff_ms 30_000
  @call_timeout 20_000
  @imds_endpoint "http://169.254.169.254"
  @ecs_endpoint "http://169.254.170.2"

  @type static :: {String.t(), String.t(), String.t() | nil}
  @type provider ::
          {:web_identity, map} | {:container, map} | {:imds, map}
  @type detected :: %{source: String.t(), static: static | nil, provider: provider | nil}

  @doc """
  Picks the source from `config` (the daemon's values by variable name) and returns it.

  `opts`: `:home` (the home directory, for the shared files; none skips them), `:read_file` (default
  `File.read/1`) and `:ecs_endpoint` (the host of the relative container URI).
  """
  @spec detect(map, keyword) :: {:ok, detected} | {:error, String.t()}
  def detect(config, opts \\ []) do
    read = Keyword.get(opts, :read_file, &File.read/1)

    with :skip <- env(config),
         :skip <- web_identity(config),
         :skip <- shared_files(config, Keyword.get(opts, :home), read),
         :skip <- container(config, Keyword.get(opts, :ecs_endpoint, @ecs_endpoint)),
         :skip <- imds(config) do
      {:error,
       "no AWS credentials: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or a web identity, a profile, " <>
         "container credentials or the EC2 metadata service (AWS_EC2_METADATA_DISABLED is true)"}
    end
  end

  defp static(source, {id, secret, token}), do: {:ok, %{source: source, static: {id, secret, token}, provider: nil}}
  defp renewable(source, provider), do: {:ok, %{source: source, static: nil, provider: provider}}

  defp env(config) do
    id = config["AWS_ACCESS_KEY_ID"]
    secret = config["AWS_SECRET_ACCESS_KEY"]

    cond do
      id && secret -> static("env", {id, secret, config["AWS_SESSION_TOKEN"]})
      id -> {:error, "AWS_ACCESS_KEY_ID is set without AWS_SECRET_ACCESS_KEY"}
      secret -> {:error, "AWS_SECRET_ACCESS_KEY is set without AWS_ACCESS_KEY_ID"}
      true -> :skip
    end
  end

  defp web_identity(config) do
    file = config["AWS_WEB_IDENTITY_TOKEN_FILE"]
    role = config["AWS_ROLE_ARN"]

    cond do
      file && role ->
        renewable("web identity", {
          :web_identity,
          %{
            token_file: file,
            role_arn: role,
            session_name: config["AWS_ROLE_SESSION_NAME"] || "atanor",
            endpoint: config["AWS_ENDPOINT_URL_STS"] || sts_endpoint(config)
          }
        })

      file ->
        {:error, "AWS_WEB_IDENTITY_TOKEN_FILE is set without AWS_ROLE_ARN"}

      role ->
        {:error, "AWS_ROLE_ARN is set without AWS_WEB_IDENTITY_TOKEN_FILE"}

      true ->
        :skip
    end
  end

  defp sts_endpoint(config) do
    case config["ATANOR_S3_REGION"] || config["AWS_REGION"] || config["AWS_DEFAULT_REGION"] do
      nil -> "https://sts.amazonaws.com"
      region -> "https://sts.#{region}.amazonaws.com"
    end
  end

  # The shared files hold static keys only. Without a home directory they are skipped.
  defp shared_files(config, home, read) do
    explicit = config["AWS_PROFILE"]
    profile = explicit || "default"
    creds_path = config["AWS_SHARED_CREDENTIALS_FILE"] || (home && Path.join(home, ".aws/credentials"))
    config_path = config["AWS_CONFIG_FILE"] || (home && Path.join(home, ".aws/config"))

    with {:ok, creds} <- ini(creds_path, config["AWS_SHARED_CREDENTIALS_FILE"], read),
         {:ok, conf} <- ini(config_path, config["AWS_CONFIG_FILE"], read) do
      from_creds = creds[profile]
      from_conf = conf[if(profile == "default", do: "default", else: "profile " <> profile)]

      case merge(from_creds, from_conf) do
        nil when explicit != nil -> {:error, "AWS_PROFILE #{profile} is in neither the credentials nor the config file"}
        nil -> :skip
        section -> profile_credentials(profile, section)
      end
    end
  end

  defp merge(nil, nil), do: nil
  defp merge(a, b), do: Map.merge(b || %{}, a || %{})

  defp profile_credentials(profile, section) do
    unsupported =
      cond do
        section["credential_process"] -> "credential_process"
        Enum.any?(Map.keys(section), &String.starts_with?(&1, "sso_")) -> "SSO"
        section["role_arn"] || section["source_profile"] -> "assumed roles"
        section["web_identity_token_file"] -> "web identity"
        true -> nil
      end

    cond do
      unsupported ->
        {:error,
         "profile #{profile} uses #{unsupported}, which the daemon does not support: " <>
           "give static keys, or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"}

      section["aws_access_key_id"] && section["aws_secret_access_key"] ->
        static(
          "profile #{profile}",
          {section["aws_access_key_id"], section["aws_secret_access_key"], section["aws_session_token"]}
        )

      true ->
        {:error, "profile #{profile} has no aws_access_key_id and aws_secret_access_key"}
    end
  end

  # A file the variable names must exist; a default path may be absent.
  defp ini(nil, _explicit, _read), do: {:ok, %{}}

  defp ini(path, explicit, read) do
    case read.(path) do
      {:ok, text} -> {:ok, parse_ini(text)}
      {:error, :enoent} when is_nil(explicit) -> {:ok, %{}}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp parse_ini(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce({nil, %{}}, fn line, {section, acc} ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, ["#", ";"]) ->
          {section, acc}

        String.starts_with?(line, "[") ->
          name = line |> String.trim_leading("[") |> String.split("]") |> hd() |> String.trim()
          {name, Map.put_new(acc, name, %{})}

        section && String.contains?(line, "=") ->
          [key, value] = String.split(line, "=", parts: 2)
          {section, put_in(acc, [section, String.trim(key)], String.trim(value))}

        true ->
          {section, acc}
      end
    end)
    |> elem(1)
  end

  defp container(config, ecs_endpoint) do
    relative = config["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
    full = config["AWS_CONTAINER_CREDENTIALS_FULL_URI"]
    url = if relative, do: ecs_endpoint <> relative, else: full

    if url,
      do:
        renewable(
          "container credentials",
          {:container, %{url: url, token: config["AWS_CONTAINER_AUTHORIZATION_TOKEN"]}}
        ),
      else: :skip
  end

  defp imds(config) do
    if String.downcase(config["AWS_EC2_METADATA_DISABLED"] || "") == "true",
      do: :skip,
      else:
        renewable("EC2 metadata", {:imds, %{endpoint: config["AWS_EC2_METADATA_SERVICE_ENDPOINT"] || @imds_endpoint}})
  end

  ## The process that holds temporary credentials

  @doc "Starts the holder of a renewable `provider` and fetches the first credentials."
  @spec start_link(provider, keyword) :: GenServer.on_start()
  def start_link(provider, opts \\ []) do
    GenServer.start_link(__MODULE__, {provider, opts}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec({provider, opts}),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [provider, opts]}, type: :worker}

  def child_spec(provider), do: child_spec({provider, []})

  @doc """
  The credentials for `Alambique.Store.S3`: `{access_key_id, secret_access_key, token, expires_at}`
  or `{:error, reason}`. Pass `&Atanor.AwsCredentials.credentials/0` as the store's `:credentials`.
  """
  @spec credentials(GenServer.server()) :: {String.t(), String.t(), String.t() | nil, DateTime.t()} | {:error, term}
  def credentials(server \\ __MODULE__) do
    GenServer.call(server, :credentials, @call_timeout)
  catch
    :exit, _ -> {:error, :credentials_unavailable}
  end

  @impl true
  def init({provider, opts}) do
    state = %{
      provider: provider,
      source: Keyword.get(opts, :source, "credentials"),
      margin_ms: Keyword.get(opts, :margin_ms, @margin_ms),
      creds: nil,
      retry_at: 0
    }

    case fetch(provider) do
      {:ok, creds} -> {:ok, %{state | creds: creds}}
      {:error, reason} -> {:stop, {:aws_credentials, state.source, reason}}
    end
  end

  @impl true
  def handle_call(:credentials, _from, state) do
    now = System.system_time(:millisecond)
    {_, _, _, expires_at} = state.creds
    left = DateTime.diff(expires_at, DateTime.from_unix!(now, :millisecond), :millisecond)

    cond do
      left > state.margin_ms ->
        {:reply, state.creds, state}

      left > 0 and now < state.retry_at ->
        {:reply, state.creds, state}

      true ->
        case refresh(state, now, left) do
          {:ok, state} -> {:reply, state.creds, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # New credentials; or the old ones with a backoff while they last; or an error when they are gone.
  defp refresh(state, now, left) do
    case fetch(state.provider) do
      {:ok, creds} ->
        {:ok, %{state | creds: creds, retry_at: 0}}

      {:error, reason} when left > 0 ->
        Logger.warning(
          "atanor: refreshing the AWS credentials (#{state.source}) failed: #{inspect(reason)}; " <>
            "keeping the current ones, which expire in #{div(left, 1000)}s"
        )

        {:ok, %{state | retry_at: now + @backoff_ms}}

      {:error, reason} ->
        Logger.warning("atanor: refreshing the AWS credentials (#{state.source}) failed: #{inspect(reason)}")
        {:error, reason, %{state | retry_at: now + @backoff_ms}}
    end
  end

  ## The sources

  defp fetch({:web_identity, p}) do
    with {:ok, token} <- read_token(p.token_file),
         {:ok, %{status: 200, body: body}} <-
           http(:post, p.endpoint <> "/",
             form: [
               Action: "AssumeRoleWithWebIdentity",
               Version: "2011-06-15",
               RoleArn: p.role_arn,
               RoleSessionName: p.session_name,
               WebIdentityToken: token
             ],
             receive_timeout: 10_000
           ) do
      parse_sts(body)
    else
      {:ok, %{status: status, body: body}} -> {:error, {:sts, status, xml(body, "Code")}}
      {:error, _} = error -> error
    end
  end

  defp fetch({:container, p}) do
    with {:ok, headers} <- container_headers(p),
         {:ok, %{status: 200, body: body}} <- http(:get, p.url, headers: headers, receive_timeout: 5_000) do
      parse_json(body)
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, _} = error -> error
    end
  end

  defp fetch({:imds, p}) do
    base = p.endpoint <> "/latest"
    short = [receive_timeout: 1_000, connect_options: [timeout: 1_000]]

    with {:ok, %{status: 200, body: token}} <-
           http(:put, base <> "/api/token", [headers: [{"x-aws-ec2-metadata-token-ttl-seconds", "21600"}]] ++ short),
         auth = [{"x-aws-ec2-metadata-token", String.trim(token)}],
         {:ok, %{status: 200, body: roles}} <-
           http(:get, base <> "/meta-data/iam/security-credentials/", [headers: auth] ++ short),
         [role | _] <- String.split(roles, "\n", trim: true),
         {:ok, %{status: 200, body: body}} <-
           http(:get, base <> "/meta-data/iam/security-credentials/" <> String.trim(role), [headers: auth] ++ short) do
      parse_json(body)
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      [] -> {:error, :no_instance_role}
      {:error, _} = error -> error
    end
  end

  # The token is inline or `{:file, path}`; a file is read again on every fetch, as Pod Identity rotates it.
  defp container_headers(%{token: nil}), do: {:ok, []}

  defp container_headers(%{token: {:file, path}}),
    do: with({:ok, token} <- read_token(path), do: {:ok, [{"authorization", token}]})

  defp container_headers(%{token: token}), do: {:ok, [{"authorization", token}]}

  defp read_token(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, String.trim(text)}
      {:error, reason} -> {:error, {:token_file, :file.format_error(reason) |> to_string()}}
    end
  end

  # Req answers `{:error, exception}` for transport errors; the exception holds no request.
  defp http(method, url, opts) do
    base = [method: method, url: url, retry: false, redirect: false, decode_body: false]

    case Req.request(Keyword.merge(base, opts)) do
      {:ok, _} = ok -> ok
      {:error, %{reason: reason}} -> {:error, {:transport, reason}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  catch
    kind, _reason -> {:error, {:request_crashed, kind}}
  end

  defp parse_json(body) do
    with {:ok, %{"AccessKeyId" => id, "SecretAccessKey" => secret, "Token" => token, "Expiration" => at}} <-
           Jason.decode(body),
         {:ok, expires_at, _} <- DateTime.from_iso8601(at) do
      {:ok, {id, secret, token, expires_at}}
    else
      _ -> {:error, :invalid_credentials_response}
    end
  end

  defp parse_sts(body) do
    with id when is_binary(id) <- xml(body, "AccessKeyId"),
         secret when is_binary(secret) <- xml(body, "SecretAccessKey"),
         token when is_binary(token) <- xml(body, "SessionToken"),
         at when is_binary(at) <- xml(body, "Expiration"),
         {:ok, expires_at, _} <- DateTime.from_iso8601(at) do
      {:ok, {id, secret, token, expires_at}}
    else
      _ -> {:error, :invalid_credentials_response}
    end
  end

  defp xml(body, tag) do
    case Regex.run(~r{<#{tag}>(.*?)</#{tag}>}s, to_string(body), capture: :all_but_first) do
      [value] -> value
      _ -> nil
    end
  end
end
