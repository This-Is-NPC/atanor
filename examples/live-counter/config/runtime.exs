import Config

# `bin/atanor eval` runs this file too, for the `atanor` commands of the entry point (deploy, status, ...),
# which start no app: ask for the secret only where the endpoint starts. Not ATANOR_*: the daemon refuses an
# ATANOR_ variable it does not know.
if config_env() == :prod and System.get_env("RELEASE_COMMAND") != "eval" do
  config :live_counter, LiveCounterWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4010"))],
    secret_key_base: System.get_env("SECRET_KEY_BASE") || raise("SECRET_KEY_BASE is required (at least 64 bytes)")
end
