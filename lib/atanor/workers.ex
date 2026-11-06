defmodule Atanor.Workers do
  @moduledoc """
  Registration of deployments on a node (design §5) and the execution of a
  native deployment's request handler.
  """

  require Logger

  @handlers [
    plug: 1,
    handle_request: 2,
    handle_ws: 3,
    handle_tcp: 3,
    ranch_protocol: 1,
    handle_alarm: 3,
    handle_job: 2
  ]

  alias Atanor.{Deployment, Deployments, Env, Migrations, Package, Registry, Request, Response, TCP, Wasm}
  alias Atanor.Diagnostics.Breadcrumb

  @doc """
  Builds the deployment of `package` and makes it the worker's active one.
  Refused when a namespace belongs to another worker (design §3.3), the code
  does not match (`{:code_mismatch, expected, loaded}`), the module is not a
  worker, or the registry refuses it (design §4.1, §7.1).
  """
  @spec activate(atom, Package.t()) :: {:ok, Deployment.t()} | {:error, term}
  def activate(instance, %Package{} = package) do
    # New TCP listeners open first, so a port that cannot be bound refuses the
    # activation; listeners nobody claims anymore close afterwards.
    result =
      Breadcrumb.wrap(
        instance,
        %{kind: "deployment", worker: package.manifest.name, package: package.id},
        fn ->
          with :ok <- Deployments.claim_namespaces(instance, package.manifest),
               {:ok, deployment} <- build(instance, package),
               :ok <- TCP.open(instance, for({:tcp, listener, _protocol} <- package.manifest.routes, do: listener)),
               {:ok, changed} <- Registry.put(instance, deployment) do
            Migrations.migrate_awake(instance, changed)
            {:ok, deployment}
          end
        end
      )

    TCP.sync(instance)
    result
  end

  @doc """
  The deployment `id` of `worker` on this node, for a request forwarded from
  a node that pinned it (design §8, D1). The active deployment when it has that
  id; otherwise the package is fetched by id, built and kept apart from the
  registry, so it serves no routes and replaces nothing.
  """
  @spec pinned(atom, String.t(), String.t()) :: {:ok, Deployment.t()} | {:error, term}
  def pinned(instance, worker, id) do
    with :error <- active(instance, worker, id),
         :error <- Registry.pinned(instance, id) do
      with {:ok, %Package{manifest: %{name: ^worker}} = package} <- Deployments.fetch_package(instance, id),
           {:ok, deployment} <- build(instance, package) do
        Registry.put_pinned(instance, deployment)
        {:ok, deployment}
      else
        {:ok, %Package{manifest: %{name: other}}} -> {:error, {:package_of_other_worker, other, worker}}
        {:error, _} = error -> error
      end
    end
  end

  defp active(instance, worker, id) do
    case Registry.deployment(instance, worker) do
      {:ok, %Deployment{id: ^id} = deployment} -> {:ok, deployment}
      _ -> :error
    end
  end

  @doc "Removes the worker, its routes and the TCP listeners nobody claims anymore."
  @spec deactivate(atom, String.t()) :: :ok | {:error, :not_active}
  def deactivate(instance, worker) do
    result = Registry.delete(instance, worker)
    TCP.sync(instance)
    result
  end

  # TCP is native-only for now (design §3.2).
  defp build(instance, %Package{manifest: %{kind: :wasm} = manifest} = package) do
    if Enum.any?(manifest.routes, &match?({:tcp, _, _}, &1)),
      do: {:error, {:unsupported_for_wasm, :tcp}},
      else: Wasm.build(instance, package)
  end

  defp build(_instance, %Package{manifest: %{kind: :native} = manifest, id: id, md5: expected}) do
    with {:ok, module} <- Package.load_module(manifest.module),
         :ok <- behaviour(module),
         md5 = module.module_info(:md5),
         :ok <- same_code(expected, md5),
         :ok <- callbacks(module, manifest) do
      {:ok,
       %Deployment{
         id: id,
         manifest: manifest,
         module: module,
         plug?: function_exported?(module, :plug, 1),
         request?: function_exported?(module, :handle_request, 2),
         ws?: function_exported?(module, :handle_ws, 3),
         local_ws?: function_exported?(module, :handle_ws_local, 3)
       }}
    end
  end

  # What the manifest promises must exist in the module.
  defp callbacks(module, manifest) do
    cond do
      Enum.any?(manifest.routes, &match?({:tcp, _, :thousand_island}, &1)) and
          not function_exported?(module, :handle_tcp, 3) ->
        {:error, {:missing_callback, module, {:handle_tcp, 3}}}

      Enum.any?(manifest.routes, &match?({:tcp, _, :ranch}, &1)) and
          not function_exported?(module, :ranch_protocol, 1) ->
        {:error, {:missing_callback, module, {:ranch_protocol, 1}}}

      manifest.alarms and not function_exported?(module, :handle_alarm, 3) ->
        {:error, {:missing_callback, module, {:handle_alarm, 3}}}

      manifest.jobs and not function_exported?(module, :handle_job, 2) ->
        {:error, {:missing_callback, module, {:handle_job, 2}}}

      true ->
        :ok
    end
  end

  defp same_code(expected, md5) do
    loaded = Base.encode16(md5, case: :lower)
    if loaded == expected, do: :ok, else: {:error, {:code_mismatch, expected, loaded}}
  end

  @doc """
  Runs the deployment's `handle_request/2`. Returns the response, or an error
  when the worker crashed or returned something else; the failure is logged
  with the worker and deployment.
  """
  @spec invoke(Env.t(), Request.t()) :: {:ok, Response.t()} | {:error, term}
  def invoke(%Env{deployment: %{manifest: %{kind: :wasm}} = deployment} = env, %Request{} = request),
    do: Wasm.invoke(deployment, request, env)

  def invoke(%Env{deployment: deployment} = env, %Request{} = request) do
    case deployment.module.handle_request(request, env) do
      response when is_struct(response, Response) ->
        if Response.valid?(response), do: {:ok, response}, else: bad_response(deployment, response)

      other ->
        bad_response(deployment, other)
    end
  catch
    kind, reason ->
      log(deployment, "crashed", format_crash(kind, reason, __STACKTRACE__))
      {:error, :crashed}
  end

  @doc false
  # `Exception.format/3` prints the arguments of the failing call (a request, a Plug.Conn with its headers,
  # TLS options). The stacktrace goes with arities, which also stops the blame of a FunctionClauseError.
  def format_crash(kind, reason, stacktrace) do
    stacktrace = for {module, function, args, location} <- stacktrace, do: {module, function, arity(args), location}
    Exception.format(kind, reason, stacktrace)
  end

  defp arity(args) when is_list(args), do: length(args)
  defp arity(arity), do: arity

  @doc false
  def log(deployment, what, detail),
    do: Logger.error("worker #{Deployment.worker(deployment)} (deployment #{deployment.id}) #{what}: #{detail}")

  defp bad_response(deployment, value) do
    log(deployment, "returned an invalid response", inspect(value, limit: 20))
    {:error, :bad_response}
  end

  defp behaviour(module) do
    behaviours = module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    cond do
      Atanor.Worker not in behaviours ->
        {:error, {:not_a_worker, module}}

      not Enum.any?(@handlers, fn {name, arity} -> function_exported?(module, name, arity) end) ->
        {:error, {:no_handler, module}}

      true ->
        :ok
    end
  end
end
