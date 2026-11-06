if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :atanor

    # The cookie only says that the token was shown; its signing key is random
    # at each start, so a restart signs everyone out.
    @session [store: :cookie, key: "_atanor_dashboard", signing_salt: "atanor dashboard", same_site: "Strict"]

    socket("/live", Atanor.Dashboard.Socket, websocket: [connect_info: [session: @session], check_origin: :conn])

    plug(Plug.Session, @session)
    plug(Atanor.Dashboard.Auth)
    plug(Atanor.Dashboard.Router)
  end
end
