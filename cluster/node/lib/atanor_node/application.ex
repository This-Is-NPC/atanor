defmodule AtanorNode.Application do
  @moduledoc """
  One Atanor node of the container cluster, configured by environment variables (the image's
  entrypoint reads the secrets into them). It holds no worker: deploy with `atanor deploy`.

    * `ATANOR_NODE_S3_ENDPOINT`, `ATANOR_NODE_BUCKET`, `ATANOR_NODE_S3_ACCESS_KEY`,
      `ATANOR_NODE_S3_SECRET_KEY`: the store.
    * `ATANOR_NODE_ADMIN_TOKEN`, `ATANOR_NODE_DASHBOARD_TOKEN`: at least 32 bytes each.
    * `ATANOR_NODE_PEERS`: the host names of the nodes, comma separated (see `AtanorNode.Mesh`).
    * `ATANOR_NODE_RELEASE`: the release id (the image id).
    * `ATANOR_NODE_LEASE_TTL_MS`, `ATANOR_NODE_DETECTOR_PAUSE_MS`: optional tuning.
  """
  use Application

  @any {0, 0, 0, 0}

  @impl true
  def start(_type, _args) do
    store =
      {Alambique.Store.S3,
       %{
         endpoint: System.fetch_env!("ATANOR_NODE_S3_ENDPOINT"),
         bucket: System.fetch_env!("ATANOR_NODE_BUCKET"),
         access_key_id: System.fetch_env!("ATANOR_NODE_S3_ACCESS_KEY"),
         secret_access_key: System.fetch_env!("ATANOR_NODE_S3_SECRET_KEY")
       }}

    alambique = integer_options([{"ATANOR_NODE_LEASE_TTL_MS", :lease_ttl_ms}])
    detector = integer_options([{"ATANOR_NODE_DETECTOR_PAUSE_MS", :acceptable_pause_ms}])

    children = [
      {AtanorNode.Mesh, System.fetch_env!("ATANOR_NODE_PEERS")},
      {Atanor,
       name: AtanorNode.Atanor,
       store: store,
       data_dir: "/var/lib/atanor/cells",
       ip: @any,
       port: 4000,
       admin: [ip: @any, port: 4001, token: System.fetch_env!("ATANOR_NODE_ADMIN_TOKEN")],
       dashboard: [ip: @any, port: 4002, token: System.fetch_env!("ATANOR_NODE_DASHBOARD_TOKEN")],
       release: [id: System.fetch_env!("ATANOR_NODE_RELEASE")],
       alambique: alambique,
       detector: detector}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AtanorNode.Supervisor)
  end

  defp integer_options(pairs) do
    for {env, key} <- pairs, value = System.get_env(env), do: {key, String.to_integer(value)}
  end
end
