defmodule Atanor.Test.AddressCache do
  @moduledoc """
  An address cache: it keeps domain addresses and evicts an entry
  when the change feed reports a change of its `domains` cell.
  """

  use GenServer

  alias Atanor.Env

  def start_link({%Env{} = env, entries}) do
    GenServer.start_link(__MODULE__, {env, entries})
  end

  def entries(cache), do: GenServer.call(cache, :entries)

  def put(cache, domain, address), do: GenServer.call(cache, {:put, domain, address})

  @impl true
  def init({env, entries}) do
    {:ok, ref} = Env.subscribe(env, "domains", from: :now)
    {:ok, %{env: env, ref: ref, entries: entries}}
  end

  @impl true
  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  def handle_call({:put, domain, address}, _from, state),
    do: {:reply, :ok, put_in(state.entries[domain], address)}

  @impl true
  def handle_info({:atanor_changes, ref, changes, _position}, %{ref: ref} = state) do
    entries = Enum.reduce(changes, state.entries, fn %{cell: domain}, entries -> Map.delete(entries, domain) end)
    {:noreply, %{state | entries: entries}}
  end

  def handle_info({:atanor_feed_dropped, ref, position}, %{ref: ref} = state) do
    {:ok, new_ref} = Env.subscribe(state.env, "domains", from: position)
    {:noreply, %{state | ref: new_ref}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Env.unsubscribe(state.env, state.ref)
    :ok
  end
end
