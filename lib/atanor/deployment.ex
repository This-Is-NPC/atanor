defmodule Atanor.Deployment do
  @moduledoc """
  An activated version of a worker (design §5): the manifest and the loaded
  module (for WASM, `Atanor.Wasm` and the linked component in `wasm`). `id` is
  the id of its package.
  """

  @enforce_keys [:id, :manifest, :module]
  defstruct [:id, :manifest, :module, :wasm, plug?: false, request?: false, ws?: false, local_ws?: false]

  @type t :: %__MODULE__{
          id: String.t(),
          manifest: Atanor.Manifest.t(),
          module: module,
          wasm: reference | nil,
          plug?: boolean,
          request?: boolean,
          ws?: boolean,
          local_ws?: boolean
        }

  @doc "The worker's name."
  def worker(%__MODULE__{manifest: %{name: name}}), do: name
end
