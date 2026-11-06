defmodule AtanorNode.Application do
  @moduledoc """
  One Atanor node of the container cluster, configured by environment variables (the image's
  entrypoint reads the secrets into them). It holds no worker: deploy with `atanor deploy`.

    * `ATANOR_NODE_S3_ENDPOINT`, `ATANOR_NODE_BUCKET`, `ATANOR_NODE_S3_ACCESS_KEY`,
      `ATANOR_NODE_S3_SECRET_KEY`: the store.
    * `ATANOR_NODE_ADMIN_TOKEN`, `ATANOR_NODE_DASHBOARD_TOKEN`: at least 32 bytes each.
    * `ATANOR_NODE_PEERS`: the host names of the nodes, comma separated (see `AtanorNode.Mesh`).
      Empty: the node joins no cluster, as in a swap (docs/how-to-replace-a-node.md).
    * `ATANOR_NODE_ID`: the node's id in the leases (default: the Erlang node name). Two nodes
      that share a store must not share an id.
    * `ATANOR_NODE_SHUTDOWN_MS`, `ATANOR_NODE_DRAIN_TIMEOUT_MS`, `ATANOR_NODE_DRAIN_CONCURRENCY`:
      the drain, `stop.shutdown_ms` and its siblings (the container's grace period must exceed
      the first).
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

    alambique =
      integer_options([{"ATANOR_NODE_LEASE_TTL_MS", :lease_ttl_ms}]) ++
        for(id <- [System.get_env("ATANOR_NODE_ID")], id not in [nil, ""], do: {:node_id, id})

    stop =
      integer_options([
        {"ATANOR_NODE_SHUTDOWN_MS", :shutdown_ms},
        {"ATANOR_NODE_DRAIN_TIMEOUT_MS", :drain_timeout_ms},
        {"ATANOR_NODE_DRAIN_CONCURRENCY", :drain_concurrency}
      ])

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
       stop: stop,
       detector: detector}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AtanorNode.Supervisor)
  end

  defp integer_options(pairs) do
    for {env, key} <- pairs, value = System.get_env(env), value != "", do: {key, String.to_integer(value)}
  end
end
