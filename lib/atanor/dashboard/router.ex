if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Router do
    @moduledoc false
    use Phoenix.Router

    import Phoenix.LiveDashboard.Router

    alias Atanor.Dashboard.Pages

    pipeline :browser do
      plug(:fetch_session)
      plug(:protect_from_forgery)
      plug(:put_secure_browser_headers)
    end

    scope "/" do
      pipe_through(:browser)

      live_dashboard("/",
        home_app: {"Atanor", :atanor},
        metrics: Atanor.Dashboard.Metrics,
        request_logger: false,
        on_mount: [{Atanor.Dashboard.Auth, :default}],
        additional_pages: [
          workers: Pages.Workers,
          deployments: Pages.Deployments,
          routes: Pages.Routes,
          cells: Pages.Cells,
          alarms: Pages.Alarms,
          jobs: Pages.Jobs
        ]
      )
    end
  end
end
