if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Pages.Routes do
    @moduledoc false
    use Atanor.Dashboard.Page, title: "Routes"

    def load(socket) do
      socket = assign(socket, error: nil, http: [], tcp: [])

      case on_node(socket, :routes) do
        {:ok, routes} -> assign(socket, http: routes.http, tcp: routes.tcp)
        {:error, reason} -> unreachable(socket, reason)
      end
    end

    def render(assigns) do
      ~H"""
      <.error error={@error} />
      <.data_table title="HTTP routes of {@page.node}" rows={@http} empty="No HTTP route is active.">
        <:col :let={r} label="Host">{r.host}</:col>
        <:col :let={r} label="Path">{r.path}</:col>
        <:col :let={r} label="Worker">{r.worker}</:col>
      </.data_table>
      <.data_table title="TCP listeners of {@page.node}" rows={@tcp} empty="No TCP listener is open.">
        <:col :let={r} label="Listener">{r.listener}</:col>
        <:col :let={r} label="Port">{r.port}</:col>
        <:col :let={r} label="Worker">{r.worker}</:col>
      </.data_table>
      """
    end
  end
end
