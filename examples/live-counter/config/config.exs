import Config

config :phoenix, :json_library, Jason

# check_origin is off so that the example answers on any host name; set it in a real app.
config :live_counter, LiveCounterWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: true,
  http: [ip: {0, 0, 0, 0}, port: 4010],
  pubsub_server: LiveCounter.PubSub,
  live_view: [signing_salt: "live-counter-live-view"],
  check_origin: false,
  render_errors: [formats: [html: LiveCounterWeb.ErrorHTML], layout: false]
