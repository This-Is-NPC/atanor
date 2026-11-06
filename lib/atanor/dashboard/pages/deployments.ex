if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Pages.Deployments do
    @moduledoc false
    use Atanor.Dashboard.Page, title: "Deployments"

    alias Atanor.Overview

    def load(socket) do
      report = Overview.gather(instance(), :deployments)

      rows =
        for {node, entry} <- Enum.sort(report.nodes), row <- rows(node, entry), do: row

      assign(socket, rows: rows, partial: report.partial)
    end

    defp rows(node, %{status: :error, reason: reason}), do: [%{node: node, state: "no answer", error: reason}]

    defp rows(node, %{workers: workers} = entry) do
      release = entry[:release] && entry.release.id

      for w <- workers, do: Map.merge(w, %{node: node, state: state(w), release: release})
    end

    defp state(%{error: error}) when is_binary(error), do: "failed"
    defp state(%{head: head, serving: serving}) when head == serving, do: "serving"
    defp state(_), do: "applying"

    def render(assigns) do
      ~H"""
      <.error error={@partial && "Some nodes did not answer within 5 seconds."} />
      <.data_table title="Deployments per node" rows={@rows} empty="No node reports a worker.">
        <:col :let={r} label="Node">{r.node}</:col>
        <:col :let={r} label="Release"><code>{short(r[:release])}</code></:col>
        <:col :let={r} label="Worker">{r[:worker]}</:col>
        <:col :let={r} label="State"><span class={state_class(r.state)}>{r.state}</span></:col>
        <:col :let={r} label="Active version (head)"><code>{short(r[:head])}</code></:col>
        <:col :let={r} label="Applied"><code>{short(r[:applied])}</code></:col>
        <:col :let={r} label="Serving"><code>{short(r[:serving])}</code></:col>
        <:col :let={r} label="Error">{r.error}</:col>
      </.data_table>
      """
    end

    defp state_class("serving"), do: "text-success"
    defp state_class("applying"), do: "text-muted"
    defp state_class(_), do: "text-danger"
  end
end
