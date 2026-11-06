if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Page do
    @moduledoc false
    # What the Atanor pages share. A page defines `load/1`, which puts its data
    # in the assigns, and `render/1`; the data is loaded when the page opens,
    # when its parameters change and on every automatic refresh.

    use Phoenix.Component

    alias Atanor.Overview
    alias Phoenix.LiveDashboard.PageBuilder

    defmacro __using__(title: title) do
      quote do
        use Phoenix.LiveDashboard.PageBuilder

        import Atanor.Dashboard.Page

        @impl true
        def menu_link(_session, _capabilities), do: {:ok, unquote(title)}

        @impl true
        def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

        @impl true
        def handle_refresh(socket), do: {:noreply, load(socket)}
      end
    end

    @doc "The instance the dashboard shows."
    def instance, do: Atanor.Dashboard.Endpoint.config(:atanor_instance)

    @doc "Calls an `Atanor.Overview` function on the node selected in the dashboard."
    def on_node(socket, fun, args \\ []), do: Overview.call_node(instance(), socket.assigns.page.node, fun, args)

    @doc "The key after which the page starts (`?after=`), or `nil` for the first."
    def cursor(socket) do
      case socket.assigns.page.params["after"] do
        "" -> nil
        key -> key
      end
    end

    @doc "Rows per page: `?limit=` from 1 to the dashboard's `:max_page_size` (500), `:page_size` (50) by default."
    def limit(socket) do
      dashboard = Atanor.Registry.config(instance()).dashboard

      case Integer.parse(socket.assigns.page.params["limit"] || "") do
        {n, ""} when n in 1..dashboard.max_page_size//1 -> n
        _ -> dashboard.page_size
      end
    end

    @doc "Shows the reason a node could not be asked."
    def unreachable(socket, reason),
      do: assign(socket, error: "#{socket.assigns.page.node} did not answer: #{inspect(reason)}")

    attr :title, :string, required: true
    attr :rows, :list, required: true
    attr :empty, :string, default: "Nothing to show."

    slot :col, required: true do
      attr :label, :string, required: true
    end

    @doc "A table in the style of the dashboard's own."
    def data_table(assigns) do
      ~H"""
      <div class="tabular">
        <h5 class="card-title">{@title}</h5>
        <div class="card tabular-card mb-4 mt-4">
          <div class="card-body p-0">
            <div class="dash-table-wrapper">
              <table class="table table-hover mt-0 dash-table">
                <thead>
                  <tr>
                    <th :for={col <- @col}>{col.label}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @rows}>
                    <td :for={col <- @col}>{render_slot(col, row)}</td>
                  </tr>
                  <tr :if={@rows == []}>
                    <td colspan={length(@col)} class="text-muted">{@empty}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
      """
    end

    attr :socket, :any, required: true
    attr :page, :any, required: true
    attr :cursor, :string, default: nil
    attr :next, :string, default: nil

    @doc "Links to the first page and to the one after the current."
    def pager(assigns) do
      ~H"""
      <div class="mb-4">
        <.link :if={@cursor} patch={PageBuilder.live_dashboard_path(@socket, @page, after: nil)}>
          First page
        </.link>
        <.link :if={@next} patch={PageBuilder.live_dashboard_path(@socket, @page, after: @next)} class="ml-3">
          Next page
        </.link>
      </div>
      """
    end

    attr :error, :string, default: nil

    def error(assigns) do
      ~H"""
      <div :if={@error} class="alert alert-warning">{@error}</div>
      """
    end

    @doc "The first 12 characters of a package id."
    def short(nil), do: "-"
    def short(id), do: String.slice(id, 0, 12)

    @doc "A UTC time in milliseconds as `2026-10-27 12:00:00`."
    def time(ms) when is_integer(ms),
      do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end
end
