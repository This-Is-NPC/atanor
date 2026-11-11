if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :atanor

    socket("/live", Atanor.Dashboard.Socket,
      websocket: [connect_info: [session: {__MODULE__, :session_options, []}], check_origin: :conn]
    )

    # The cookie only says that the token was shown; its signing key is random
    # at each start, so a restart signs everyone out. `Max-Age` and `Secure` come
    # from the dashboard options, which are known only at start.
    @doc false
    def session_options do
      [
        store: :cookie,
        key: "_atanor_dashboard",
        signing_salt: "atanor dashboard",
        same_site: "Strict",
        max_age: config(:atanor_cookie_max_age_s),
        secure: config(:atanor_cookie_secure)
      ]
    end

    plug(:session)

    defp session(conn, _opts), do: Plug.Session.call(conn, Plug.Session.init(session_options()))

    plug(Atanor.Dashboard.Auth)
    plug(Atanor.Dashboard.Router)
  end
end
