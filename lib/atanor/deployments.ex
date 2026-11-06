defmodule Atanor.Deployments do
  @moduledoc """
  Deployments by hash (design §5): packages in the store, and a head per
  worker that says which package is active.

  `store` is a running instance (its name) or an `Atanor.Store.handle/0`. A
  head changes with a compare-and-swap on its etag, retried on conflict, so
  concurrent changes never lose an update. Changes made through an instance
  also notify the nodes that share its store; changes made through a handle
  reach nodes on their next poll.

  A node applies the heads it sees with `Atanor.Deployments.Watcher`.
  `workers/1` pages the metadata store with the instance's `metadata.page_size`
  (1,000 by default); a store handle uses the same default.
  """

  alias Atanor.{Manifest, Package, Registry, Store}
  alias Atanor.Deployments.{Head, Watcher}

  @defaults %{max_previous: 20, max_attempts: 16}
  @default_page_size 1_000

  @doc "The defaults of the head history and the compare-and-swap attempts."
  @spec defaults() :: map
  def defaults, do: @defaults

  @doc "Stores the package once, under its id. An existing package is left as it is."
  @spec publish(Store.t(), Package.t()) :: {:ok, String.t()} | {:error, term}
  def publish(store, %Package{id: id, bytes: bytes}) do
    case Store.put(store, "packages/" <> id, bytes, :if_none_match) do
      {:ok, _etag} -> {:ok, id}
      {:error, :precondition_failed} -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  @doc "Reads a package and checks that its bytes hash to `id`."
  @spec fetch_package(Store.t(), String.t()) :: {:ok, Package.t()} | {:error, term}
  def fetch_package(store, id) do
    with {:ok, bytes, _etag, _meta} <- Store.get(store, "packages/" <> id),
         {:ok, %Package{id: ^id} = package} <- Package.parse(bytes, package_limits(store)) do
      {:ok, package}
    else
      {:ok, %Package{id: other}} -> {:error, {:package_id_mismatch, id, other}}
      {:error, _} = error -> error
    end
  end

  @doc "The size limits for the packages of `store`: the instance's `:package` option, or the defaults."
  @spec package_limits(Store.t()) :: map
  def package_limits(store) when is_atom(store), do: Registry.config(store).package
  def package_limits(_store), do: Package.limits()

  @doc "The head of a worker."
  @spec head(Store.t(), String.t()) :: {:ok, Head.t()} | {:error, :not_found | term}
  def head(store, worker) do
    with {:ok, head, _etag} <- read(store, worker), do: {:ok, head}
  end

  @doc "The heads of all workers, ordered by name."
  @spec list(Store.t()) :: {:ok, [Head.t()]} | {:error, term}
  def list(store) do
    with {:ok, workers} <- workers(store) do
      workers
      |> Enum.reduce_while({:ok, []}, fn worker, {:ok, acc} ->
        case head(store, worker) do
          {:ok, head} -> {:cont, {:ok, [head | acc]}}
          {:error, :not_found} -> {:cont, {:ok, acc}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, heads} -> {:ok, Enum.reverse(heads)}
        error -> error
      end
    end
  end

  @doc "The names of the workers that have a head, ordered."
  @spec workers(Store.t()) :: {:ok, [String.t()]} | {:error, term}
  def workers(store), do: workers(store, nil, [])

  defp workers(store, start_after, acc) do
    with {:ok, keys, next} <- Store.list(store, "workers/", start_after, page_size(store)) do
      acc = acc ++ for("workers/" <> rest <- keys, [worker, "head"] <- [String.split(rest, "/")], do: worker)
      if next, do: workers(store, next, acc), else: {:ok, acc}
    end
  end

  @doc """
  Makes package `id` the active one of `worker`; the previous active one goes
  to the head of `previous`, which keeps `:deployments`' `:max_previous`. The
  package must be in the store and belong to `worker`. Activating the active
  package changes nothing. Options: `:max_previous` and `:max_attempts`; the
  instance's `:deployments` settings are the defaults when `store` is an
  instance name, and `defaults/0` otherwise.
  """
  @spec activate(Store.t(), String.t(), String.t(), keyword) :: {:ok, Head.t()} | {:error, term}
  def activate(store, worker, id, opts \\ []) do
    settings = settings(store, opts)

    with :ok <- check_worker(worker),
         :ok <- check_id(id),
         {:ok, package} <- fetch_package(store, id),
         :ok <- check_owner(package, worker),
         :ok <- check_package(store, package) do
      update(
        store,
        worker,
        fn
          %Head{active: ^id} = head -> {:keep, head}
          head -> {:change, %{head | active: id, previous: push(head, settings.max_previous)}}
        end,
        settings
      )
    end
  end

  @doc "Returns `worker` to its previous package, which leaves `previous`. Takes the options of `activate/4`."
  @spec rollback(Store.t(), String.t(), keyword) :: {:ok, Head.t()} | {:error, :no_previous | term}
  def rollback(store, worker, opts \\ []) do
    with :ok <- check_previous(store, worker) do
      update(
        store,
        worker,
        fn
          %Head{previous: [id | rest]} = head -> {:change, %{head | active: id, previous: rest}}
          _ -> {:error, :no_previous}
        end,
        settings(store, opts)
      )
    end
  end

  # The package a rollback returns to obeys the same rules as one that is activated.
  defp check_previous(store, worker) do
    case head(store, worker) do
      {:ok, %Head{previous: [id | _]}} ->
        with {:ok, package} <- fetch_package(store, id), do: check_package(store, package)

      _ ->
        :ok
    end
  end

  @doc "Makes `worker` inactive: the head stays, with no active package. Takes the options of `activate/4`."
  @spec deactivate(Store.t(), String.t(), keyword) :: {:ok, Head.t()} | {:error, :not_found | term}
  def deactivate(store, worker, opts \\ []) do
    settings = settings(store, opts)

    update(
      store,
      worker,
      fn
        %Head{revision: 0} -> {:error, :not_found}
        %Head{active: nil} = head -> {:keep, head}
        head -> {:change, %{head | active: nil, previous: push(head, settings.max_previous)}}
      end,
      settings
    )
  end

  @doc """
  What this node applied for each worker: the head's package, the one being
  served, and why the head could not be applied, such as
  `{:code_mismatch, expected_md5, loaded_md5}`.
  """
  @spec status(atom) :: %{String.t() => %{head: String.t() | nil, applied: String.t() | nil, error: term}}
  defdelegate status(instance), to: Watcher

  @doc "Reloads the heads from the store now and applies them on this node."
  @spec sync(atom) :: :ok
  defdelegate sync(instance), to: Watcher

  defp push(%Head{active: nil, previous: previous}, _max_previous), do: previous
  defp push(%Head{active: active, previous: previous}, max_previous), do: Enum.take([active | previous], max_previous)

  @doc "Checks that `worker` is a valid worker name."
  @spec check_worker(term) :: :ok | {:error, :invalid_worker}
  def check_worker(worker),
    do: if(Manifest.worker_name?(worker), do: :ok, else: {:error, :invalid_worker})

  # What a head may point to is checked before it is written (design §3.3, §5.2): the registry's rules as this node
  # would apply them, then the namespaces the package claims, then their partitions. A node applies the same
  # rules (`Atanor.Workers.activate/2`), so a head that got into the store another way is refused there too.
  defp check_package(store, %Package{manifest: manifest} = package) do
    with :ok <- if(is_atom(store), do: Registry.check(store, manifest), else: :ok),
         :ok <- claim_namespaces(store, manifest),
         do: check_partitions(store, package)
  end

  @doc """
  Checks that `manifest`'s worker may use the cell namespaces it declares, and records it as their owner when
  nobody owns them yet (design §3.3). A namespace in the operator's `:namespaces` is open to the workers listed
  there only; any other belongs to the first worker that claimed it, for good: the record survives the worker
  being deactivated, so a name cannot be taken over. The record is a conditional write, so the store, not the
  order in which a node applies heads, decides between two claimants. Errors: `{:namespace_not_allowed, ns,
  worker}`, `{:namespace_owned, ns, owner}` and `{:store_unavailable, reason}`.
  """
  @spec claim_namespaces(Store.t(), Manifest.t()) :: :ok | {:error, term}
  def claim_namespaces(store, %Manifest{name: worker, cells: cells}) do
    listed = if is_atom(store), do: Registry.config(store).namespaces

    Enum.reduce_while(cells, :ok, fn {ns, _migrations}, :ok ->
      case claim_namespace(store, listed && listed[ns], ns, worker) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp claim_namespace(store, nil, ns, worker) do
    case Store.get(store, "owners/" <> ns) do
      {:ok, ^worker, _etag, _meta} -> :ok
      {:ok, owner, _etag, _meta} -> {:error, {:namespace_owned, ns, owner}}
      {:error, :not_found} -> record_owner(store, ns, worker)
      {:error, reason} -> {:error, {:store_unavailable, reason}}
    end
  end

  defp claim_namespace(_store, workers, ns, worker),
    do: if(worker in workers, do: :ok, else: {:error, {:namespace_not_allowed, ns, worker}})

  defp record_owner(store, ns, worker) do
    case Store.put(store, "owners/" <> ns, worker, :if_none_match) do
      {:ok, _etag} -> :ok
      {:error, :precondition_failed} -> claim_namespace(store, nil, ns, worker)
      {:error, reason} -> {:error, {:store_unavailable, reason}}
    end
  end

  # The number of partitions of a namespace is fixed for the life of its data (design §4.2). The first
  # activation that declares it records the number in the store; a package that declares another number,
  # or none, is refused. A namespace that already has cells cannot become partitioned.
  defp check_partitions(store, %Package{manifest: manifest}) do
    Enum.reduce_while(manifest.cells, :ok, fn {ns, _}, :ok ->
      case claim_partitions(store, ns, manifest.partitions[ns]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp claim_partitions(store, ns, declared) do
    case Store.get(store, "partitions/" <> ns) do
      {:ok, body, _etag, _meta} ->
        recorded = String.to_integer(body)
        if recorded == declared, do: :ok, else: {:error, {:partitions_changed, ns, recorded, declared}}

      {:error, :not_found} when is_nil(declared) ->
        :ok

      {:error, :not_found} ->
        with :ok <- check_empty(store, ns), do: record_partitions(store, ns, declared)

      {:error, _} = error ->
        error
    end
  end

  defp record_partitions(store, ns, declared) do
    case Store.put(store, "partitions/" <> ns, Integer.to_string(declared), :if_none_match) do
      {:ok, _etag} -> :ok
      {:error, :precondition_failed} -> claim_partitions(store, ns, declared)
      {:error, _} = error -> error
    end
  end

  # With a running instance, the namespace must have no cell in any location. A store handle cannot list cells.
  defp check_empty(store, ns) when is_atom(store) do
    alambique = Registry.config(store).alambique

    Enum.reduce_while(Alambique.Feed.ctx(alambique).locations, :ok, fn location, :ok ->
      case Alambique.list_cells(alambique, location: location, prefix: ns <> ".", limit: 1) do
        {:ok, %{cells: []}} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, {:namespace_has_data, ns}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_empty(_store, _ns), do: :ok

  defp check_id(id), do: if(Head.id?(id), do: :ok, else: {:error, :invalid_id})

  defp check_owner(%Package{manifest: %{name: worker}}, worker), do: :ok
  defp check_owner(%Package{manifest: %{name: name}}, worker), do: {:error, {:package_of_other_worker, name, worker}}

  defp read(store, worker) do
    with :ok <- check_worker(worker),
         {:ok, json, etag, _meta} <- Store.get(store, key(worker)),
         {:ok, head} <- Head.decode(json) do
      {:ok, head, etag}
    end
  end

  defp key(worker), do: "workers/#{worker}/head"

  # Compare-and-swap loop: `fun` sees the current head and returns the new
  # one, or says to keep it or fail.
  defp update(store, worker, fun, settings, attempt \\ 1) do
    {head, condition} =
      case read(store, worker) do
        {:ok, head, etag} -> {head, {:if_match, etag}}
        {:error, :not_found} -> {%Head{worker: worker}, :if_none_match}
        {:error, _} = error -> throw(error)
      end

    case fun.(head) do
      {:keep, head} -> {:ok, head}
      {:error, _} = error -> error
      {:change, new} -> write(store, worker, new, condition, fun, settings, attempt)
    end
  catch
    {:error, _} = error -> error
  end

  defp write(store, worker, head, condition, fun, settings, attempt) do
    head = %{head | revision: head.revision + 1, updated_at: DateTime.to_iso8601(DateTime.utc_now())}

    case Store.put(store, key(worker), Head.encode(head), condition) do
      {:ok, _etag} ->
        if is_atom(store), do: Watcher.notify(store, worker)
        {:ok, head}

      {:error, :precondition_failed} when attempt < settings.max_attempts ->
        update(store, worker, fun, settings, attempt + 1)

      {:error, :precondition_failed} ->
        {:error, :conflict}

      {:error, _} = error ->
        error
    end
  end

  defp page_size(store) when is_atom(store), do: Registry.config(store).metadata.page_size
  defp page_size(_store), do: @default_page_size

  defp settings(store, opts) do
    base = if is_atom(store), do: Registry.config(store).deployments, else: @defaults

    valid? =
      Keyword.keyword?(opts) and
        Enum.all?(opts, fn {key, value} ->
          is_map_key(@defaults, key) and is_integer(value) and value > 0
        end)

    unless valid? do
      raise ArgumentError,
            "deployment options must be positive integers for #{inspect(Map.keys(@defaults))}"
    end

    Map.merge(base, Map.new(opts))
  end
end
