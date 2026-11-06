defmodule Atanor.Package do
  @moduledoc """
  A deployable package (design §5): the bytes of a deterministic archive, and
  what they hold once parsed and validated.

  The archive is `"ATANORPKG1\\n"` followed by entries in name order, each
  `<<name_size::16, name, data_size::64, data>>`. It has no timestamps, modes
  or owners, so the same inputs give the same bytes. Entries:

    * `atanor.json` - the canonical manifest JSON;
    * `module.md5` - native only: the MD5 (hex) of the worker module's object
      code;
    * the file the manifest names as `component` - WASM only.

  The package id is the SHA-256 (hex) of the bytes.
  """

  alias Atanor.Manifest

  @enforce_keys [:id, :bytes, :manifest]
  defstruct [:id, :bytes, :manifest, :md5, :component]

  @type t :: %__MODULE__{
          id: String.t(),
          bytes: binary,
          manifest: Manifest.t(),
          md5: String.t() | nil,
          component: binary | nil
        }
  @type code :: {:native, md5 :: binary} | {:wasm, component :: binary}

  @limits %{max_manifest_bytes: 262_144, max_component_bytes: 8_388_608}
  @magic "ATANORPKG1\n"
  @manifest_file "atanor.json"
  @md5_file "module.md5"
  @md5 ~r/\A[0-9a-f]{32}\z/

  @doc """
  Builds the package of a manifest map. `code` is the MD5 of the native
  module (raw or hex) or the component bytes.
  """
  @spec build(map, code) :: {:ok, t} | {:error, term}
  def build(manifest_map, code) do
    with {:ok, manifest} <- Manifest.parse(manifest_map),
         {:ok, entries} <- entries(manifest, code) do
      bytes = [@magic | for({name, data} <- Enum.sort(entries), do: entry(name, data))] |> IO.iodata_to_binary()
      parse(bytes)
    end
  end

  @doc """
  Builds the package of a manifest map from the project that holds its code:
  the native module, or the `component` file inside `dir`. The module is the
  loaded one, or with the `:ebin` option (a list of directories) the
  `<module>.beam` file found in the first directory that has it, which is how
  the `atanor` command builds without loading the project.
  """
  @spec from_project(map, Path.t(), keyword) :: {:ok, t} | {:error, term}
  def from_project(manifest_map, dir \\ ".", opts \\ []) do
    with {:ok, manifest} <- Manifest.parse(manifest_map),
         {:ok, code} <- project_code(manifest, dir, opts[:ebin]) do
      build(manifest_map, code)
    end
  end

  @doc "The default size limits of a package, as the instance's `:package` option."
  @spec limits() :: %{max_manifest_bytes: pos_integer, max_component_bytes: pos_integer}
  def limits, do: @limits

  @doc """
  Parses and validates package bytes; the id is computed from them. The
  limits `:max_manifest_bytes` (256 KiB) and `:max_component_bytes` (8 MiB),
  given as a keyword list or a map (the instance's `:package` option), bound the entries before they are decoded or compiled.
  """
  @spec parse(binary, keyword | map) :: {:ok, t} | {:error, {:invalid_package, term}}
  def parse(bytes, opts \\ [])

  def parse(bytes, opts) when is_binary(bytes) do
    limits = Map.merge(@limits, Map.new(opts))

    with {:ok, entries} <- decode(bytes),
         {:ok, json} <- fetch(entries, @manifest_file),
         :ok <- check_size(json, :manifest_too_large, limits.max_manifest_bytes),
         {:ok, map} <- decode_json(json),
         {:ok, manifest} <- manifest(map, json),
         {:ok, md5, component} <- code(manifest, entries),
         :ok <- check_size(component || "", :component_too_large, limits.max_component_bytes) do
      {:ok,
       %__MODULE__{
         id: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
         bytes: bytes,
         manifest: manifest,
         md5: md5,
         component: component
       }}
    end
  end

  def parse(_, _opts), do: invalid(:not_binary)

  defp check_size(data, reason, max),
    do: if(byte_size(data) <= max, do: :ok, else: invalid({reason, byte_size(data)}))

  defp project_code(%Manifest{kind: :native, module: module}, _dir, nil) do
    with {:ok, loaded} <- load_module(module), do: {:ok, {:native, loaded.module_info(:md5)}}
  end

  defp project_code(%Manifest{kind: :native, module: module}, _dir, ebin) do
    beam = module <> ".beam"

    case Enum.find(ebin, &File.regular?(Path.join(&1, beam))) do
      nil ->
        {:error, {:beam_not_found, module, ebin}}

      path ->
        file = Path.join(path, beam)

        case :beam_lib.md5(String.to_charlist(file)) do
          {:ok, {_module, md5}} -> {:ok, {:native, md5}}
          {:error, _, reason} -> {:error, {:beam_unreadable, file, reason}}
        end
    end
  end

  defp project_code(%Manifest{kind: :wasm, component: component}, dir, _ebin) do
    case File.read(Path.join(dir, component)) do
      {:ok, bytes} -> {:ok, {:wasm, bytes}}
      {:error, reason} -> {:error, {:component_unreadable, component, reason}}
    end
  end

  @doc """
  The loaded module named `name`, a native manifest's `module`, loaded from the
  code path if needed (a node in interactive mode loads modules on demand). The
  name comes from a package, so an atom is created for it only when the name is
  a valid module name and `<name>.beam` is on the code path: the atoms are
  bounded by the files the node has. `{:error, {:module_not_loaded, name}}`
  otherwise.
  """
  @spec load_module(String.t()) :: {:ok, module} | {:error, {:module_not_loaded, String.t()}}
  def load_module(name) when is_binary(name) do
    with {:ok, module} <- module_atom(name), true <- Code.ensure_loaded?(module) do
      {:ok, module}
    else
      _ -> {:error, {:module_not_loaded, name}}
    end
  end

  defp module_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError ->
      if Manifest.module_name?(name) and :code.where_is_file(String.to_charlist(name <> ".beam")) != :non_existing,
        do: {:ok, String.to_atom(name)},
        else: :error
  end

  defp entries(%Manifest{kind: :native} = m, {:native, md5}) do
    md5 = if byte_size(md5) == 16, do: Base.encode16(md5, case: :lower), else: md5
    {:ok, [{@manifest_file, Manifest.canonical_json(m)}, {@md5_file, md5}]}
  end

  defp entries(%Manifest{kind: :wasm} = m, {:wasm, bytes}),
    do: {:ok, [{@manifest_file, Manifest.canonical_json(m)}, {m.component, bytes}]}

  defp entries(%Manifest{kind: kind}, _), do: {:error, {:code_does_not_match_kind, kind}}

  defp entry(name, data), do: [<<byte_size(name)::16>>, name, <<byte_size(data)::64>>, data]

  defp decode(@magic <> rest), do: decode(rest, [], nil)
  defp decode(_), do: invalid(:bad_magic)

  defp decode(<<>>, acc, _last), do: {:ok, Map.new(acc)}

  defp decode(<<n::16, name::binary-size(n), size::64, data::binary-size(size), rest::binary>>, acc, last) do
    if last == nil or name > last,
      do: decode(rest, [{name, data} | acc], name),
      else: invalid({:entries_not_sorted, name})
  end

  defp decode(_, _, _), do: invalid(:truncated)

  defp fetch(entries, name) do
    case entries do
      %{^name => data} -> {:ok, data}
      _ -> invalid({:missing_entry, name})
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> invalid(:manifest_not_json)
    end
  end

  # Only the canonical form is accepted, so one package has one set of bytes.
  defp manifest(map, json) do
    case Manifest.parse(map) do
      {:ok, manifest} ->
        if Manifest.canonical_json(manifest) == json, do: {:ok, manifest}, else: invalid(:manifest_not_canonical)

      {:error, error} ->
        invalid(error)
    end
  end

  defp code(%Manifest{kind: :native}, entries) do
    with {:ok, md5} <- fetch(entries, @md5_file),
         :ok <- check(Regex.match?(@md5, md5), :bad_md5),
         :ok <- extra(entries, [@manifest_file, @md5_file]),
         do: {:ok, md5, nil}
  end

  defp code(%Manifest{kind: :wasm, component: name}, entries) do
    with :ok <- check(name not in [@manifest_file, @md5_file], {:reserved_component_name, name}),
         {:ok, component} <- fetch(entries, name),
         :ok <- extra(entries, [@manifest_file, name]),
         do: {:ok, nil, component}
  end

  defp extra(entries, allowed) do
    case Map.keys(entries) -- allowed do
      [] -> :ok
      [name | _] -> invalid({:unexpected_entry, name})
    end
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: invalid(reason)

  defp invalid(reason), do: {:error, {:invalid_package, reason}}
end
