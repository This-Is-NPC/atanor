if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Supervisor do
    @moduledoc false
    # The Phoenix side of an instance. The endpoint is a module, so a VM runs
    # one dashboard.
    use Supervisor

    alias Atanor.Dashboard.{Endpoint, Poller}

    def start_link(config), do: Supervisor.start_link(__MODULE__, config)

    @impl true
    def init(%{name: name, dashboard: dashboard}) do
      endpoint = [
        adapter: Bandit.PhoenixAdapter,
        server: true,
        http: [ip: dashboard.ip, port: dashboard.port, startup_log: false],
        log_access_url: false,
        live_view: [signing_salt: "atanor dashboard live view"],
        secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
        pubsub_server: Atanor.Dashboard.PubSub,
        render_errors: [formats: [html: Atanor.Dashboard.Errors], layout: false],
        atanor_instance: name,
        atanor_token: dashboard.token,
        atanor_cookie_max_age_s: dashboard.cookie_max_age_s,
        atanor_cookie_secure: dashboard.secure_cookie
      ]

      # The options go to the endpoint's start, not the application environment, which anyone in the
      # VM can list (the token and the key base would show).
      children = [{Phoenix.PubSub, name: Atanor.Dashboard.PubSub}, {Poller, dashboard.poll_ms}, {Endpoint, endpoint}]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule Atanor.Dashboard.Errors do
    @moduledoc false

    def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
  end
end
