defmodule AtanorLab.Application do
  @moduledoc false
  use Application

  @instance AtanorLab.Atanor

  @impl true
  def start(_type, _args) do
    ip = "ATANOR_LAB_IP" |> System.fetch_env!() |> String.to_charlist() |> :inet.parse_address() |> elem(1)

    store =
      {Alambique.Store.S3,
       %{
         endpoint: System.fetch_env!("ATANOR_LAB_S3_ENDPOINT"),
         bucket: "atanor-lab",
         access_key_id: "atanor",
         secret_access_key: "atanor-secret"
       }}

    peers = "ATANOR_LAB_PEERS" |> System.fetch_env!() |> String.split(",") |> Enum.map(&String.to_atom/1)

    # ATANOR_LAB_PIPELINE_DEPTH sets the pipeline depth (Alambique's default, 8, without it) and
    # ATANOR_LAB_REPLICAS=on turns the read replicas on with their defaults.
    alambique =
      for {env, key} <- [
            {"ATANOR_LAB_LEASE_TTL_MS", :lease_ttl_ms},
            {"ATANOR_LAB_SKEW_MARGIN_MS", :skew_margin_ms},
            {"ATANOR_LAB_PIPELINE_DEPTH", :pipeline_depth}
          ],
          value = System.get_env(env),
          do: {key, String.to_integer(value)}

    alambique = if System.get_env("ATANOR_LAB_REPLICAS") == "on", do: [replicas: []] ++ alambique, else: alambique

    detector =
      for {env, key} <- [
            {"ATANOR_LAB_DETECTOR_INTERVAL_MS", :interval_ms},
            {"ATANOR_LAB_DETECTOR_PAUSE_MS", :acceptable_pause_ms},
            {"ATANOR_LAB_DETECTOR_PHI", :phi_threshold}
          ],
          value = System.get_env(env),
          do: {key, String.to_integer(value)}

    AtanorLab.Events.attach()

    children = [
      {AtanorLab.Mesh, peers},
      {Atanor,
       name: @instance,
       store: store,
       data_dir: "/var/lib/atanor-lab/cells",
       ip: ip,
       port: 4000,
       admin: [ip: ip, port: 4001, token: System.fetch_env!("ATANOR_LAB_TOKEN")],
       dashboard: [ip: ip, port: 4002, token: System.fetch_env!("ATANOR_LAB_TOKEN")],
       alambique: alambique,
       detector: detector,
       takeover: [enabled: System.get_env("ATANOR_LAB_TAKEOVER") != "off"],
       hot_cells: hot_cells()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AtanorLab.Supervisor)
  end

  # The placement of hot cells is off unless ATANOR_LAB_HOT_CELLS=on. ATANOR_LAB_HOT_<OPTION> sets an integer option
  # (ATANOR_LAB_HOT_CPU_ENTER=40), ATANOR_LAB_HOT_MOVE=off and ATANOR_LAB_HOT_REPLICAS=on the two booleans,
  # ATANOR_LAB_HOT_TAGS the tags of the node ("dedicated,gpu") and
  # ATANOR_LAB_HOT_AFFINITY the rules ("log=dedicated").
  defp hot_cells do
    if System.get_env("ATANOR_LAB_HOT_CELLS") == "on" do
      integers =
        for key <- ~w(interval_ms sustain_ms write_enter write_exit read_enter read_exit queue_enter queue_exit
                      cpu_enter cpu_exit margin residence_ms node_cooldown_ms max_moves move_timeout_ms stale_ms
                      replica_enter replica_exit replica_hold_ms)a,
            value = System.get_env("ATANOR_LAB_HOT_" <> String.upcase(Atom.to_string(key))),
            do: {key, String.to_integer(value)}

      tags = String.split(System.get_env("ATANOR_LAB_HOT_TAGS", ""), ",", trim: true)

      affinity =
        for rule <- String.split(System.get_env("ATANOR_LAB_HOT_AFFINITY", ""), ",", trim: true),
            [namespace, tag] = String.split(rule, "="),
            do: {namespace, tag}

      booleans =
        for key <- ~w(move replicas)a,
            value = System.get_env("ATANOR_LAB_HOT_" <> String.upcase(Atom.to_string(key))),
            do: {key, value == "on"}

      [enabled: true, tags: tags, affinity: affinity] ++ integers ++ booleans
    else
      []
    end
  end

  @doc "Publishes and activates the lab worker; the other nodes follow from the store."
  def deploy do
    manifest = %{
      "manifest_version" => 1,
      "name" => "lab",
      "kind" => "native",
      "module" => Atom.to_string(AtanorLab.Counter),
      "bindings" => %{
        "cells" =>
          Map.new(AtanorLab.Counter.partitions(), fn n ->
            {"p#{n}", %{"migrations" => AtanorLab.Counter.migrations(), "partitions" => n}}
          end)
          |> Map.put("log", %{"migrations" => AtanorLab.Counter.migrations()}),
        "sockets" => true
      },
      "routes" => [%{"http" => %{"host" => "lab", "path" => "/c"}}, %{"http" => %{"host" => "lab", "path" => "/p"}}]
    }

    with {:ok, deployment} <- Atanor.Dev.deploy(@instance, manifest), do: {:ok, deployment.id}
  end
end
