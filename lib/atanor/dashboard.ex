defmodule Atanor.Dashboard do
  @moduledoc """
  The read-only dashboard (design §10.1): a Phoenix LiveDashboard with pages for
  the workers, deployments, routes, cells and alarms of an instance, and the
  metrics built from its telemetry events.

  The runtime does not depend on Phoenix. The dashboard is compiled only when
  your project also depends on the packages listed by `dependencies/0`, and it
  starts only with the `:dashboard` option of `Atanor` (`:token`, `:port`,
  `:ip`). See docs/how-to-open-the-dashboard.md.
  """

  # Compiled only with the dependencies.
  @compile {:no_warn_undefined, Atanor.Dashboard.Endpoint}

  @dependencies [
    ~s({:phoenix, "~> 1.8"}),
    ~s({:phoenix_live_view, "~> 1.2"}),
    ~s({:phoenix_live_dashboard, "~> 0.9"}),
    ~s({:telemetry_metrics, "~> 1.2"})
  ]

  @doc "The dependencies a project adds to get the dashboard."
  @spec dependencies() :: String.t()
  def dependencies do
    Enum.join(@dependencies, ", ")
  end

  @doc "Whether Atanor was compiled with the dashboard."
  @spec available?() :: boolean
  def available?, do: Code.ensure_loaded?(Atanor.Dashboard.Supervisor)

  @doc "The port the dashboard listens on."
  @spec port() :: :inet.port_number()
  def port do
    {:ok, {_ip, port}} = Atanor.Dashboard.Endpoint.server_info(:http)
    port
  end
end
