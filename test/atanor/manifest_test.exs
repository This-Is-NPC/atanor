defmodule Atanor.ManifestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Manifest

  @full %{
    "manifest_version" => 1,
    "name" => "notes",
    "kind" => "native",
    "module" => "Elixir.MyApp.NotesWorker",
    "bindings" => %{
      "cells" => %{"notes" => %{"migrations" => [[1, "CREATE TABLE a (x)"], [2, ["ALTER TABLE a ADD y", "SELECT 1"]]]}},
      "secrets" => ["API_TOKEN"],
      "http" => %{
        "allow" => ["api.example.com", "api.example.com:8443", "https://pay.example.com", "*.cdn.example.com"]
      },
      "workers" => ["auth"],
      "alarms" => true,
      "sockets" => true
    },
    "routes" => [
      %{"http" => %{"host" => "notes.example.test", "path" => "/api/"}},
      %{"http" => %{"host" => "*.example.test"}},
      %{"http" => %{"host" => "*", "path" => "/health"}},
      %{"tcp" => %{"listener" => "smtp"}}
    ],
    "limits" => %{"timeout_ms" => 30_000, "memory_bytes" => 1024, "fuel" => 5}
  }

  defp invalid(map, path), do: assert({:error, {:invalid_manifest, ^path, _}} = Manifest.parse(map))

  test "parses a full manifest" do
    assert {:ok, m} = Manifest.parse(@full)
    assert m.name == "notes" and m.kind == :native and m.module == "Elixir.MyApp.NotesWorker"
    assert m.cells["notes"] == [{1, ["CREATE TABLE a (x)"]}, {2, ["ALTER TABLE a ADD y", "SELECT 1"]}]

    assert m.secrets == ["API_TOKEN"] and
             m.http_allow == [
               {nil, "api.example.com", nil},
               {nil, "api.example.com", 8443},
               {"https", "pay.example.com", 443},
               {nil, "*.cdn.example.com", nil}
             ] and m.workers == ["auth"]

    assert m.alarms and m.sockets

    assert m.routes == [
             {:http, "notes.example.test", "/api"},
             {:http, "*.example.test", "/"},
             {:http, "*", "/health"},
             {:tcp, "smtp", :thousand_island}
           ]

    assert m.limits == %{timeout_ms: 30_000, memory_bytes: 1024, fuel: 5}
  end

  test "defaults: only manifest_version, name, kind and module are required" do
    assert {:ok, m} =
             Manifest.parse(%{"manifest_version" => 1, "name" => "w", "kind" => "native", "module" => "Elixir.W"})

    assert %{cells: %{}, secrets: [], http_allow: [], workers: [], routes: [], limits: %{}, alarms: false} = m
  end

  test "accepts wasm with a component, and activation is a separate step" do
    assert {:ok, %{kind: :wasm, component: "w.wasm", module: nil}} =
             Manifest.parse(%{"manifest_version" => 1, "name" => "w", "kind" => "wasm", "component" => "w.wasm"})
  end

  test "reports the path of the first invalid input" do
    invalid(:nope, [])
    invalid(Map.delete(@full, "manifest_version"), ["manifest_version"])
    invalid(%{@full | "manifest_version" => 2}, ["manifest_version"])
    invalid(%{@full | "manifest_version" => "1"}, ["manifest_version"])
    invalid(Map.delete(@full, "name"), ["name"])
    invalid(%{@full | "name" => "Bad Name"}, ["name"])
    invalid(%{@full | "kind" => "java"}, ["kind"])
    invalid(Map.delete(@full, "module"), ["module"])
    invalid(%{@full | "module" => "MyApp.NotesWorker"}, ["module"])
    invalid(Map.put(@full, "component", "x.wasm"), ["component"])
    invalid(Map.put(@full, "extra", 1), [])
    invalid(%{@full | "kind" => "wasm"} |> Map.delete("module") |> Map.put("component", "a/b.wasm"), ["component"])

    invalid(
      %{"manifest_version" => 1, "name" => "w", "kind" => "wasm", "module" => "Elixir.W", "component" => "c"},
      ["module"]
    )

    invalid(put_in(@full, ["bindings", "secrets"], ["bad name"]), ["bindings", "secrets", 0])
    invalid(put_in(@full, ["bindings", "http", "allow"], ["ok.test", "UPPER.test"]), ["bindings", "http", "allow", 1])

    for bad <- [
          "*.com",
          "example.com:0",
          "example.com:70000",
          "ftp://example.com",
          "https://",
          "a.*.com",
          "*example.com",
          "https://*"
        ] do
      invalid(put_in(@full, ["bindings", "http", "allow"], ["ok.test", bad]), ["bindings", "http", "allow", 1])
    end

    invalid(put_in(@full, ["bindings", "alarms"], "yes"), ["bindings", "alarms"])
    invalid(put_in(@full, ["bindings", "other"], 1), ["bindings"])
    invalid(put_in(@full, ["bindings", "cells", "Bad"], %{}), ["bindings", "cells", "Bad"])

    invalid(put_in(@full, ["bindings", "cells", "notes", "migrations"], [[2, "x"]]), [
      "bindings",
      "cells",
      "notes",
      "migrations",
      0,
      0
    ])

    invalid(put_in(@full, ["bindings", "cells", "notes", "migrations"], [[1, ""]]), [
      "bindings",
      "cells",
      "notes",
      "migrations",
      0,
      1
    ])

    invalid(put_in(@full, ["bindings", "cells", "notes", "migrations"], [[1, [5]]]), [
      "bindings",
      "cells",
      "notes",
      "migrations",
      0,
      1
    ])

    invalid(put_in(@full, ["bindings", "cells", "notes", "migrations"], [[1, "ok"], "x"]), [
      "bindings",
      "cells",
      "notes",
      "migrations",
      1
    ])

    invalid(%{@full | "routes" => [%{"http" => %{"host" => "A.test"}}]}, ["routes", 0, "http", "host"])
    invalid(%{@full | "routes" => [%{"http" => %{"host" => "*x"}}]}, ["routes", 0, "http", "host"])
    invalid(%{@full | "routes" => [%{"http" => %{"host" => "**"}}]}, ["routes", 0, "http", "host"])
    invalid(%{@full | "routes" => [%{"http" => %{"host" => "a.test", "path" => "api"}}]}, ["routes", 0, "http", "path"])
    invalid(%{@full | "routes" => [%{"http" => %{"host" => "a.test"}, "tcp" => %{"listener" => "x"}}]}, ["routes", 0])
    invalid(%{@full | "routes" => [%{"tcp" => %{"port" => 25}}]}, ["routes", 0, "tcp"])
    invalid(%{@full | "routes" => [%{"tcp" => %{"listener" => "Bad Name"}}]}, ["routes", 0, "tcp", "listener"])

    invalid(%{@full | "routes" => [%{"tcp" => %{"listener" => "smtp", "protocol" => "udp"}}]}, [
      "routes",
      0,
      "tcp",
      "protocol"
    ])

    invalid(%{@full | "limits" => %{"fuel" => 0}}, ["limits", "fuel"])
    invalid(%{@full | "limits" => %{"cpu_ms" => 0}}, ["limits", "cpu_ms"])
    invalid(%{@full | "limits" => %{"cpu" => 1}}, ["limits"])
  end

  test "a ranch route names its protocol and keeps the default out of the JSON" do
    {:ok, plain} =
      Manifest.parse(%{
        "manifest_version" => 1,
        "name" => "w",
        "kind" => "native",
        "module" => "Elixir.W",
        "routes" => [%{"tcp" => %{"listener" => "smtp"}}]
      })

    assert plain.routes == [{:tcp, "smtp", :thousand_island}]
    refute Manifest.canonical_json(plain) =~ "protocol"

    ranch = %{
      "manifest_version" => 1,
      "name" => "w",
      "kind" => "native",
      "module" => "Elixir.W",
      "routes" => [%{"tcp" => %{"listener" => "smtp", "protocol" => "ranch"}}]
    }

    assert {:ok, parsed} = Manifest.parse(ranch)
    assert parsed.routes == [{:tcp, "smtp", :ranch}]
    assert {:ok, ^parsed} = parsed |> Manifest.to_map() |> Manifest.parse()
  end

  test "a namespace can declare its number of partitions" do
    cells = %{"events" => %{"migrations" => [[1, "CREATE TABLE a (x)"]], "partitions" => 6}, "notes" => %{}}
    assert {:ok, m} = Manifest.parse(put_in(@full, ["bindings", "cells"], cells))
    assert m.partitions == %{"events" => 6}
    assert Map.keys(m.cells) == ["events", "notes"]
    assert {:ok, ^m} = m |> Manifest.to_map() |> Jason.encode!() |> Jason.decode!() |> Manifest.parse()
    assert Manifest.canonical_json(m) =~ ~s|"events":{"migrations":[[1,["CREATE TABLE a (x)"]]],"partitions":6}|

    # A manifest without partitions has the same canonical form as before.
    assert {:ok, plain} = Manifest.parse(@full)
    assert plain.partitions == %{}
    refute Manifest.canonical_json(plain) =~ "partitions"
  end

  test "the number of partitions is an integer from 2 to the maximum" do
    path = ["bindings", "cells", "notes", "partitions"]

    for n <- [2, 6, Atanor.Partition.max_partitions()] do
      assert {:ok, %{partitions: %{"notes" => ^n}}} = Manifest.parse(put_in(@full, path, n))
    end

    for bad <- [0, 1, -3, Atanor.Partition.max_partitions() + 1, 2.0, "6", nil, true] do
      invalid(put_in(@full, path, bad), path)
    end

    invalid(put_in(@full, ["bindings", "cells", "notes", "shards"], 3), ["bindings", "cells", "notes"])
  end

  test "formats errors" do
    {:error, error} = Manifest.parse(put_in(@full, ["bindings", "secrets"], ["bad name"]))

    assert Manifest.format_error(error) ==
             "invalid manifest at bindings.secrets.0: must be a list of names like API_TOKEN"
  end

  test "the canonical JSON ignores key order and spelling of defaults" do
    base = %{"manifest_version" => 1, "name" => "w", "kind" => "native", "module" => "Elixir.W"}
    {:ok, a} = Manifest.parse(base)
    {:ok, b} = Manifest.parse(Map.put(base, "bindings", %{"alarms" => false}))

    assert Manifest.canonical_json(a) == Manifest.canonical_json(b)
    assert Manifest.canonical_json(a) =~ ~s("kind":"native","limits":{},"manifest_version":1,"module":"Elixir.W")
  end

  describe "properties" do
    defp ident, do: string(~c"abcdefghijklmnopqrstuvwxyz0123456789_-", min_length: 1, max_length: 12)

    defp host,
      do:
        map(
          list_of(string(~c"abcdefghijklmnopqrstuvwxyz0123456789", min_length: 1, max_length: 8),
            min_length: 1,
            max_length: 3
          ),
          &Enum.join(&1, ".")
        )

    defp migrations do
      sql =
        one_of([
          string(:alphanumeric, min_length: 1),
          list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 2)
        ])

      map(list_of(sql, max_length: 3), fn sqls -> sqls |> Enum.with_index(1) |> Enum.map(fn {s, v} -> [v, s] end) end)
    end

    defp allow_entry do
      one_of([
        host(),
        map(host(), &("https://" <> &1)),
        map({host(), integer(1..65_535)}, fn {h, p} -> "#{h}:#{p}" end),
        map(host(), &("*." <> &1 <> ".test"))
      ])
    end

    defp route do
      one_of([
        map({host(), list_of(string(:alphanumeric, min_length: 1, max_length: 5), max_length: 3)}, fn {h, segs} ->
          %{"http" => %{"host" => h, "path" => "/" <> Enum.join(segs, "/")}}
        end),
        map(ident(), &%{"tcp" => %{"listener" => &1}}),
        map(ident(), &%{"tcp" => %{"listener" => &1, "protocol" => "ranch"}})
      ])
    end

    defp valid_manifest do
      gen all(
            name <- ident(),
            native? <- boolean(),
            module <- member_of(["Elixir.A", "Elixir.My.Worker2"]),
            cells <- map_of(ident(), map(migrations(), &%{"migrations" => &1}), max_length: 3),
            secrets <- list_of(string([?A..?Z, ?_], min_length: 1, max_length: 8), max_length: 3),
            allow <- list_of(allow_entry(), max_length: 3),
            workers <- list_of(ident(), max_length: 3),
            alarms <- boolean(),
            routes <- list_of(route(), max_length: 3),
            limits <-
              map(
                list_of(tuple({member_of(~w(timeout_ms memory_bytes fuel)), integer(1..1_000_000)}), max_length: 3),
                &Map.new/1
              )
          ) do
        code = if native?, do: %{"module" => module}, else: %{"component" => name <> ".wasm"}

        Map.merge(code, %{
          "manifest_version" => 1,
          "name" => name,
          "kind" => if(native?, do: "native", else: "wasm"),
          "bindings" => %{
            "cells" => cells,
            "secrets" => secrets,
            "http" => %{"allow" => allow},
            "workers" => workers,
            "alarms" => alarms
          },
          "routes" => routes,
          "limits" => limits
        })
      end
    end

    # Each corruption makes a valid manifest invalid in one way.
    defp corruptions do
      [
        &Map.delete(&1, "name"),
        &Map.put(&1, "name", &1["name"] <> " X"),
        &Map.put(&1, "kind", "java"),
        &Map.put(&1, "unknown", 1),
        &put_in(&1, ["bindings", "secrets"], [1]),
        &put_in(&1, ["bindings", "http", "allow"], ["Not A Host"]),
        &put_in(&1, ["bindings", "http", "allow"], ["*.com"]),
        &Map.delete(&1, "manifest_version"),
        &put_in(&1, ["bindings", "workers"], "auth"),
        &put_in(&1, ["bindings", "cells"], %{"Bad NS" => %{}}),
        &put_in(&1, ["bindings", "cells"], %{"ns" => %{"migrations" => [[2, "x"]]}}),
        &put_in(&1, ["bindings", "alarms"], 1),
        &Map.put(&1, "routes", [%{"http" => %{"host" => "x.test", "path" => "no-slash"}}]),
        &Map.put(&1, "routes", [%{"udp" => %{}}]),
        &Map.put(&1, "routes", [%{"tcp" => %{"port" => 25}}]),
        &Map.put(&1, "limits", %{"fuel" => -1}),
        &Map.put(&1, "limits", %{"nope" => 1})
      ]
    end

    property "every corrupted manifest is rejected with an invalid_manifest error" do
      check all(manifest <- valid_manifest(), corrupt <- member_of(corruptions())) do
        assert {:error, {:invalid_manifest, path, _}} = Manifest.parse(corrupt.(manifest))
        assert is_list(path)
      end
    end

    property "valid manifests parse and round trip through to_map" do
      check all(manifest <- valid_manifest()) do
        assert {:ok, parsed} = Manifest.parse(manifest)
        assert {:ok, ^parsed} = parsed |> Manifest.to_map() |> Jason.encode!() |> Jason.decode!() |> Manifest.parse()
        assert Manifest.canonical_json(parsed) == Manifest.canonical_json(parsed)
      end
    end
  end
end
