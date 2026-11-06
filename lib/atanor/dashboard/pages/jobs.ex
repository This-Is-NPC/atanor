if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Pages.Jobs do
    @moduledoc false
    use Atanor.Dashboard.Page, title: "Jobs"

    alias Atanor.{Cell, Overview}

    def load(socket) do
      socket =
        assign(socket,
          error: nil,
          stats: nil,
          operations: [],
          dead: [],
          jobs: [],
          cell_error: nil,
          cell: socket.assigns.page.params["cell"],
          cursor: socket.assigns.page.params["after"]
        )

      socket =
        case on_node(socket, :jobs_stats) do
          {:ok, stats} -> assign(socket, stats: stats)
          {:error, reason} -> unreachable(socket, reason)
        end

      socket =
        case Overview.operations(instance()) do
          {:ok, operations} -> assign(socket, operations: operations)
          {:error, reason} -> assign(socket, error: "The store did not answer: #{inspect(reason)}")
        end

      socket =
        case Overview.dead_letters(instance(), nil, limit(socket)) do
          {:ok, page} -> assign(socket, dead: page.dead)
          {:error, _} -> socket
        end

      load_cell(socket)
    end

    defp load_cell(%{assigns: %{cell: cell}} = socket) when is_binary(cell) and cell != "" do
      case Cell.parse(cell) do
        {:ok, address} ->
          case Overview.jobs_page(instance(), address, after: socket.assigns.cursor, limit: limit(socket)) do
            {:ok, page} -> assign(socket, jobs: page.jobs, next: page.next)
            {:error, reason} -> assign(socket, cell_error: "The cell did not answer: #{inspect(reason)}")
          end

        _ ->
          assign(socket, cell_error: "The cell is not namespace.key")
      end
    end

    defp load_cell(socket), do: assign(socket, next: nil)

    defp selector(op), do: op["selector"]["kind"]

    defp counters(op) do
      c = op["counters"]
      "#{c["dispatched"] || 0} / #{c["skipped"] || 0} / #{c["failed"] || 0}"
    end

    def render(assigns) do
      ~H"""
      <.error error={@error} />
      <.error error={@cell_error} />
      <.data_table title="Bulk operations" rows={@operations} empty="No operation exists.">
        <:col :let={op} label="Operation">{String.slice(op["id"], 0, 12)}</:col>
        <:col :let={op} label="State">{op["state"]}</:col>
        <:col :let={op} label="Selector">{selector(op)}</:col>
        <:col :let={op} label="Cursor">{op["cursor"] || "-"}</:col>
        <:col :let={op} label="Dispatched / skipped / failed">{counters(op)}</:col>
        <:col :let={op} label="Driver">{op["driver"] || "-"}</:col>
      </.data_table>
      <.data_table title="Job slots on this node" rows={if @stats, do: [@stats], else: []} empty="No stats.">
        <:col :let={stats} label="Node">{stats.node}</:col>
        <:col :let={stats} label="Running">{stats.running}</:col>
        <:col :let={stats} label="By worker">{inspect(stats.workers)}</:col>
      </.data_table>
      <.data_table title="Dead letters" rows={@dead} empty="No dead letter.">
        <:col :let={job} label="Cell">{job["cell"]}</:col>
        <:col :let={job} label="Job">{String.slice(job["id"], 0, 12)}</:col>
        <:col :let={job} label="Worker">{job["worker"]}</:col>
        <:col :let={job} label="Kind">{job["kind"]}</:col>
        <:col :let={job} label="Reason">{job["reason"]}</:col>
      </.data_table>
      <.data_table title={"Jobs of #{@cell || "a cell"}"} rows={@jobs} empty="Give ?cell=namespace.key to list a cell's jobs.">
        <:col :let={job} label="Job">{String.slice(job.id, 0, 12)}</:col>
        <:col :let={job} label="Worker">{job.worker}</:col>
        <:col :let={job} label="Kind">{job.kind}</:col>
        <:col :let={job} label="State">{job.state}</:col>
        <:col :let={job} label="Attempts">{job.attempts}</:col>
        <:col :let={job} label="Due (UTC)">{time(job.due_at_ms)}</:col>
      </.data_table>
      <p class="text-muted">
        Operations are read from the metadata store; jobs and dead letters need a cell
        (<code>?cell=namespace.key</code>). Pause, cancel and retry use the admin API.
      </p>
      """
    end
  end
end
