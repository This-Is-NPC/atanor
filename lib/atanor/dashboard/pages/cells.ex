if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Pages.Cells do
    @moduledoc false
    use Atanor.Dashboard.Page, title: "Cells"

    def load(socket) do
      socket = assign(socket, error: nil, cursor: cursor(socket), cells: [], next: nil, count: nil)

      with {:ok, %{count: count}} <- on_node(socket, :cells_count),
           {:ok, page} <- on_node(socket, :cells_page, [cursor(socket), limit(socket)]) do
        assign(socket, count: count, cells: page.cells, next: page.next)
      else
        {:error, reason} -> unreachable(socket, reason)
      end
    end

    def render(assigns) do
      ~H"""
      <.error error={@error} />
      <.data_table
        title={"Live cells of #{@page.node}" <> if(@count, do: " (#{@count})", else: "")}
        rows={@cells}
        empty="No cell is awake on this node."
      >
        <:col :let={c} label="Namespace">{c.namespace}</:col>
        <:col :let={c} label="Key">{c.key}</:col>
        <:col :let={c} label="Id"><code>{c.id}</code></:col>
      </.data_table>
      <.pager socket={@socket} page={@page} cursor={@cursor} next={@next} />
      """
    end
  end
end
