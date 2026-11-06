defmodule Atanor.Diagnostics.Breadcrumb do
  @moduledoc false
  # A unit's marker file (design §17.2). The first byte is 1 while the unit
  # runs and 0 otherwise; a VM crash leaves it at 1. The tracker removes the
  # file when the holder process ends, so only a VM crash produces a report.

  require Logger

  alias Atanor.{Cell, Diagnostics, Release, Registry}

  defstruct [:fd, :path, :instance]

  @type t :: %__MODULE__{fd: :file.fd(), path: Path.t(), instance: atom} | nil

  @doc "Opens an idle marker for the calling process; `nil` when diagnostics are off."
  @spec open(atom, map) :: t
  def open(instance, meta) do
    config = Registry.config(instance)

    if config.diagnostics.enabled and config.diagnostics.breadcrumbs != :off do
      dir = Path.join(config.diagnostics.dir, "units")
      path = Path.join(dir, "#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}")
      body = [<<0>>, Jason.encode!(normalize(meta, instance))]

      with {:ok, fd} <- open_file(path, dir, body) do
        Diagnostics.track(instance, self(), path)
        %__MODULE__{fd: fd, path: path, instance: instance}
      else
        {:error, reason} ->
          Logger.warning("atanor: could not create a crash breadcrumb #{path}: #{inspect(reason)}")
          nil
      end
    end
  end

  @doc "Marks the unit busy."
  @spec hold(t) :: :ok
  def hold(nil), do: :ok
  def hold(%__MODULE__{fd: fd}), do: pwrite(fd, <<1>>)

  @doc "Marks the unit idle."
  @spec release(t) :: :ok
  def release(nil), do: :ok
  def release(%__MODULE__{fd: fd}), do: pwrite(fd, <<0>>)

  @doc "Marks idle, closes and removes the marker."
  @spec close(t) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{fd: fd, path: path, instance: instance}) do
    pwrite(fd, <<0>>)
    :file.close(fd)
    File.rm(path)
    Diagnostics.untrack(instance, path)
    :ok
  end

  @doc "Runs `fun` with a busy marker, and removes the marker afterwards."
  @spec wrap(atom, map, (-> result)) :: result when result: term
  def wrap(instance, meta, fun) do
    breadcrumb = open(instance, meta)

    try do
      hold(breadcrumb)
      fun.()
    after
      close(breadcrumb)
    end
  end

  @doc "Like `wrap/3`, only under `diagnostics.breadcrumbs: :all` (HTTP and TCP callbacks)."
  @spec callback(atom, map, (-> result)) :: result when result: term
  def callback(instance, meta, fun) do
    if Registry.config(instance).diagnostics.breadcrumbs == :all, do: wrap(instance, meta, fun), else: fun.()
  end

  defp open_file(path, dir, body) do
    case :file.open(path, [:raw, :binary, :read, :write, :exclusive]) do
      {:ok, fd} ->
        case :file.write(fd, body) do
          :ok ->
            {:ok, fd}

          {:error, _} = error ->
            :file.close(fd)
            File.rm(path)
            error
        end

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(dir), do: open_file(path, dir, body)

      {:error, _} = error ->
        error
    end
  end

  defp pwrite(fd, byte) do
    case :file.pwrite(fd, 0, byte) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp normalize(meta, instance) do
    config = Registry.config(instance)

    meta
    |> Map.put_new(:release, Release.id(config))
    |> Map.put_new(:started_at_ms, System.os_time(:millisecond))
    |> Map.put_new(:unit_id, Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
    |> Map.new(fn {key, value} -> {to_string(key), value(value)} end)
  end

  defp value({:cell, nil}), do: nil
  defp value({:cell, _} = cell), do: cell_string(cell)
  defp value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp value(value) when is_atom(value), do: Atom.to_string(value)
  defp value(value), do: inspect(value)

  defp cell_string({:cell, {ns, key}}) do
    case Cell.id({ns, key}) do
      {:ok, id} -> id
      _ -> "#{ns}.#{key}"
    end
  end
end
