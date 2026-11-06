defmodule Atanor.PackageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Package
  alias Atanor.Test.Manifests

  @md5 String.duplicate("ab", 16)

  defp native(name \\ "w", opts \\ []), do: Manifests.probe(name, opts)
  defp build!(manifest, code), do: with({:ok, package} <- Package.build(manifest, code), do: package)

  test "the id is the SHA-256 of the bytes, and parsing gives the same package back" do
    package = build!(native(), {:native, @md5})
    assert package.id == :crypto.hash(:sha256, package.bytes) |> Base.encode16(case: :lower)
    assert package.md5 == @md5
    assert package.manifest.name == "w"
    assert {:ok, ^package} = Package.parse(package.bytes)
  end

  test "a native package takes the MD5 raw or in hex" do
    raw = Base.decode16!(@md5, case: :lower)
    assert build!(native(), {:native, raw}) == build!(native(), {:native, @md5})
  end

  test "from_project reads the MD5 of the loaded module" do
    assert {:ok, package} = Package.from_project(native())
    assert package.md5 == Atanor.Test.ProbeWorker.module_info(:md5) |> Base.encode16(case: :lower)

    assert {:error, {:module_not_loaded, "Elixir.Not.Compiled"}} =
             Package.from_project(native("w", module: Not.Compiled))
  end

  test "from_project with :ebin reads the MD5 of the beam file, the same as the loaded module" do
    ebin = Atanor.Test.ProbeWorker |> :code.which() |> to_string() |> Path.dirname()

    assert {:ok, from_beam} = Package.from_project(native(), ".", ebin: ["/nonexistent", ebin])
    assert {:ok, loaded} = Package.from_project(native())
    assert from_beam.id == loaded.id

    assert {:error, {:beam_not_found, "Elixir.Not.Compiled", [^ebin]}} =
             Package.from_project(native("w", module: Not.Compiled), ".", ebin: [ebin])
  end

  @tag :tmp_dir
  test "from_project with :ebin refuses an unreadable beam file", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "Elixir.Atanor.Test.ProbeWorker.beam"), "not a beam")
    assert {:error, {:beam_unreadable, _, _}} = Package.from_project(native(), ".", ebin: [dir])
  end

  @tag :tmp_dir
  test "a WASM package holds the component file named in the manifest", %{tmp_dir: dir} do
    manifest = %{"manifest_version" => 1, "name" => "w", "kind" => "wasm", "component" => "w.wasm"}
    File.write!(Path.join(dir, "w.wasm"), "\0asm component")

    assert {:ok, package} = Package.from_project(manifest, dir)
    assert package.component == "\0asm component" and package.md5 == nil
    assert {:ok, ^package} = Package.parse(package.bytes)
    assert {:error, {:component_unreadable, "w.wasm", :enoent}} = Package.from_project(manifest, dir <> "/missing")
  end

  test "the code must match the kind" do
    assert {:error, {:code_does_not_match_kind, :native}} = Package.build(native(), {:wasm, "x"})

    wasm = %{"manifest_version" => 1, "name" => "w", "kind" => "wasm", "component" => "w.wasm"}
    assert {:error, {:code_does_not_match_kind, :wasm}} = Package.build(wasm, {:native, @md5})
    assert {:error, {:invalid_package, :bad_md5}} = Package.build(native(), {:native, "not hex"})
    assert {:error, {:invalid_manifest, ["name"], _}} = Package.build(Map.put(native(), "name", "Bad"), {:native, @md5})
  end

  test "different manifests or code give different ids" do
    a = build!(native(), {:native, @md5})
    assert a.id != build!(native("w", limits: %{"fuel" => 1}), {:native, @md5}).id
    assert a.id != build!(native(), {:native, String.duplicate("cd", 16)}).id
  end

  describe "parse refuses" do
    setup do
      %{bytes: build!(native(), {:native, @md5}).bytes}
    end

    defp reason(bytes), do: with({:error, {:invalid_package, reason}} <- Package.parse(bytes), do: reason)

    test "foreign and truncated bytes", %{bytes: bytes} do
      assert reason("nope") == :bad_magic
      assert reason(:not_bytes) == :not_binary
      assert reason(binary_part(bytes, 0, byte_size(bytes) - 1)) == :truncated
      assert reason(bytes <> "x") == :truncated
    end

    test "entries out of order, repeated, missing or unknown" do
      entry = fn name, data -> <<byte_size(name)::16, name::binary, byte_size(data)::64, data::binary>> end
      magic = "ATANORPKG1\n"
      json = Atanor.Manifest.canonical_json(build!(native(), {:native, @md5}).manifest)

      assert reason(magic <> entry.("module.md5", @md5) <> entry.("atanor.json", json)) ==
               {:entries_not_sorted, "atanor.json"}

      assert reason(magic <> entry.("atanor.json", json) <> entry.("atanor.json", json)) ==
               {:entries_not_sorted, "atanor.json"}

      assert reason(magic <> entry.("atanor.json", json)) == {:missing_entry, "module.md5"}
      assert reason(magic <> entry.("module.md5", @md5)) == {:missing_entry, "atanor.json"}

      assert reason(magic <> entry.("atanor.json", json) <> entry.("extra", "x") <> entry.("module.md5", @md5)) ==
               {:unexpected_entry, "extra"}

      assert reason(magic <> entry.("atanor.json", json) <> entry.("module.md5", @md5) <> entry.("zz", "x")) ==
               {:unexpected_entry, "zz"}
    end

    test "a manifest that is invalid, not JSON or not canonical" do
      entry = fn name, data -> <<byte_size(name)::16, name::binary, byte_size(data)::64, data::binary>> end
      magic = "ATANORPKG1\n"
      canonical = Atanor.Manifest.canonical_json(build!(native(), {:native, @md5}).manifest)
      pretty = canonical |> Jason.decode!() |> Jason.encode!(pretty: true)

      assert reason(magic <> entry.("atanor.json", "{") <> entry.("module.md5", @md5)) == :manifest_not_json
      assert reason(magic <> entry.("atanor.json", pretty) <> entry.("module.md5", @md5)) == :manifest_not_canonical

      assert {:invalid_manifest, ["manifest_version"], :required} =
               reason(magic <> entry.("atanor.json", "{}") <> entry.("module.md5", @md5))

      assert reason(magic <> entry.("atanor.json", canonical) <> entry.("module.md5", "XX")) == :bad_md5
    end

    test "a component named like a reserved entry" do
      manifest = %{"manifest_version" => 1, "name" => "w", "kind" => "wasm", "component" => "module.md5"}

      assert {:error, {:invalid_package, {:reserved_component_name, "module.md5"}}} =
               Package.build(manifest, {:wasm, "x"})
    end
  end

  describe "properties" do
    defp manifest_gen do
      gen all(
            name <- string(~c"abcdefghijklmnopqrstuvwxyz0123456789_-", min_length: 1, max_length: 10),
            limits <-
              map(
                list_of(tuple({member_of(~w(timeout_ms memory_bytes fuel)), integer(1..1000)}), max_length: 3),
                &Map.new/1
              ),
            ns <- list_of(string(~c"abcdefghijklmnopqrstuvwxyz", min_length: 1, max_length: 5), max_length: 3),
            routes <- list_of(string(~c"abcdefghijklmnopqrstuvwxyz", min_length: 1, max_length: 5), max_length: 3)
          ) do
        Manifests.probe(name,
          limits: limits,
          cells: Map.new(ns, &{&1, []}),
          routes: Enum.map(routes, &{&1 <> ".test", "/"})
        )
      end
    end

    property "the same inputs give the same bytes and the same id, whatever the key order" do
      check all(manifest <- manifest_gen(), md5 <- binary(length: 16)) do
        a = build!(manifest, {:native, md5})
        shuffled = manifest |> Map.to_list() |> Enum.reverse() |> Map.new()
        b = build!(shuffled, {:native, md5})
        assert a.bytes == b.bytes and a.id == b.id
        assert {:ok, ^a} = Package.parse(a.bytes)
      end
    end

    property "any change to the bytes either fails to parse or changes the id" do
      check all(
              manifest <- manifest_gen(),
              md5 <- binary(length: 16),
              position <- integer(0..400),
              byte <- integer(0..255)
            ) do
        package = build!(manifest, {:native, md5})
        at = rem(position, byte_size(package.bytes))
        <<head::binary-size(^at), old, tail::binary>> = package.bytes

        if old != byte do
          case Package.parse(<<head::binary, byte, tail::binary>>) do
            {:ok, other} -> assert other.id != package.id
            {:error, {:invalid_package, _}} -> :ok
          end
        end
      end
    end
  end
end
