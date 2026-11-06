defmodule Atanor.Admin.ScopeTest do
  use ExUnit.Case, async: true

  alias Atanor.Admin.Scope

  test "parses the scope grammar" do
    assert {:ok, :cluster} = Scope.parse("cluster:admin")
    assert {:ok, {:worker, "my-app_2", :deploy}} = Scope.parse("worker:my-app_2:deploy")
    assert {:ok, {:worker, "*", :read}} = Scope.parse("worker:*:read")

    for bad <- [
          "",
          "cluster",
          "cluster:read",
          "admin",
          "worker:a",
          "worker::deploy",
          "worker:a:",
          "worker:a:delete",
          "worker:a:deploy:x",
          "worker:A:deploy",
          "worker:a*:deploy",
          "worker:*a:deploy",
          "worker:**:deploy",
          "worker:a/b:deploy",
          "*",
          nil,
          :cluster
        ] do
      assert Scope.parse(bad) == :error, inspect(bad)
    end
  end

  test "format is the inverse of parse" do
    for s <- ["cluster:admin", "worker:a:rollback", "worker:*:activate"],
        do: assert(s == s |> Scope.parse() |> elem(1) |> Scope.format())
  end

  test "a wildcard covers every worker for its action only; cluster:admin covers no worker" do
    scopes = for s <- ["worker:*:read", "worker:a:deploy"], do: elem(Scope.parse(s), 1)

    assert Scope.allows?(scopes, {:worker, "any", :read})
    assert Scope.allows?(scopes, {:worker, "a", :deploy})
    refute Scope.allows?(scopes, {:worker, "b", :deploy})
    refute Scope.allows?(scopes, {:worker, "a", :rollback})
    refute Scope.allows?(scopes, :cluster)
    refute Scope.allows?([:cluster], {:worker, "a", :read})
    assert Scope.allows?([:cluster], :cluster)
    assert Scope.allows?(:all, {:worker, "a", :rollback})
  end
end
