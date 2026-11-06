defmodule Atanor.Manifest do
  @moduledoc """
  The manifest of a worker (design §3): the JSON of `atanor.json` as a map
  with string keys, parsed and validated into a struct.

  This is the only module that knows the manifest's keys and shape.

  `parse/1` returns `{:error, {:invalid_manifest, path, reason}}` for the
  first invalid input, where `path` lists the keys and indexes leading to it.
  `format_error/1` renders it. Unknown keys are errors, so a typo is never
  silently ignored.

  `parse/1` accepts `"kind": "wasm"` with a `component` (design §3.2).

  `"manifest_version": 1` is required (design §3).

  A cell binding is `{"migrations": [...], "partitions": n}`; `partitions`
  (an integer from 2 to `Atanor.Partition.max_partitions/0`) makes the
  namespace partitioned (design §4.2) and is kept in `partitions`.
  """

  alias Atanor.{Cell, Partition}

  @type migration :: {pos_integer, [String.t()]}
  @type route ::
          {:http, host :: String.t(), path :: String.t()}
          | {:tcp, listener :: String.t(), protocol :: :thousand_island | :ranch}
  @type allow :: {scheme :: String.t() | nil, host :: String.t(), port :: :inet.port_number() | nil}
  @type t :: %__MODULE__{
          name: String.t(),
          kind: :native | :wasm,
          module: String.t() | nil,
          component: String.t() | nil,
          cells: %{String.t() => [migration]},
          partitions: %{String.t() => pos_integer},
          secrets: [String.t()],
          http_allow: [allow],
          workers: [String.t()],
          callable_by: [String.t()],
          alarms: boolean,
          sockets: boolean,
          jobs: boolean,
          routes: [route],
          limits: %{optional(atom) => pos_integer}
        }

  defstruct [
    :name,
    :kind,
    :module,
    :component,
    cells: %{},
    partitions: %{},
    secrets: [],
    http_allow: [],
    workers: [],
    callable_by: [],
    alarms: false,
    sockets: false,
    jobs: false,
    routes: [],
    limits: %{}
  ]

  @version 1
  @name ~r/\A[a-z0-9_-]+\z/
  @component ~r/\A(?!\.\.?\z)[A-Za-z0-9._-]+\z/
  @allow ~r/\A(?:(?<scheme>https?):\/\/)?(?<wildcard>\*\.)?(?<host>[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*)(?::(?<port>[0-9]{1,5}))?\z/
  @default_ports %{"http" => 80, "https" => 443}
  @host ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/
  @secret ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @module ~r/\AElixir(\.[A-Z][A-Za-z0-9_]*)+\z/
  # The longest atom the VM accepts.
  @max_module_bytes 255
  @path ~r/\A\/[^\s?#]*\z/
  @limits %{"timeout_ms" => :timeout_ms, "memory_bytes" => :memory_bytes, "fuel" => :fuel, "cpu_ms" => :cpu_ms}

  @doc "Whether `value` is a valid worker name (`[a-z0-9_-]+`)."
  @spec worker_name?(term) :: boolean
  def worker_name?(value), do: is_binary(value) and Regex.match?(@name, value)

  @doc "Whether `value` is the name of a native worker module, such as `\"Elixir.MyApp.Worker\"`."
  @spec module_name?(term) :: boolean
  def module_name?(value),
    do: is_binary(value) and byte_size(value) <= @max_module_bytes and Regex.match?(@module, value)

  @doc "Parses and validates a manifest map."
  @spec parse(term) :: {:ok, t} | {:error, {:invalid_manifest, [String.t() | non_neg_integer], term}}
  def parse(map) when is_map(map) do
    with :ok <- keys(map, ~w(manifest_version name kind module component bindings callable_by routes limits), []),
         {:ok, _} <- required(map, "manifest_version", [], &version/2),
         {:ok, name} <- required(map, "name", [], &name/2),
         {:ok, kind} <- required(map, "kind", [], &kind/2),
         {:ok, module, component} <- code(map, kind),
         {:ok, bindings} <- bindings(Map.get(map, "bindings", %{}), ["bindings"]),
         {:ok, callable_by} <-
           optional(map, "callable_by", [], [], &list(&1, &2, @name, "a list of worker names")),
         {:ok, routes} <- optional(map, "routes", [], [], &routes/2),
         {:ok, limits} <- optional(map, "limits", %{}, [], &limits/2) do
      {:ok,
       struct!(
         __MODULE__,
         [name: name, kind: kind, module: module, component: component] ++
           bindings ++ [callable_by: callable_by, routes: routes, limits: limits]
       )}
    end
  end

  def parse(_), do: error([], :not_a_map)

  @doc "Reads and validates a manifest file; returns the map, or a message that names the file."
  @spec read_file(Path.t()) :: {:ok, map} | {:error, String.t()}
  def read_file(path) do
    with {:ok, json} <- File.read(path),
         {:ok, map} <- Jason.decode(json),
         {:ok, _} <- parse(map) do
      {:ok, map}
    else
      {:error, {:invalid_manifest, _, _} = error} -> {:error, "#{path}: " <> format_error(error)}
      {:error, %Jason.DecodeError{}} -> {:error, "#{path}: not valid JSON"}
      {:error, reason} -> {:error, "cannot read manifest #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "The normalized manifest as a JSON-friendly map: `parse(to_map(m)) == {:ok, m}`."
  @spec to_map(t) :: map
  def to_map(%__MODULE__{} = m) do
    code = if m.kind == :native, do: %{"module" => m.module}, else: %{"component" => m.component}
    # Left out when empty, so a manifest without it keeps its canonical form and package id.
    callers = if m.callable_by == [], do: %{}, else: %{"callable_by" => m.callable_by}

    code
    |> Map.merge(callers)
    |> Map.merge(%{
      "manifest_version" => @version,
      "name" => m.name,
      "kind" => Atom.to_string(m.kind),
      "bindings" => %{
        "cells" => Map.new(m.cells, fn {ns, migs} -> {ns, cell_map(migs, m.partitions[ns])} end),
        "secrets" => m.secrets,
        "http" => %{"allow" => Enum.map(m.http_allow, &allow_string/1)},
        "workers" => m.workers,
        "alarms" => m.alarms,
        "sockets" => m.sockets,
        "jobs" => m.jobs
      },
      "routes" => Enum.map(m.routes, &route_map/1),
      "limits" => Map.new(m.limits, fn {k, v} -> {Atom.to_string(k), v} end)
    })
  end

  @doc "The normalized manifest as JSON with sorted keys, the same for equal manifests."
  @spec canonical_json(t) :: binary
  def canonical_json(%__MODULE__{} = m), do: m |> to_map() |> sorted() |> Jason.encode!()

  @doc "Renders an error returned by `parse/1`."
  @spec format_error({:invalid_manifest, list, term}) :: String.t()
  def format_error({:invalid_manifest, path, reason}) do
    where = if path == [], do: "manifest", else: Enum.join(path, ".")
    "invalid manifest at #{where}: #{reason(reason)}"
  end

  defp reason(:not_a_map), do: "must be an object"
  defp reason(:required), do: "is required"
  defp reason({:unknown_key, key}), do: "unknown key #{inspect(key)}"
  defp reason({:expected, what}), do: "must be #{what}"
  defp reason(other), do: inspect(other)

  defp cell_map(migrations, nil), do: %{"migrations" => Enum.map(migrations, &Tuple.to_list/1)}
  defp cell_map(migrations, n), do: migrations |> cell_map(nil) |> Map.put("partitions", n)

  defp route_map({:http, host, path}), do: %{"http" => %{"host" => host, "path" => path}}
  defp route_map({:tcp, listener, :thousand_island}), do: %{"tcp" => %{"listener" => listener}}
  defp route_map({:tcp, listener, :ranch}), do: %{"tcp" => %{"listener" => listener, "protocol" => "ranch"}}

  defp allow_string({scheme, host, port}),
    do: if(scheme, do: scheme <> "://", else: "") <> host <> if(port, do: ":#{port}", else: "")

  defp sorted(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, sorted(v)} end) |> Jason.OrderedObject.new()

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(other), do: other

  defp error(path, reason), do: {:error, {:invalid_manifest, path, reason}}
  defp expected(path, what), do: error(path, {:expected, what})

  defp keys(map, allowed, path) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> error(path, {:unknown_key, key})
    end
  end

  defp required(map, key, path, parse) do
    case map do
      %{^key => value} -> parse.(value, path ++ [key])
      _ -> error(path ++ [key], :required)
    end
  end

  defp optional(map, key, default, path, parse) do
    case map do
      %{^key => value} -> parse.(value, path ++ [key])
      _ -> {:ok, default}
    end
  end

  defp version(@version, _), do: {:ok, @version}
  defp version(_, path), do: expected(path, "the integer #{@version}")

  defp name(value, path) do
    if is_binary(value) and Regex.match?(@name, value),
      do: {:ok, value},
      else: expected(path, "a string matching [a-z0-9_-]+")
  end

  defp kind("native", _), do: {:ok, :native}
  defp kind("wasm", _), do: {:ok, :wasm}
  defp kind(_, path), do: expected(path, ~s("native" or "wasm"))

  defp code(map, :native) do
    with {:ok, module} <- required(map, "module", [], &module/2),
         do:
           if(is_map_key(map, "component"),
             do: error(["component"], {:unknown_key, "component"}),
             else: {:ok, module, nil}
           )
  end

  defp code(map, :wasm) do
    with {:ok, component} <- required(map, "component", [], &component/2),
         do: if(is_map_key(map, "module"), do: error(["module"], {:unknown_key, "module"}), else: {:ok, nil, component})
  end

  defp module(value, path) do
    if module_name?(value),
      do: {:ok, value},
      else: expected(path, ~s(a module name like "Elixir.MyApp.Worker"))
  end

  defp component(value, path) do
    if is_binary(value) and Regex.match?(@component, value),
      do: {:ok, value},
      else: expected(path, "a file name like worker.wasm")
  end

  defp bindings(map, path) when is_map(map) do
    with :ok <- keys(map, ~w(cells secrets http workers alarms sockets jobs), path),
         {:ok, cells} <- optional(map, "cells", %{}, path, &cells/2),
         {:ok, secrets} <- optional(map, "secrets", [], path, &list(&1, &2, @secret, "a list of names like API_TOKEN")),
         {:ok, allow} <- optional(map, "http", [], path, &http/2),
         {:ok, workers} <- optional(map, "workers", [], path, &list(&1, &2, @name, "a list of worker names")),
         {:ok, alarms} <- optional(map, "alarms", false, path, &boolean/2),
         {:ok, sockets} <- optional(map, "sockets", false, path, &boolean/2),
         {:ok, jobs} <- optional(map, "jobs", false, path, &boolean/2) do
      {:ok,
       [
         cells: Map.new(cells, fn {ns, {migrations, _}} -> {ns, migrations} end),
         partitions: for({ns, {_, n}} <- cells, n, into: %{}, do: {ns, n}),
         secrets: secrets,
         http_allow: allow,
         workers: workers,
         alarms: alarms,
         sockets: sockets,
         jobs: jobs
       ]}
    end
  end

  defp bindings(_, path), do: expected(path, "an object")

  defp boolean(value, _) when is_boolean(value), do: {:ok, value}
  defp boolean(_, path), do: expected(path, "true or false")

  defp list(values, path, regex, what) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.find(fn {v, _} -> not (is_binary(v) and Regex.match?(regex, v)) end)
    |> case do
      nil -> {:ok, values}
      {_, i} -> expected(path ++ [i], what)
    end
  end

  defp list(_, path, _, what), do: expected(path, what)

  defp http(%{} = map, path) do
    with :ok <- keys(map, ["allow"], path),
         do: optional(map, "allow", [], path, &allow/2)
  end

  defp http(_, path), do: expected(path, "an object")

  @allow_what "a list of host, host:port, scheme://host[:port] or *.domain entries, in lowercase"

  defp allow(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, i}, {:ok, acc} ->
      case allow_entry(entry) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, expected(path ++ [i], @allow_what)}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp allow(_, path), do: expected(path, @allow_what)

  # A scheme without a port means the scheme's default port; a bare host
  # matches any scheme and port. A wildcard needs a domain below the TLD.
  defp allow_entry(entry) when is_binary(entry) do
    with %{"scheme" => scheme, "wildcard" => wildcard, "host" => host, "port" => port} <-
           Regex.named_captures(@allow, entry),
         true <- wildcard == "" or String.contains?(host, "."),
         {:ok, port} <- allow_port(scheme, port) do
      {:ok, {if(scheme == "", do: nil, else: scheme), wildcard <> host, port}}
    else
      _ -> :error
    end
  end

  defp allow_entry(_), do: :error

  defp allow_port("", ""), do: {:ok, nil}
  defp allow_port(scheme, ""), do: {:ok, Map.fetch!(@default_ports, scheme)}

  defp allow_port(_, port) do
    port = String.to_integer(port)
    if port in 1..65_535, do: {:ok, port}, else: :error
  end

  @doc """
  Whether `http.allow` permits a request to `scheme://host:port`. `host` must
  be lowercase. An entry `*.example.com` matches subdomains, never the bare
  domain.
  """
  @spec http_allowed?(t, String.t(), String.t(), :inet.port_number()) :: boolean
  def http_allowed?(%__MODULE__{http_allow: allow}, scheme, host, port) do
    Enum.any?(allow, fn {s, h, p} ->
      (is_nil(s) or s == scheme) and (is_nil(p) or p == port) and host_match?(h, host)
    end)
  end

  defp host_match?("*." <> domain, host), do: String.ends_with?(host, "." <> domain)
  defp host_match?(pattern, host), do: pattern == host

  @doc """
  Whether a route host `host` (exact, `*.domain` or `*`) falls under the
  operator pattern `pattern` (exact, `*.domain` for subdomains of `domain`, or
  `*` for every host, the catch-all route included).
  """
  @spec host_covered?(String.t(), String.t()) :: boolean
  def host_covered?("*", _host), do: true
  def host_covered?(pattern, host), do: pattern == host or host_match?(pattern, host)

  @doc """
  Whether the `http.allow` host `host` (exact or `*.domain`) stays inside the
  operator pattern `pattern` (exact, `*.domain` or `*`): a wildcard entry needs
  a wildcard pattern at least as wide.
  """
  @spec allow_covered?(String.t(), String.t()) :: boolean
  def allow_covered?("*", _host), do: true
  def allow_covered?(pattern, host) when pattern == host, do: true
  def allow_covered?("*." <> wide, "*." <> domain), do: String.ends_with?(domain, "." <> wide)
  def allow_covered?(_pattern, "*." <> _domain), do: false
  def allow_covered?(pattern, host), do: host_match?(pattern, host)

  defp cells(map, path) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {ns, spec}, {:ok, acc} ->
      case cell(ns, spec, path ++ [ns]) do
        {:ok, cell} -> {:cont, {:ok, Map.put(acc, ns, cell)}}
        error -> {:halt, error}
      end
    end)
  end

  defp cells(_, path), do: expected(path, "an object")

  defp cell(ns, %{} = spec, path) do
    with :ok <- Cell.validate_namespace(ns) |> namespace(path),
         :ok <- keys(spec, ["migrations", "partitions"], path),
         {:ok, migrations} <- optional(spec, "migrations", [], path, &migrations/2),
         {:ok, partitions} <- optional(spec, "partitions", nil, path, &partitions/2),
         do: {:ok, {migrations, partitions}}
  end

  defp cell(_, _, path), do: expected(path, "an object")

  defp partitions(n, path) do
    max = Partition.max_partitions()

    if is_integer(n) and n in 2..max//1,
      do: {:ok, n},
      else: expected(path, "an integer from 2 to #{max}")
  end

  defp namespace(:ok, _), do: :ok
  defp namespace({:error, _}, path), do: expected(path, "a namespace matching [a-z0-9_-]+")

  defp migrations(list, path) when is_list(list) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, version}, {:ok, acc} ->
      case migration(entry, version, path ++ [version - 1]) do
        {:ok, m} -> {:cont, {:ok, [m | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp migrations(_, path), do: expected(path, "a list of [version, sql] pairs")

  defp migration([version, sql], version, path) do
    case statements(sql) do
      {:ok, statements} -> {:ok, {version, statements}}
      :error -> expected(path ++ [1], "a SQL statement or a non-empty list of statements")
    end
  end

  defp migration([_, _], version, path),
    do: expected(path ++ [0], "version #{version} (versions are contiguous from 1)")

  defp migration(_, _, path), do: expected(path, "a [version, sql] pair")

  defp statements(sql) when is_binary(sql) and sql != "", do: {:ok, [sql]}

  defp statements([_ | _] = list),
    do: if(Enum.all?(list, &(is_binary(&1) and &1 != "")), do: {:ok, list}, else: :error)

  defp statements(_), do: :error

  defp routes(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, i}, {:ok, acc} ->
      case route(entry, path ++ [i]) do
        {:ok, r} -> {:cont, {:ok, [r | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp routes(_, path), do: expected(path, "a list of routes")

  defp route(%{"http" => %{} = http} = route, path) when map_size(route) == 1 do
    path = path ++ ["http"]

    with :ok <- keys(http, ~w(host path), path),
         {:ok, host} <- required(http, "host", path, &route_host/2),
         {:ok, url_path} <- optional(http, "path", "/", path, &route_path/2),
         do: {:ok, {:http, host, url_path}}
  end

  defp route(%{"tcp" => %{} = tcp} = route, path) when map_size(route) == 1 do
    path = path ++ ["tcp"]

    with :ok <- keys(tcp, ["listener", "protocol"], path),
         {:ok, listener} <- required(tcp, "listener", path, &name/2),
         {:ok, protocol} <- optional(tcp, "protocol", :thousand_island, path, &route_protocol/2),
         do: {:ok, {:tcp, listener, protocol}}
  end

  defp route(_, path), do: expected(path, ~s(an object with one key, "http" or "tcp"))

  defp route_protocol("thousand_island", _path), do: {:ok, :thousand_island}
  defp route_protocol("ranch", _path), do: {:ok, :ranch}
  defp route_protocol(_, path), do: expected(path, ~s("thousand_island" or "ranch"))

  defp route_host(host, path),
    do: if(host_pattern?(host), do: {:ok, host}, else: expected(path, "a lowercase host name, *.host or *"))

  @doc "Whether `value` is a lowercase host name, `*.` and a host name, or `*` (every host)."
  @spec host_pattern?(term) :: boolean
  def host_pattern?("*"), do: true
  def host_pattern?("*." <> rest), do: Regex.match?(@host, rest)
  def host_pattern?(value), do: is_binary(value) and Regex.match?(@host, value)

  # A trailing slash is dropped, so "/api/" and "/api" are the same prefix.
  defp route_path(url, path) do
    if is_binary(url) and Regex.match?(@path, url),
      do: {:ok, if(String.trim_trailing(url, "/") == "", do: "/", else: String.trim_trailing(url, "/"))},
      else: expected(path, "a path starting with /")
  end

  defp limits(%{} = map, path) do
    with :ok <- keys(map, Map.keys(@limits), path) do
      Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        if is_integer(value) and value > 0,
          do: {:cont, {:ok, Map.put(acc, Map.fetch!(@limits, key), value)}},
          else: {:halt, expected(path ++ [key], "a positive integer")}
      end)
    end
  end

  defp limits(_, path), do: expected(path, "an object")
end
