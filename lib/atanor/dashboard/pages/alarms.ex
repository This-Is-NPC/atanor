if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Pages.Alarms do
    @moduledoc false
    use Atanor.Dashboard.Page, title: "Alarms"

    alias Atanor.{Cell, Overview}

    def load(socket) do
      socket = assign(socket, error: nil, cursor: cursor(socket), alarms: [], next: nil)

      case Overview.alarms_page(instance(), cursor(socket), limit(socket)) do
        {:ok, page} -> assign(socket, alarms: page.alarms, next: page.next)
        {:error, reason} -> assign(socket, error: "The store did not answer: #{inspect(reason)}")
      end
    end

    defp cell(id) do
      {:ok, {namespace, key}} = Cell.parse(id)
      "#{namespace} / #{key}"
    end

    def render(assigns) do
      ~H"""
      <.error error={@error} />
      <.data_table
        title="Pending alarms"
        rows={@alarms}
        empty="No alarm is set."
      >
        <:col :let={a} label="Due (UTC)">{time(a.at_ms)}</:col>
        <:col :let={a} label="Worker">{a.worker}</:col>
        <:col :let={a} label="Cell">{cell(a.id)}</:col>
      </.data_table>
      <.pager socket={@socket} page={@page} cursor={@cursor} next={@next} />
      <p class="text-muted">
        Entries of the store index, in key order (by minute, then shard). It also lists alarms
        claimed for a retry and stale entries not yet removed.
      </p>
      """
    end
  end
end
