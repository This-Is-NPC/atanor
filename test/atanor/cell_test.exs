defmodule Atanor.CellTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Alambique.Tx
  alias Atanor.Cell
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @notes Manifests.notes_migrations()
  @v2_v3 [[2, "ALTER TABLE notes ADD COLUMN tag TEXT"], [3, ["UPDATE notes SET tag = 'x'"]]]
  @version "PRAGMA user_version"

  defp node_with(cells, opts \\ []) do
    node = Node.start([workers: [Manifests.probe("cells", cells: cells)]] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  describe "addressing" do
    property "id and parse round trip" do
      check all(
              ns <- string(~c"abcdefghijklmnopqrstuvwxyz0123456789_-", min_length: 1, max_length: 20),
              key <- string([?a..?z, ?A..?Z, ?0..?9, ?_, ?., ?-], min_length: 1, max_length: 60)
            ) do
        assert {:ok, id} = Cell.id({ns, key})
        assert id == ns <> "." <> key
        assert {:ok, {^ns, ^key}} = Cell.parse(id)
      end
    end

    test "namespaces are checked byte by byte" do
      for ns <- ["a", "a_b-1", "0", String.duplicate("z", 200)], do: assert(:ok = Cell.validate_namespace(ns))

      for ns <- ["", "A", "a b", "a.b", "a\n", "caf\u00E9", <<0>>, 1, nil],
          do: assert({:error, :invalid_namespace} = Cell.validate_namespace(ns))
    end

    property "invalid namespaces are rejected" do
      check all(
              ns <- string(:printable, max_length: 10),
              not Regex.match?(~r/\A[a-z0-9_-]+\z/, ns)
            ) do
        assert {:error, :invalid_namespace} = Cell.id({ns, "k"})
      end
    end

    property "keys with a slash or NUL, and empty keys, are rejected" do
      check all(
              prefix <- string(:alphanumeric, max_length: 5),
              bad <- member_of(["/", <<0>>]),
              suffix <- string(:alphanumeric, max_length: 5)
            ) do
        assert {:error, :invalid_key} = Cell.id({"ns", prefix <> bad <> suffix})
      end

      assert {:error, :invalid_key} = Cell.id({"ns", ""})
      assert {:error, :invalid_key} = Cell.id({"ns", :atom})
    end

    test "parse refuses ids that are not addresses" do
      for id <- ["nodots", ".key", "Up.key", "ns.", "ns.a/b"] do
        assert {:error, :invalid_cell_id} = Cell.parse(id)
      end
    end
  end

  describe "calls" do
    setup do
      node = node_with(%{"notes" => @notes, "plain" => []})
      %{name: node.name, node: node}
    end

    test "query, execute and transaction work", %{name: name} do
      cell = {"notes", "a"}
      assert {:ok, _} = Cell.execute(name, cell, "INSERT INTO notes (body) VALUES (?)", ["hi"])
      assert {:ok, %{rows: [["hi"]]}} = Cell.query(name, cell, "SELECT body FROM notes")

      assert {:ok, :done} =
               Cell.transaction(name, cell, fn tx ->
                 {:ok, _} = Tx.execute(tx, "DELETE FROM notes")
                 :done
               end)

      assert {:ok, %{rows: []}} = Cell.query(name, cell, "SELECT body FROM notes")
    end

    test "a read can verify the lease", %{name: name} do
      cell = {"notes", "v"}
      {:ok, _} = Cell.execute(name, cell, "INSERT INTO notes (body) VALUES ('seen')")
      assert {:ok, %{rows: [["seen"]]}} = Cell.query(name, cell, "SELECT body FROM notes", [], verify_lease: true)
    end

    test "cells of one namespace are separate", %{name: name} do
      {:ok, _} = Cell.execute(name, {"notes", "a"}, "INSERT INTO notes (body) VALUES ('x')")
      assert {:ok, %{rows: []}} = Cell.query(name, {"notes", "b"}, "SELECT body FROM notes")
    end

    test "a namespace without migrations leaves the cell at version 0", %{name: name} do
      assert {:ok, _} = Cell.execute(name, {"plain", "a"}, "CREATE TABLE t (x)")
      assert {:ok, %{rows: [[0]]}} = Cell.query(name, {"plain", "a"}, @version)
    end

    test "errors for bad addresses and unknown namespaces", %{name: name} do
      assert {:error, :invalid_namespace} = Cell.query(name, {"Bad", "a"}, "SELECT 1")
      assert {:error, :invalid_key} = Cell.query(name, {"notes", "a/b"}, "SELECT 1")
      assert {:error, {:unknown_namespace, "other"}} = Cell.query(name, {"other", "a"}, "SELECT 1")
      assert {:error, :invalid_address} = Cell.query(name, "notes.a", "SELECT 1")
    end

    test "migrations apply once and persist across hibernation", %{name: name} do
      cell = {"notes", "wake"}

      {:ok, _} = Cell.execute(name, cell, "INSERT INTO notes (body) VALUES ('kept')")
      assert {:ok, %{rows: [[1]]}} = Cell.query(name, cell, @version)

      :ok = Cell.hibernate(name, cell)

      assert {:ok, %{rows: [["kept"]]}} = Cell.query(name, cell, "SELECT body FROM notes")
      assert {:ok, %{rows: [[1]]}} = Cell.query(name, cell, @version)
    end

    test "a call on an awake cell is one Alambique call", %{name: name} do
      cell = {"notes", "warm"}
      {:ok, _} = Cell.query(name, cell, "SELECT 1")

      # A traced process cannot be its own tracer.
      test = self()
      tracer = spawn_link(fn -> collect(test, []) end)
      :erlang.trace_pattern({Alambique, :query, 5}, true, [:local])
      :erlang.trace(self(), true, [:call, tracer: tracer])
      {:ok, _} = Cell.query(name, cell, "SELECT body FROM notes")
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Alambique, :query, 5}, false, [:local])

      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^ref}
      send(tracer, :done)
      assert_receive {:calls, [{:trace, _, :call, {Alambique, :query, _}}]}
    end

    defp collect(test, calls) do
      receive do
        {:trace, _, :call, _} = call -> collect(test, [call | calls])
        :done -> send(test, {:calls, Enum.reverse(calls)})
      end
    end

    test "a later migration list upgrades the cell once", %{node: node} do
      cell = {"notes", "up"}
      {:ok, _} = Cell.execute(node.name, cell, "INSERT INTO notes (body) VALUES ('old')")
      :ok = Cell.hibernate(node.name, cell)

      # Same store, next release.
      next = node_with(%{"notes" => @notes ++ @v2_v3}, store: node.store)

      assert {:ok, %{rows: [["old", "x"]]}} = Cell.query(next.name, cell, "SELECT body, tag FROM notes")
      assert {:ok, %{rows: [[3]]}} = Cell.query(next.name, cell, @version)
    end

    test "a failing migration fails the wake", %{node: node} do
      bad = node_with(%{"bad" => [[1, "CREATE TABLE t (x)"], [2, "NOT SQL"]]}, store: node.store)

      assert {:error, {:migration, 2, _}} = Cell.query(bad.name, {"bad", "a"}, "SELECT 1")
      assert {:error, {:migration, 2, _}} = Cell.query(bad.name, {"bad", "a"}, "SELECT * FROM t")
    end
  end

  describe "a namespace no deployment grants" do
    test "fails the wake instead of creating a cell without tables" do
      node = node_with(%{"notes" => @notes})

      assert {:error, {:bad_migrations, message}} = Cell.owner(node.name, {"nope", "a"})
      assert message =~ "namespace nope"
    end
  end

  describe "migrations callback" do
    test "reads the namespaces of its own instance" do
      a = node_with(%{"notes" => @notes})
      b = node_with(%{"other" => []})
      {module, :for_cell, [name]} = Atanor.Migrations.callback(a.name)
      assert name == a.name

      assert [{1, fun}] = module.for_cell("notes.x", a.name)
      assert is_function(fun, 1)
      assert_raise RuntimeError, ~r/namespace other/, fn -> module.for_cell("other.x", a.name) end
      assert [] = module.for_cell("other.x", b.name)
      assert_raise RuntimeError, ~r/namespace notes/, fn -> module.for_cell("notes.x", b.name) end
      assert_raise RuntimeError, ~r/namespace unknown/, fn -> module.for_cell("unknown.x", a.name) end
      assert [] = module.for_cell("not an address", a.name)
    end
  end
end
