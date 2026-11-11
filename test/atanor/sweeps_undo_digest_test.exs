defmodule Atanor.Sweeps.UndoDigestTest do
  use ExUnit.Case, async: true

  alias Alambique.Sqlite
  alias Atanor.Sweeps.Undo.Cell

  setup do
    path = Path.join(System.tmp_dir!(), "atanor-digest-#{System.unique_integer([:positive])}.db")
    {:ok, conn} = Sqlite.open(path)

    :ok =
      Sqlite.execute(conn, """
      CREATE TABLE plain (id INTEGER PRIMARY KEY, a TEXT, b BLOB);
      CREATE TABLE loose (a TEXT, b INTEGER);
      CREATE TABLE keyed (x TEXT, y INTEGER, v TEXT, PRIMARY KEY (x, y)) WITHOUT ROWID;
      """)

    for n <- 1..2_500 do
      {:ok, _} =
        Sqlite.run(conn, "INSERT INTO plain (a, b) VALUES (?, ?)", [
          if(rem(n, 7) == 0, do: nil, else: "r#{n}"),
          <<n::16>>
        ])

      {:ok, _} = Sqlite.run(conn, "INSERT INTO loose VALUES (?, ?)", ["dup#{rem(n, 5)}", nil])
      {:ok, _} = Sqlite.run(conn, "INSERT INTO keyed VALUES (?, ?, ?)", ["k#{rem(n, 9)}", n, "v"])
    end

    on_exit(fn ->
      Sqlite.close(conn)
      File.rm_rf(path)
    end)

    {:ok, conn: conn}
  end

  test "a table bigger than one page hashes like the whole table", %{conn: conn} do
    for table <- ["plain", "loose", "keyed"] do
      assert {:ok, {2_500, hash}} = Cell.digest(conn, table, 1_000_000)
      assert {:ok, {2_500, ^hash}} = Cell.digest(conn, table, 1_000)
      assert {:ok, {2_500, ^hash}} = Cell.digest(conn, table, 7)
      assert {:ok, {2_500, ^hash}} = Cell.digest(conn, table, 2_500)
    end
  end

  test "a changed row changes the hash, a reordered insert does not", %{conn: conn} do
    {:ok, {_, before}} = Cell.digest(conn, "plain", 100)
    {:ok, _} = Sqlite.run(conn, "UPDATE plain SET a = 'x' WHERE id = 1234", [])
    assert {:ok, {2_500, changed}} = Cell.digest(conn, "plain", 100)
    assert changed != before
    {:ok, _} = Sqlite.run(conn, "UPDATE plain SET a = 'r1234' WHERE id = 1234", [])
    assert {:ok, {2_500, ^before}} = Cell.digest(conn, "plain", 100)
  end
end
