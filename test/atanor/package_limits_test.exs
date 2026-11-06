defmodule Atanor.PackageLimitsTest do
  @moduledoc "A package from outside is bounded before it is parsed, compiled or turned into an atom."
  use ExUnit.Case, async: true

  alias Atanor.{Deployments, Manifest, Package, Workers}
  alias Atanor.Deployments.Service
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @md5 String.duplicate("ab", 16)

  defp start(opts \\ []) do
    node = Node.start(opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  defp wasm_package do
    manifest = Manifests.wasm("w", "hello")
    bytes = File.read!("test/fixtures/wasm/hello.wasm")
    {:ok, package} = Package.build(manifest, {:wasm, bytes})
    package
  end

  defp upload(node, package, worker \\ "w") do
    sha = package.id
    Service.upload(node.name, worker, package.bytes, sha, max_bytes: 10_000_000, uploaded_by: %{"kind" => "test"})
  end

  describe "the module name (INPUT-3, DOS-15)" do
    test "a manifest refuses a module name over 255 bytes" do
      long = "Elixir." <> String.duplicate("A", 300)

      assert {:error, {:invalid_manifest, ["module"], _}} =
               Manifest.parse(Manifests.probe("w") |> Map.put("module", long))
    end

    test "activating a package with such a name returns an error and does not raise" do
      node = start()
      {:ok, package} = Package.build(Manifests.probe("w"), {:native, @md5})
      long = "Elixir." <> String.duplicate("A", 300)
      package = %{package | manifest: %{package.manifest | module: long}}
      assert {:error, {:module_not_loaded, ^long}} = Workers.activate(node.name, package)
    end

    test "a module that is not loaded is refused without creating its atom" do
      node = start()
      name = "Elixir.NoSuchModule#{System.unique_integer([:positive])}"
      {:ok, package} = Package.build(Manifests.probe("w", module: Atanor.Test.ProbeWorker), {:native, @md5})
      package = %{package | manifest: %{package.manifest | module: name}}

      assert {:error, {:module_not_loaded, ^name}} = Workers.activate(node.name, package)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "a name that reaches a beam file through a path is refused without creating its atom" do
      # `<ebin>/../ebin/Elixir.Atanor.Package.beam` exists, so only the name check stops it.
      name = "../ebin/Elixir.Atanor.Package"

      assert {:error, {:module_not_loaded, ^name}} = Package.load_module(name)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "an upload names a module the node has" do
      node = start()
      missing = "Elixir.NoSuchUploadModule#{System.unique_integer([:positive])}"
      {:ok, package} = Package.build(Manifests.probe("w") |> Map.put("module", missing), {:native, @md5})

      assert {:error, {:module_not_loaded, ^missing}} = upload(node, package)
      assert {:error, :not_found} = Deployments.head(node.name, "w")
      assert_raise ArgumentError, fn -> String.to_existing_atom(missing) end
    end
  end

  describe "the manifest entry (INPUT-6)" do
    test "an entry over the limit is refused before it is decoded" do
      package = Manifests.package(Manifests.probe("w"))

      assert {:error, {:invalid_package, {:manifest_too_large, _}}} =
               Package.parse(package.bytes, max_manifest_bytes: 10)

      assert {:ok, _} = Package.parse(package.bytes, max_manifest_bytes: 100_000)
    end

    test "a nested array bomb is refused by size" do
      bomb = String.duplicate("[", 1_000_000)
      bytes = "ATANORPKG1\n" <> <<11::16>> <> "atanor.json" <> <<byte_size(bomb)::64>> <> bomb
      assert {:error, {:invalid_package, {:manifest_too_large, 1_000_000}}} = Package.parse(bytes)
    end

    test "the instance's package limits bound the packages it reads" do
      node = start(package: [max_manifest_bytes: 50])
      package = Manifests.package(Manifests.probe("w"))
      {:ok, id} = Deployments.publish(node.name, package)
      assert {:error, {:invalid_package, {:manifest_too_large, _}}} = Deployments.fetch_package(node.name, id)
    end
  end

  describe "the component (INPUT-7)" do
    test "a component over the limit is refused when the package is parsed" do
      package = wasm_package()

      assert {:error, {:invalid_package, {:component_too_large, _}}} =
               Package.parse(package.bytes, max_component_bytes: 1_000)

      assert {:ok, _} = Package.parse(package.bytes)
    end

    test "a compile that takes longer than the wait leaves the caller with an error" do
      node = start()
      bytes = File.read!("test/fixtures/wasm/hello.wasm")
      hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      assert {:error, message} = Atanor.Wasm.Cache.fetch(node.name, hash, bytes, 0)
      assert message =~ "timed out"
      assert {:ok, _} = Atanor.Wasm.Cache.fetch(node.name, hash, bytes)
    end
  end
end
