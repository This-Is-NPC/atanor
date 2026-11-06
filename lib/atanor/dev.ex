defmodule Atanor.Dev do
  @moduledoc """
  A single local node for development (design §6): `mix atanor.dev` calls
  `start/1`. The node holds no deployments of its own: `deploy/2` publishes a
  worker's package into the node's store and activates it, in-process; deployers
  use the `atanor` command (docs/cli.md) instead.
  """

  @compile {:no_warn_undefined, AlambiqueTestkit.MemoryStore}

  alias Atanor.{Deployments, Package, Registry}
  alias Atanor.Dev.SeaweedFS

  @doc """
  Starts an Atanor instance linked to the caller over the in-memory store, or
  over the local SeaweedFS with `store: :seaweedfs`, and deploys `:workers`,
  a list of manifest maps whose modules are compiled in this VM. Options:
  `:port`, `:data_dir`, `:store`, `:bucket` (SeaweedFS), `:workers`, plus any
  option of `Atanor`.
  """
  @spec start(keyword) :: {:ok, pid} | {:error, term}
  def start(opts) do
    {store, opts} = Keyword.pop(opts, :store, :memory)
    {workers, opts} = Keyword.pop(opts, :workers, [])
    {bucket, opts} = Keyword.pop(opts, :bucket)
    name = Keyword.get(opts, :name, Atanor)

    with {:ok, sup} <- Supervisor.start_link([{Atanor, [store: store(store, bucket)] ++ opts}], strategy: :one_for_one) do
      case deploy_all(name, workers) do
        :ok ->
          {:ok, sup}

        {:error, _} = error ->
          Supervisor.stop(sup)
          error
      end
    end
  end

  @doc """
  Publishes the package of a worker, activates it and waits until this node
  applied it. `dir` is where a WASM manifest's component file is. Returns the
  deployment, or the reason the node could not apply it.
  """
  @spec deploy(atom, map, Path.t()) :: {:ok, Atanor.Deployment.t()} | {:error, term}
  def deploy(instance, manifest_map, dir \\ ".") do
    with {:ok, package} <- Package.from_project(manifest_map, dir),
         {:ok, id} <- Deployments.publish(instance, package),
         worker = package.manifest.name,
         {:ok, _head} <- Deployments.activate(instance, worker, id),
         :ok <- Deployments.sync(instance) do
      case Deployments.status(instance) do
        %{^worker => %{error: nil}} -> Registry.deployment(instance, worker)
        %{^worker => %{error: error}} -> {:error, error}
        _ -> {:error, :not_applied}
      end
    end
  end

  @doc "Deactivates a worker and waits until this node stopped serving it."
  @spec undeploy(atom, String.t()) :: {:ok, Deployments.Head.t()} | {:error, term}
  def undeploy(instance, worker) do
    with {:ok, head} <- Deployments.deactivate(instance, worker),
         :ok <- Deployments.sync(instance),
         do: {:ok, head}
  end

  defp deploy_all(name, workers) do
    Enum.reduce_while(workers, :ok, fn manifest, :ok ->
      case deploy(name, manifest) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:worker_not_deployed, manifest["name"], reason}}}
      end
    end)
  end

  defp store(:memory, _bucket) do
    {:ok, pid} = AlambiqueTestkit.MemoryStore.start_link()
    {AlambiqueTestkit.MemoryStore, AlambiqueTestkit.MemoryStore.config(pid)}
  end

  defp store(:seaweedfs, bucket), do: {Alambique.Store.S3, SeaweedFS.config(bucket)}
end
