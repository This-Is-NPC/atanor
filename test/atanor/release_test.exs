defmodule Atanor.ReleaseTest do
  use ExUnit.Case, async: false

  alias Atanor.Release
  alias AtanorTestkit.Node

  @token "release-token"

  defp start(opts) do
    node = Node.start([admin: [token: @token, port: 0]] ++ opts)
    on_exit(fn -> Node.stop(node) end)
    node
  end

  test "the release id defaults to a development identity and can be set" do
    config = Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil})
    assert config.release.id == Release.default_id()
    assert config.release.id =~ "atanor-"
    assert config.release.hash_nifs

    config = Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, release: [id: "image-sha"])
    assert config.release.id == "image-sha"
  end

  test "invalid release options raise" do
    for release <- [[id: ""], [id: :atom], [id: "a\nb"], [hash_nifs: :yes], [retention_ms: 0]] do
      assert_raise ArgumentError, fn ->
        Atanor.Config.build(data_dir: "/tmp/x", store: {Mod, nil}, release: release)
      end
    end
  end

  test "a node reports its versions and NIF hashes" do
    node = start(release: [id: "image-sha", built_at: "2026-10-28T00:00:00Z"])

    info = Release.info(node.name)
    assert info.id == "image-sha"
    assert is_binary(info.atanor)
    assert is_binary(info.elixir)
    assert is_binary(info.otp)
    assert info.built_at == "2026-10-28T00:00:00Z"
    assert %{"atanor_wasm" => %{path: wasm, sha256: wasm_sha}} = info.nifs
    assert File.exists?(wasm)
    assert byte_size(wasm_sha) == 64
  end

  test "deployments carry the release of every node" do
    node = start(release: [id: "image-sha"])

    response =
      Req.request!(
        method: :get,
        url: "http://127.0.0.1:#{Atanor.admin_port(node.name)}/deployments",
        headers: [{"authorization", "Bearer " <> @token}],
        retry: false,
        decode_body: false
      )

    assert %{"status" => "ok", "release" => %{"id" => "image-sha"}} =
             Jason.decode!(response.body)["nodes"][Atom.to_string(node())]
  end
end
