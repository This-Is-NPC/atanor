defmodule Atanor.CLIClientTest do
  use ExUnit.Case, async: true

  alias Atanor.CLI.Client

  test "an error status becomes a message that tells what to do" do
    assert Client.failure(401, %{}) =~ "atanor login"
    assert Client.failure(403, %{"required" => "deploy"}) == "forbidden: this token needs the scope deploy"
    assert Client.failure(403, %{}) == "forbidden: this token may not do that"
    assert Client.failure(413, %{"max_bytes" => 10}) =~ "larger than the server accepts (10 bytes"
    assert Client.failure(422, %{"error" => "hash_mismatch"}) =~ "run the command again"
    assert Client.failure(422, %{"error" => "invalid_package", "reason" => "bad"}) =~ "refused the package: bad"

    assert Client.failure(422, %{"error" => "package_of_other_worker", "package_worker" => "w2"}) =~
             "package is for the worker w2"

    assert Client.failure(409, %{"error" => "no_previous"}) =~ "no previous package"
    assert Client.failure(409, %{"error" => "conflict"}) =~ "moved the head"

    assert Client.failure(409, %{"error" => "partitions_changed", "namespace" => "n", "recorded" => 4, "declared" => 8}) =~
             "namespace n is recorded with 4 partitions and the package declares 8"

    assert Client.failure(409, %{"error" => "partitions_changed", "namespace" => "n"}) =~
             "recorded with no partitions and the package declares none"

    assert Client.failure(409, %{"error" => "namespace_has_data", "namespace" => "n"}) =~
             "namespace n already has cells"

    assert Client.failure(404, %{"error" => "package_not_found"}) =~ "deploy it first"
    assert Client.failure(404, %{"error" => "not_found"}) == "not found"
    assert Client.failure(503, %{"error" => "store_unavailable", "reason" => "down"}) =~ "(store_unavailable: down)"
    assert Client.failure(500, %{"error" => "boom", "reason" => "x"}) == "the server answered 500 boom: x"
    assert Client.failure(500, %{"error" => "boom"}) == "the server answered 500 boom"
    assert Client.failure(502, %{}) == "the server answered 502"
  end

  test "an answer that is not a JSON object, or an error without a JSON body, is reported as such" do
    {_pid, port} = Atanor.Test.HTTPTarget.start(self())
    conn = %{url: "http://127.0.0.1:#{port}", token: "t", timeout_ms: 30_000, connect_timeout_ms: 30_000}

    assert {:error, "the server answered something that is not a JSON object" <> _} = Client.request(conn, :get, "/ok")
    assert {:error, "the server answered 302"} = Client.request(conn, :get, "/redirect-in")
  end
end
