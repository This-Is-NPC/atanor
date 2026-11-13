defmodule Atanor.DiscoveryPropertyTest do
  @moduledoc """
  The dial set of `Atanor.Discovery` is exactly the live peers of the registry, of this node's group,
  minus this node; a peer that expired or left is dialled no more (design §8.16).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Atanor.Discovery
  alias Atanor.Test.Await

  @hosts ["a", "b", "c", "d", "e", "f"]
  @names Enum.map(@hosts, &"atanor@#{&1}")
  @me :atanor@a
  # Node names, and strings that are not (they are reported, never dialled).
  @advertises @names ++ ["no-at-sign", "x@", "has space@h", ""]
  @groups [nil, "x", "y"]

  defp peer({advertise, group}),
    do: %{
      node_id: advertise,
      incarnation: "i",
      advertise: advertise,
      meta: if(group, do: %{"group" => group}, else: %{})
    }

  defp entry, do: tuple({member_of(@advertises), member_of(@groups)})

  # What a round must dial: the valid peers of the group, once each, minus this node.
  defp expected(entries, group, connected \\ []) do
    for {advertise, ^group} <- entries, advertise in @names, reduce: [] do
      acc -> if String.to_atom(advertise) in [@me | connected] or advertise in acc, do: acc, else: acc ++ [advertise]
    end
    |> Enum.map(&String.to_atom/1)
  end

  describe "targets/4" do
    property "the nodes to dial are the valid peers of the group minus this node and the connected ones, once each" do
      check all(
              entries <- list_of(entry(), max_length: 14),
              group <- member_of(@groups),
              connected <- list_of(member_of(Enum.map(@names, &String.to_atom/1)), max_length: 4)
            ) do
        {nodes, invalid} = Discovery.targets(Enum.map(entries, &peer/1), @me, connected, group)

        assert Enum.sort(nodes) == Enum.sort(expected(entries, group, connected))
        assert nodes == Enum.uniq(nodes)

        invalid_of_group = for {advertise, ^group} <- entries, advertise not in @names, do: advertise
        assert Enum.sort(invalid) == Enum.sort(invalid_of_group)
      end
    end
  end

  describe "the process" do
    defp registry_op do
      one_of([
        tuple({constant(:set), list_of(entry(), max_length: 7)}),
        constant(:tick),
        constant(:changed)
      ])
    end

    property "each round dials exactly the peers listed now, minus this node, and no expired peer" do
      check all(
              ops <- list_of(registry_op(), min_length: 3, max_length: 14),
              connects <- member_of([true, false]),
              group <- member_of(@groups),
              max_runs: 40
            ) do
        {:ok, agent} = Agent.start_link(fn -> [] end)
        test = self()
        instance = :"discovery_property_#{System.unique_integer([:positive])}"

        {:ok, pid} =
          Discovery.start_link(
            instance: instance,
            refresh_ms: 3_600_000,
            self: @me,
            group: group,
            peers: fn -> Agent.get(agent, & &1) end,
            connect: fn node ->
              send(test, {:dialed, node})
              connects
            end
          )

        # The first round, on an empty listing.
        settle(pid)
        assert dialed() == []

        Enum.reduce(ops, [], fn
          {:set, entries}, _listed ->
            Agent.update(agent, fn _ -> Enum.map(entries, &peer/1) end)
            entries

          op, listed ->
            if op == :tick,
              do: send(pid, :dial),
              else:
                :telemetry.execute([:alambique, :registry, :peers_changed], %{}, %{
                  instance: instance,
                  joined: [],
                  left: []
                })

            settle(pid)
            assert Enum.sort(dialed()) == Enum.sort(expected(listed, group))
            listed
        end)

        GenServer.stop(pid)
        Agent.stop(agent)
      end
    end

    # The round ends when no dial is in flight.
    defp settle(pid), do: Await.until(fn -> :sys.get_state(pid).dialing == MapSet.new() end)

    defp dialed do
      receive do
        {:dialed, node} -> [node | dialed()]
      after
        0 -> []
      end
    end
  end
end
