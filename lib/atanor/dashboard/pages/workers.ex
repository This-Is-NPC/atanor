if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Pages.Workers do
    @moduledoc false
    use Atanor.Dashboard.Page, title: "Workers"

    alias Atanor.Overview
    alias Phoenix.LiveDashboard.PageBuilder

    def load(socket) do
      socket = assign(socket, error: nil, workers: [], detail: nil)

      case Overview.workers(instance()) do
        {:ok, %{workers: workers}} -> detail(assign(socket, workers: workers))
        {:error, reason} -> assign(socket, error: "The store did not answer: #{inspect(reason)}")
      end
    end

    # The manifest this node serves for the worker named in `?worker=`.
    defp detail(socket) do
      with name when is_binary(name) <- socket.assigns.page.params["worker"],
           {:ok, {:ok, worker}} <- on_node(socket, :worker, [name]) do
        assign(socket, detail: Jason.encode!(worker.deployment, pretty: true))
      else
        _ -> socket
      end
    end

    def render(assigns) do
      ~H"""
      <.error error={@error} />
      <.data_table title="Workers" rows={@workers} empty="No worker has a head in the store.">
        <:col :let={w} label="Worker">
          <.link patch={PageBuilder.live_dashboard_path(@socket, @page, worker: w.worker)}>{w.worker}</.link>
        </:col>
        <:col :let={w} label="Active version"><code>{short(w.active)}</code></:col>
        <:col :let={w} label="Revision">{w.revision}</:col>
        <:col :let={w} label="Previous versions">{length(w.previous)}</:col>
        <:col :let={w} label="Updated">{w.updated_at}</:col>
      </.data_table>
      <div :if={@detail}>
        <h5 class="card-title">Manifest served by {@page.node}</h5>
        <pre class="card card-body">{@detail}</pre>
      </div>
      """
    end
  end
end
