defmodule Atanor.Deployments.Service do
  @moduledoc """
  The writes of a deploy (design §5.4), made by the nodes for the admin API:
  deployers send packages to a node (the `atanor` command, docs/cli.md).
  `deploy/4` is also what `atanor deploy --bucket` calls with a store handle,
  for a deployer that holds the bucket credentials.

  `upload/5` takes package bytes from outside: it enforces the size limit,
  checks the SHA-256 the client expects, parses and validates the manifest
  with `Atanor.Package`, and checks that the package belongs to the worker the
  caller is allowed to deploy.
  """

  alias Atanor.Deployments
  alias Atanor.Deployments.{Head, Versions}
  alias Atanor.{Package, Store}

  @doc """
  Stores a built package, records it in the worker's version index
  (`Atanor.Deployments.Versions`) and, with `activate?`, makes it the active
  one. `uploaded_by` is the actor map kept in the index.
  """
  @spec deploy(Store.t(), Package.t(), boolean, map) ::
          {:ok, Package.t(), Head.t() | nil} | {:error, {atom, term}}
  def deploy(store, %Package{} = package, activate?, uploaded_by) do
    with {:ok, id} <- stage(Deployments.publish(store, package), :publish),
         :ok <- stage(Versions.record(store, package, uploaded_by), :publish) do
      if activate? do
        with {:ok, head} <- stage(Deployments.activate(store, package.manifest.name, id), :activate),
             do: {:ok, package, head}
      else
        {:ok, package, nil}
      end
    end
  end

  @doc """
  Validates uploaded bytes for `worker` and deploys them. Options: `:max_bytes`
  and `:uploaded_by` (required), `:activate`. Errors: `:invalid_worker`, `:too_large`, `:invalid_hash`,
  `:hash_mismatch`, `{:invalid_package, reason}`, `{:module_not_loaded, name}`,
  `{:package_of_other_worker, name}` or `{stage, reason}` from `deploy/3`.
  """
  @spec upload(Store.t(), String.t(), binary, String.t(), keyword) ::
          {:ok, Package.t(), Head.t() | nil} | {:error, term}
  def upload(store, worker, bytes, expected_sha256, opts) do
    with :ok <- Deployments.check_worker(worker),
         :ok <- check_size(bytes, Keyword.fetch!(opts, :max_bytes)),
         :ok <- check_hash(bytes, expected_sha256),
         {:ok, package} <- Package.parse(bytes, Deployments.package_limits(store)),
         :ok <- check_worker(package, worker),
         :ok <- check_module(package) do
      deploy(store, package, Keyword.get(opts, :activate, false), Keyword.fetch!(opts, :uploaded_by))
    end
  end

  # The module of a native package must be one the node has: the name is not turned into an atom otherwise.
  defp check_module(%Package{manifest: %{kind: :native, module: module}}),
    do: with({:ok, _} <- Package.load_module(module), do: :ok)

  defp check_module(_package), do: :ok

  defp check_size(bytes, max), do: if(byte_size(bytes) <= max, do: :ok, else: {:error, :too_large})

  defp check_hash(bytes, expected) do
    if Head.id?(expected) do
      actual = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      if Plug.Crypto.secure_compare(actual, expected), do: :ok, else: {:error, :hash_mismatch}
    else
      {:error, :invalid_hash}
    end
  end

  defp check_worker(%Package{manifest: %{name: worker}}, worker), do: :ok
  defp check_worker(%Package{manifest: %{name: name}}, _worker), do: {:error, {:package_of_other_worker, name}}

  defp stage(:ok, _), do: :ok
  defp stage({:ok, _} = ok, _), do: ok
  defp stage({:error, reason}, stage), do: {:error, {stage, reason}}
end
