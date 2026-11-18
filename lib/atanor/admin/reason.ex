defmodule Atanor.Admin.Reason do
  @moduledoc false
  # The `reason` of an admin error body: a fixed English text per known case, a generic one otherwise.
  # The full term goes to the node log, never to the client (design §10.2).

  require Logger

  @unknown "see the node log"

  @applied %{
    "module_not_loaded" => "the node does not have the module of the package",
    "route_taken" => "another worker holds the route",
    "host_not_allowed" => "the node's policy does not allow the host",
    "http_not_allowed" => "the node's policy does not allow outbound HTTP",
    "module_not_allowed" => "the node's policy does not allow the module",
    "listener_not_allowed" => "the node's policy does not allow the listener",
    "listener_not_configured" => "the node has no such listener",
    "listener_protocol_mismatch" => "the listener serves another protocol",
    "listener_taken" => "another worker holds the listener",
    "namespace_not_allowed" => "the node's policy does not allow the namespace",
    "namespace_owned" => "another worker owns the namespace",
    "namespace_conflict" => "the namespace conflicts with another worker's",
    "namespace_has_data" => "the namespace has cells and cannot be partitioned",
    "partitions_changed" => "the partitions differ from those the namespace was activated with",
    "migrations_lowered" => "the migrations of the namespace are fewer than those applied",
    "invalid_package" => "the package is invalid",
    "package_id_mismatch" => "the stored package does not match its id",
    "package_of_other_worker" => "the package belongs to another worker",
    "not_found" => "the package was not found",
    "store_unavailable" => "the store did not answer",
    "apply_crashed" => "applying the package crashed"
  }

  @packages %{
    not_binary: "the package is not binary data",
    bad_magic: "the bytes are not an Atanor package",
    truncated: "the package is truncated",
    entries_not_sorted: "the package entries are not in canonical order",
    missing_entry: "the package lacks a required file",
    unexpected_entry: "the package holds a file it should not",
    manifest_not_json: "the manifest is not valid JSON",
    manifest_not_canonical: "the manifest is not in canonical form",
    manifest_too_large: "the manifest is larger than the node allows",
    component_too_large: "the component is larger than the node allows",
    bad_md5: "the module checksum is malformed",
    reserved_component_name: "the component name is reserved"
  }

  @doc "Why the node could not answer a cross-node call (`Atanor.Overview.call_node/4`, `gather/3`)."
  def unreachable(reason) do
    log("node unreachable", reason)

    cond do
      has_atom?(reason, :noconnection) -> "the node is not connected"
      has_atom?(reason, :timeout) -> "the node did not answer in time"
      true -> "the node could not be queried"
    end
  end

  defp has_atom?(atom, atom), do: true
  defp has_atom?(tuple, atom) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&has_atom?(&1, atom))
  defp has_atom?([head | _], atom), do: has_atom?(head, atom)
  defp has_atom?(_, _), do: false

  @doc "Why an operation could not be started."
  def operation(reason) do
    log("operation not started", reason)
    "the operation could not be started; " <> @unknown
  end

  @doc "Why bytes are not a valid package, from `{:invalid_package, reason}`."
  def package(reason) do
    key = if is_tuple(reason), do: elem(reason, 0), else: reason
    Map.get(@packages, key, "the package is invalid")
  end

  @doc "The stable code and the text of why a head was not applied, or `{nil, nil}`."
  def applied(nil), do: {nil, nil}

  def applied(reason) do
    code = if is_tuple(reason), do: elem(reason, 0), else: reason
    code = if is_atom(code), do: Atom.to_string(code)

    case @applied do
      %{^code => text} ->
        {code, text}

      _ ->
        log("package not applied", reason)
        {"apply_failed", "the package could not be applied; " <> @unknown}
    end
  end

  defp log(what, reason),
    do: Logger.warning("atanor admin: #{what}: " <> inspect(reason, limit: 20, printable_limit: 500))
end
