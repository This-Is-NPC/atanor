defmodule Atanor.DaemonDocsTest do
  @moduledoc "The key table of docs/configuration.md lists every key of Atanor.Daemon and nothing else."
  use ExUnit.Case, async: true

  alias Atanor.Daemon

  @doc_path Path.expand("../../docs/configuration.md", __DIR__)

  # The rows of the first table under "The daemon": {variables of column 1, file keys of column 2}.
  defp rows do
    @doc_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "| Variable | File key")))
    |> Enum.drop(2)
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.map(fn line ->
      [variables, file_keys | _] = line |> String.split("|", trim: true) |> Enum.map(&String.trim/1)
      {names(variables), names(file_keys)}
    end)
  end

  defp names(cell), do: for([_, name] <- Regex.scan(~r/`([^`]+)`/, cell), do: name)

  test "every key and boot variable is in the table" do
    listed = rows() |> Enum.flat_map(&elem(&1, 0))

    for {name, _type, _doc} <- Daemon.keys(), do: assert(name in listed, "#{name} is not in the table")
    for name <- Daemon.boot_variables(), do: assert(name in listed)
  end

  test "the table names no unknown variable" do
    listed = rows() |> Enum.flat_map(&elem(&1, 0)) |> Enum.filter(&String.starts_with?(&1, ["ATANOR_", "AWS_"]))
    assert listed != []
    assert listed -- Daemon.known_variables() == []
  end

  test "the file keys of the table are the file keys of the variables" do
    file_keys = rows() |> Enum.flat_map(&elem(&1, 1)) |> Enum.reject(&(&1 == "environment only"))
    expected = for {name, type, _} <- Daemon.keys(), type != :boot, do: file_key(name)

    assert Enum.sort(file_keys -- ["none"]) == Enum.sort(expected)
  end

  defp file_key("ATANOR_" <> rest), do: String.downcase(rest)
  defp file_key(name), do: String.downcase(name)
end
