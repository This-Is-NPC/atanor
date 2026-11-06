defmodule Atanor.CLI.Config do
  @moduledoc """
  The per-user profiles of the `atanor` command: a JSON file at
  `$XDG_CONFIG_HOME/atanor/config.json` (`~/.config/atanor/config.json` when
  the variable is unset), mode 0600 in a 0700 directory:

      {"profiles": {"default": {"url": "http://127.0.0.1:5010", "token": "atn_..."}}}

  Writes replace the file atomically, so a reader never sees a partial file.
  """

  @doc "Path of the config file for an environment map."
  @spec path(%{optional(String.t()) => String.t()}) :: {:ok, Path.t()} | {:error, String.t()}
  def path(env) do
    case {blank(env["XDG_CONFIG_HOME"]), blank(env["HOME"])} do
      {nil, nil} -> {:error, "cannot find the config directory: set XDG_CONFIG_HOME or HOME"}
      {nil, home} -> {:ok, Path.join([home, ".config", "atanor", "config.json"])}
      {xdg, _} -> {:ok, Path.join([xdg, "atanor", "config.json"])}
    end
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  @doc "All profiles, as a map of name to `%{\"url\" => ..., \"token\" => ...}`; none when there is no file."
  @spec profiles(Path.t()) :: {:ok, map} | {:error, String.t()}
  def profiles(path) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"profiles" => %{} = profiles}} -> {:ok, profiles}
          _ -> {:error, "#{path} is not a profiles file"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Stores a profile."
  @spec put(Path.t(), String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def put(path, name, url, token) do
    with {:ok, profiles} <- profiles(path),
         do: write(path, Map.put(profiles, name, %{"url" => url, "token" => token}))
  end

  @doc "Removes a profile; `:absent` when there was none."
  @spec delete(Path.t(), String.t()) :: :ok | :absent | {:error, String.t()}
  def delete(path, name) do
    with {:ok, profiles} <- profiles(path) do
      if Map.has_key?(profiles, name), do: write(path, Map.delete(profiles, name)), else: :absent
    end
  end

  defp write(path, profiles) do
    dir = Path.dirname(path)
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, Jason.encode!(%{profiles: profiles}, pretty: true) <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
