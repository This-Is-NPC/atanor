defmodule Atanor.Migrations do
  @moduledoc """
  The migrations Alambique applies when a cell wakes (design §4.1), and the
  migration of cells that are already awake when a worker brings new ones.
  """

  require Logger

  alias Alambique.Tx
  alias Atanor.{Cell, Registry}
  alias Atanor.Diagnostics.Breadcrumb

  @doc "The `{module, function, extra_args}` for Alambique's `:migrations` option: `for_cell(id, name)`."
  @spec callback(atom) :: {module, :for_cell, [atom]}
  def callback(name), do: {__MODULE__, :for_cell, [name]}

  @doc """
  The Alambique migrations of cell `id` in instance `name`: those of its
  namespace, none for an id that is not an address, and a raise for a
  namespace no deployment of this node grants, which fails the wake (a node
  that has not applied the worker yet must not create a cell without tables).
  """
  @spec for_cell(String.t(), atom) :: [{pos_integer, (Tx.t() -> :ok)}]
  def for_cell(id, name) do
    case Cell.parse(id) do
      {:ok, {ns, _key}} ->
        case Registry.namespace(name, ns) do
          {:ok, migrations} -> for {version, statements} <- migrations, do: {version, &run(&1, statements)}
          :error -> raise "namespace #{ns} is not granted by any deployment on #{node()}"
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Migrates, in the background, this node's awake cells of `namespaces` to the
  migrations the registry now holds, without waking them again
  (`Alambique.migrate/3`). Emits `[:atanor, :cells, :migrate]` for each namespace.
  Cells that are asleep migrate at their next wake.
  """
  @spec migrate_awake(atom, [String.t()]) :: :ok
  def migrate_awake(_name, []), do: :ok

  def migrate_awake(name, namespaces) do
    {:ok, _} =
      Task.Supervisor.start_child(Atanor.Tasks.name(name), fn -> Enum.each(namespaces, &migrate_namespace(name, &1)) end)

    :ok
  end

  defp migrate_namespace(name, ns) do
    Breadcrumb.wrap(name, %{kind: "migration", namespace: ns}, fn -> do_migrate_namespace(name, ns) end)
  end

  defp do_migrate_namespace(name, ns) do
    config = Registry.config(name)
    alambique = config.alambique
    settings = config.migrate
    opts = if settings.timeout_ms, do: [timeout: settings.timeout_ms], else: []

    results =
      alambique
      |> awake(ns <> ".", settings.page_size)
      |> Stream.chunk_every(settings.page_size)
      |> Stream.flat_map(fn ids ->
        Atanor.Tasks.name(name)
        |> Task.Supervisor.async_stream_nolink(ids, &{&1, Alambique.migrate(alambique, &1, opts)},
          max_concurrency: settings.concurrency,
          timeout: :infinity
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> {nil, {:error, {:exit, reason}}}
        end)
      end)
      |> Enum.to_list()

    errors = for {cell, {:error, reason}} <- results, do: {cell, reason}
    migrated = Enum.count(results, &match?({_, {:ok, version}} when is_integer(version), &1))

    if errors != [],
      do: Logger.warning("atanor: #{length(errors)} cells of #{ns} did not migrate: #{inspect(errors, limit: 5)}")

    :telemetry.execute([:atanor, :cells, :migrate], %{count: migrated, errors: length(errors)}, %{
      namespace: ns,
      node: node()
    })
  end

  # Ids of the cells awake here whose id starts with `prefix`, page by page.
  defp awake(alambique, prefix, page) do
    Stream.resource(
      fn -> prefix end,
      fn
        :done ->
          {:halt, :done}

        cursor ->
          %{cells: cells, next: next} = Alambique.cells(alambique, after: cursor, limit: page)
          mine = Enum.take_while(cells, &String.starts_with?(&1, prefix))
          if next == nil or length(mine) < length(cells), do: {mine, :done}, else: {mine, next}
      end,
      fn _ -> :ok end
    )
  end

  defp run(tx, statements) do
    for statement <- statements do
      case Tx.execute(tx, statement) do
        {:ok, _} -> :ok
        {:error, reason} -> Tx.rollback(tx, reason)
      end
    end

    :ok
  end
end
