defmodule Atanor.Disk do
  @moduledoc """
  The disk budget of a node (design §4.4): how many bytes `data_dir` may hold, the Alambique options that
  follow from it, and the monitor that keeps the node under it.

  The budget is `disk: [max_bytes:]`, or `disk: [fraction:]` (0.8) of the file system that holds `data_dir`.
  Every `disk: [sample_ms:]` the monitor adds up the files of `data_dir` and escalates:

    * at `evict_fraction` of the budget it hibernates the idle cells with the biggest `-wal` files (a
      hibernation checkpoints, which truncates the WAL); the local cache then drops their files;
    * at `refuse_fraction` the ingress refuses requests with 503 `overloaded` (`Atanor.Admission`), until the
      use falls 5 points below.

  `level/3` is the pure decision, which the property tests check.
  """
  use GenServer

  alias Atanor.Admission

  @mib 1_048_576
  # Alambique's `awake: [max_cells:]` default: the cells a node may hold when the operator does not say.
  @expected_cells 20_000
  @max_wal 64 * @mib
  @min_wal @mib
  @escalated_ms 1_000
  @reclaim_batch 64
  @reclaim_timeout_ms 15_000

  ## Budget

  @doc """
  `{bytes, source}` of the budget: `:option` for `max_bytes`, `:filesystem` for a share of the file system
  that holds `data_dir` (read with the `probe` of the options), `:none` when it cannot be known.
  """
  @spec budget(map, Path.t()) :: {pos_integer | nil, :option | :filesystem | :none}
  def budget(%{max_bytes: bytes}, _data_dir) when is_integer(bytes), do: {bytes, :option}

  def budget(%{fraction: fraction, probe: probe}, data_dir) do
    case probe.(existing_ancestor(data_dir)) do
      {:ok, size} when size > 0 -> {max(1, trunc(size * fraction)), :filesystem}
      _ -> {nil, :none}
    end
  end

  # `data_dir` may not exist yet when the options are built: ask the file system of its nearest parent.
  defp existing_ancestor(path) do
    path = Path.expand(path)
    if File.dir?(path) or path == "/", do: path, else: existing_ancestor(Path.dirname(path))
  end

  @doc "The size in bytes of the file system that holds `path` (`df`), the default `probe`."
  @spec filesystem_bytes(Path.t()) :: {:ok, pos_integer} | :error
  def filesystem_bytes(path) do
    with exe when is_binary(exe) <- System.find_executable("df"),
         {out, 0} <- System.cmd(exe, ["-Pk", "--", path], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [_fs, kib | _] <- String.split(line),
         {kib, ""} when kib > 0 <- Integer.parse(kib) do
      {:ok, kib * 1024}
    else
      _ -> :error
    end
  end

  @doc """
  The Alambique options that follow from the budget. An option the operator gave stays as it is.

    * `wal: [checkpoint_bytes:]` is `budget / cells / 2` between 1 MiB and 64 MiB (and at most half the
      budget), `cells` being `awake: [max_cells:]` (20 000 by default);
    * `local_cache: [max_bytes:]` is the budget minus what the WALs of those cells may hold (at most half
      of it), and its rounds run every `sample_ms`.
  """
  @spec alambique_options(keyword, pos_integer | nil, pos_integer) :: keyword
  def alambique_options(alambique, nil, _sample_ms), do: alambique

  def alambique_options(alambique, budget, sample_ms) do
    cells = get_in(alambique, [:awake, :max_cells]) || @expected_cells
    wal = Keyword.get(alambique, :wal, [])

    checkpoint =
      case Keyword.fetch(wal, :checkpoint_bytes) do
        {:ok, bytes} -> bytes
        :error -> checkpoint_bytes(budget, cells)
      end

    alambique = Keyword.put(alambique, :wal, Keyword.put(wal, :checkpoint_bytes, checkpoint))

    case Keyword.get(alambique, :local_cache, []) do
      false ->
        alambique

      cache ->
        allowance = min(div(budget, 2), checkpoint * cells)

        cache =
          cache
          |> Keyword.put_new(:max_bytes, max(budget - allowance, 1))
          |> Keyword.put_new(:interval_ms, sample_ms)

        Keyword.put(alambique, :local_cache, cache)
    end
  end

  @doc "The `-wal` size at which a cell checkpoints, for a budget shared by `cells` cells."
  @spec checkpoint_bytes(pos_integer, pos_integer) :: pos_integer
  def checkpoint_bytes(budget, cells) do
    (budget / cells / 2) |> trunc() |> min(@max_wal) |> max(@min_wal) |> min(max(div(budget, 2), 1))
  end

  ## Decision

  @type levels :: %{reclaim: boolean, refuse: boolean}
  @type level :: :ok | :reclaim | :refuse

  @doc "Where the monitor starts."
  @spec new_levels() :: levels
  def new_levels, do: %{reclaim: false, refuse: false}

  @doc """
  `hold(on?, bytes, on_at, off_at)`: a verdict that turns on at `on_at`, off below `off_at`, and holds
  between them. Shared by the escalation and by `Atanor.Admission`.
  """
  @spec hold(boolean, number, number, number) :: boolean
  def hold(on?, bytes, on_at, off_at) do
    cond do
      bytes >= on_at -> true
      bytes < off_at -> false
      true -> on?
    end
  end

  @doc """
  The escalation for `used` bytes of a `budget` (`evict_fraction`, `refuse_fraction`, 5 points of hysteresis),
  from the levels of the last sample: `:ok`, `:reclaim` (hibernate idle cells) or `:refuse` (as well).
  It never falls as `used` rises, whatever the levels before.
  """
  @spec level(levels, non_neg_integer, map) :: {level, levels}
  def level(levels, used, %{budget: budget, evict_fraction: evict, refuse_fraction: refuse}) do
    gap = Admission.hysteresis()

    levels = %{
      reclaim: hold(levels.reclaim, used, budget * evict, budget * (evict - gap)),
      refuse: hold(levels.refuse, used, budget * refuse, budget * (refuse - gap))
    }

    level =
      cond do
        levels.refuse -> :refuse
        levels.reclaim -> :reclaim
        true -> :ok
      end

    {level, levels}
  end

  ## Usage

  @doc """
  `{total, cells}`: the bytes of every file under `dir`, and for each `<id>.cell` directory its id, its bytes
  and the bytes of its `-wal` file. A file that disappears while the walk runs counts for nothing.
  """
  @spec usage(Path.t()) :: {non_neg_integer, [%{id: String.t(), bytes: non_neg_integer, wal: non_neg_integer}]}
  def usage(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, {0, []}, fn name, {total, cells} ->
          path = Path.join(dir, name)

          if String.ends_with?(name, ".cell") do
            {bytes, wal} = cell_usage(path)
            cell = %{id: String.replace_suffix(name, ".cell", ""), bytes: bytes, wal: wal}
            {total + bytes, [cell | cells]}
          else
            {total + tree_bytes(path), cells}
          end
        end)

      {:error, _} ->
        {0, []}
    end
  end

  defp cell_usage(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        Enum.reduce(files, {0, 0}, fn file, {bytes, wal} ->
          size = tree_bytes(Path.join(dir, file))
          {bytes + size, if(String.ends_with?(file, "-wal"), do: wal + size, else: wal)}
        end)

      {:error, _} ->
        {0, 0}
    end
  end

  defp tree_bytes(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} ->
        size

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> Enum.reduce(names, 0, &(tree_bytes(Path.join(path, &1)) + &2))
          {:error, _} -> 0
        end

      _ ->
        0
    end
  end

  ## Monitor

  @doc false
  def child_spec(config), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}}

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @doc "The last `{used_bytes, level}` the monitor of node `name` saw, `nil` before its first sample."
  @spec status(atom) :: {non_neg_integer, level} | nil
  def status(name), do: :persistent_term.get({__MODULE__, name}, nil)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    disk = config.disk

    state = %{
      config: config,
      model: %{budget: disk.budget, evict_fraction: disk.evict_fraction, refuse_fraction: disk.refuse_fraction},
      levels: new_levels()
    }

    {:ok, tick(state)}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{config: config}), do: :persistent_term.erase({__MODULE__, config.name})

  defp tick(%{config: config} = state) do
    {used, cells} = usage(config.data_dir)
    {level, levels} = level(state.levels, used, state.model)

    :persistent_term.put({__MODULE__, config.name}, {used, level})
    Admission.disk_sample(config.name, used)

    :telemetry.execute([:atanor, :disk, :sample], %{used_bytes: used, budget_bytes: state.model.budget}, %{
      instance: config.name,
      level: level
    })

    if level != :ok, do: reclaim(config, used, cells, state.model)

    # Writes can fill the margin within a sample: look more often while escalated.
    Process.send_after(
      self(),
      :tick,
      if(level == :ok, do: config.disk.sample_ms, else: min(config.disk.sample_ms, @escalated_ms))
    )

    %{state | levels: levels}
  end

  # Hibernates idle cells, the biggest WALs first, until the WALs they hold would bring the use below the
  # resume mark of the eviction. A busy cell is skipped: the refusal protects the node while it is.
  defp reclaim(config, used, cells, model) do
    target = used - model.budget * (model.evict_fraction - Admission.hysteresis())

    {chosen, _} =
      cells
      |> Enum.filter(&(&1.wal > 0))
      |> Enum.sort_by(& &1.wal, :desc)
      |> Enum.take(@reclaim_batch)
      |> Enum.reduce_while({[], 0}, fn cell, {chosen, freed} ->
        if freed >= target, do: {:halt, {chosen, freed}}, else: {:cont, {[cell | chosen], freed + cell.wal}}
      end)

    alambique = config.alambique

    hibernated =
      chosen
      |> Task.async_stream(&hibernate(alambique, &1.id),
        max_concurrency: 8,
        timeout: @reclaim_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.count(&(&1 == {:ok, :ok}))

    :telemetry.execute([:atanor, :disk, :reclaim], %{candidates: length(chosen), hibernated: hibernated}, %{
      instance: config.name
    })
  end

  defp hibernate(alambique, id) do
    case Alambique.load(alambique, id) do
      {:ok, %{pending: 0}} -> Alambique.hibernate(alambique, id, timeout: @reclaim_timeout_ms)
      _ -> :skipped
    end
  end
end
