defmodule LiveCounterWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LiveCounterWeb.Layout, :root}
    plug :protect_from_forgery
  end

  scope "/" do
    pipe_through :browser
    live "/", LiveCounterWeb.CounterLive
  end
end
