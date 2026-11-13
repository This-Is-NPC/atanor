defmodule LiveCounterWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :live_counter

  @session [store: :cookie, key: "_live_counter", signing_salt: "live-counter-session"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  # The two scripts of LiveView come from the dependencies; the example has no asset pipeline.
  plug Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)
  plug Plug.Static, at: "/assets/live_view", from: {:phoenix_live_view, "priv/static"}, only: ~w(phoenix_live_view.min.js)

  plug Plug.Session, @session
  plug LiveCounterWeb.Router
end
