defmodule Atanor.Release do
  @moduledoc """
  The build a node runs (design §17.1): an operator-supplied identity, the
  Atanor/Elixir/OTP/Alambique versions and the NIF hashes.

  `:release` `:id` is the identity the operator puts in the option. The default
  `"atanor-" <> Application.spec(:atanor, :vsn)` is a development convenience:
  two builds of the same version are different builds, so give production
  nodes an image digest or commit.
  """

  alias Atanor.Config

  @doc "The development default release id."
  @spec default_id() :: String.t()
  def default_id, do: "atanor-" <> (vsn(:atanor) || "dev")

  @doc "The release information of an instance (its name or an `Atanor.Config`)."
  @spec info(atom | Config.t()) :: map
  def info(name) when is_atom(name), do: info(Atanor.Registry.config(name))

  def info(%Config{} = config) do
    %{
      id: config.release.id,
      atanor: vsn(:atanor),
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)),
      alambique: vsn(:alambique),
      built_at: config.release.built_at,
      nifs: if(config.release.hash_nifs, do: nifs(), else: %{})
    }
  end

  @doc "The release id of an instance, for telemetry and breadcrumbs."
  @spec id(atom | Config.t()) :: String.t()
  def id(name) when is_atom(name), do: Atanor.Registry.config(name).release.id
  def id(%Config{release: release}), do: release.id

  # -- NIF hashes -------------------------------------------------------------

  defp nifs do
    %{
      "atanor_wasm" => nif(:atanor, "atanor_wasm.so"),
      "alambique_nif" => nif(:alambique, "alambique_nif.so")
    }
  end

  defp nif(app, file) do
    case :code.priv_dir(app) do
      dir when is_list(dir) ->
        path = dir |> to_string() |> Path.join("native/" <> file)
        nif_info(path)

      _ ->
        %{path: nil, sha256: nil}
    end
  end

  defp nif_info(path) do
    case File.stat(path) do
      {:ok, %{size: size, mtime: mtime}} ->
        key = {__MODULE__, :nif, path, size, mtime}

        sha =
          case :persistent_term.get(key, nil) do
            nil ->
              value =
                case File.read(path) do
                  {:ok, bytes} -> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
                  {:error, _} -> nil
                end

              :persistent_term.put(key, value)
              value

            value ->
              value
          end

        %{path: path, sha256: sha}

      {:error, _} ->
        %{path: path, sha256: nil}
    end
  end

  defp vsn(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      value -> to_string(value)
    end
  end
end
