defmodule Atanor.Sockets do
  @moduledoc """
  WebSockets attached to cells (design §7.3). A socket process attached to a
  cell joins a `:pg` group named by the instance's prefix and the cell, so a
  message sent from any node reaches every socket attached to the cell.
  """

  alias Atanor.{Cell, Channels, Registry}

  @doc """
  Joins the socket `pid` to the sockets of `cell`. Attaching twice is the same
  as once. A socket attaches to at most `:sockets`' `:max_attachments` cells
  (16 by default); over it `{:error, :too_many_attachments}`. `:pg` joins only
  local processes, so a callback that runs on the cell's owner (design §8)
  attaches through the socket's own node. A remote attach is bounded by
  `:attach_timeout_ms` (5 s by default); a timeout is
  `{:error, {:unavailable, :owner_unreachable}}` (design §8.4).
  """
  @spec attach(atom, pid, Cell.address()) :: :ok | {:error, term}
  def attach(instance, pid, cell) when node(pid) == node(),
    do: Channels.attach(pid, group(instance, cell), Registry.config(instance).sockets.max_attachments)

  def attach(instance, pid, cell) do
    case Channels.remote(instance, node(pid), __MODULE__, :attach, [instance, pid, cell]) do
      {:error, :node_unreachable} ->
        Cell.mark_unavailable(:owner_unreachable)
        {:error, {:unavailable, :owner_unreachable}}

      result ->
        result
    end
  end

  @doc """
  Sends `{:atanor_cell_message, message}` to every socket attached to `cell`,
  on any node: one message per node, then one per local socket
  (`Atanor.Channels.broadcast/3`), skipping a socket whose queue is over `channels.max_queue`.
  """
  @spec send_to(atom, Cell.address(), term) :: :ok
  def send_to(instance, cell, message) do
    Channels.broadcast(instance, group(instance, cell), {:atanor_cell_message, message})
    :ok
  end

  defp group(instance, {ns, key}), do: {__MODULE__, Registry.config(instance).prefix, ns, key}
end
