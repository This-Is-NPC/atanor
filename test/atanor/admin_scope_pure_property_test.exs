defmodule Atanor.Admin.ScopePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Admin.Scope

  defp name, do: string(~c"abz09_-", min_length: 1, max_length: 6)
  defp action, do: member_of(Scope.actions())

  defp scope,
    do: one_of([constant(:cluster), map({one_of([name(), constant("*")]), action()}, fn {w, a} -> {:worker, w, a} end)])

  defp need, do: one_of([constant(:cluster), map({name(), action()}, fn {w, a} -> {:worker, w, a} end)])

  # A scope formats to a string that parses back to it.
  property "format and parse round trip" do
    check all(scope <- scope()) do
      assert Scope.parse(Scope.format(scope)) == {:ok, scope}
    end
  end

  # Partial patterns, unknown actions, extra segments and other spellings are refused.
  property "anything but the documented forms is refused" do
    check all(w <- name(), a <- action(), junk <- member_of(["x", "*", "A", ""])) do
      refused = [
        "worker:#{w}*:#{a}",
        "worker:*#{w}:#{a}",
        "worker:#{w}:#{a}:#{junk}",
        "worker:#{w}:#{a}x",
        "worker:#{w}:admin",
        "worker:#{w}",
        "worker::#{a}",
        "worker:#{String.upcase(w)}1A:#{a}",
        "worker:#{w}:#{String.upcase(to_string(a))}",
        "cluster:admin:#{junk}",
        "cluster:*",
        "Cluster:admin",
        "cluster:admin\n",
        junk
      ]

      for text <- refused, do: assert(Scope.parse(text) == :error, text)
    end
  end

  # A need is met by the same action on the same worker or on `*`, and by nothing else; `cluster:admin` implies no worker scope.
  property "allows? is the exact match with the worker wildcard" do
    check all(scopes <- list_of(scope(), max_length: 5), need <- need()) do
      want =
        case need do
          :cluster -> :cluster in scopes
          {:worker, w, a} -> Enum.any?(scopes, &(&1 in [{:worker, w, a}, {:worker, "*", a}]))
        end

      assert Scope.allows?(scopes, need) == want
      assert Scope.allows?(:all, need)
    end

    check all(need <- need(), others <- list_of(scope(), max_length: 3)) do
      assert Scope.allows?(Enum.reject(others, &(&1 == :cluster)) ++ [:cluster], {:worker, "w", :read}) ==
               Scope.allows?(others, {:worker, "w", :read})

      refute Scope.allows?([], need)
    end
  end
end
