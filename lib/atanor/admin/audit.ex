defmodule Atanor.Admin.Audit do
  @moduledoc """
  The audit log of the admin API (design §10.2): one immutable object per
  event at `<prefix>/audit/<unix microseconds>-<random>`, written once and never
  changed or deleted by Atanor, so the keys list in time order. An entry has
  `actor` (`type` `operator` or `token`, with the token's `id` and `name`),
  `action`, `worker`, `version` (a package id), `result` (`ok`, `denied` or
  `failed`), `status` (the HTTP status), `error`, `time`, `node` and
  `remote_ip`.
  """

  require Logger

  alias Atanor.Store

  @doc "Records an event. A failure to write is logged and counted, and does not change the response."
  @spec record(atom, map) :: :ok
  def record(name, event) do
    us = System.os_time(:microsecond)

    entry =
      Map.merge(event, %{
        "time" => us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
        "node" => to_string(node())
      })

    key =
      "audit/" <>
        String.pad_leading(Integer.to_string(us), 16, "0") <>
        "-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    stored =
      case Store.put(name, key, Jason.encode!(entry), :if_none_match) do
        {:ok, _} ->
          true

        {:error, reason} ->
          Logger.error("atanor admin audit entry not stored: #{inspect(reason)}")
          false
      end

    :telemetry.execute([:atanor, :admin, :audit], %{count: 1}, %{
      instance: name,
      action: event["action"],
      result: event["result"],
      worker: event["worker"],
      node: node(),
      stored: stored
    })
  end

  @doc "A page of entries, oldest first, after the cursor `after_id` (a previous page's `next`)."
  @spec list(atom, String.t() | nil, pos_integer) :: {:ok, [map], String.t() | nil} | {:error, term}
  def list(name, after_id, limit) do
    with {:ok, keys, next} <- Store.list(name, "audit/", after_id && "audit/" <> after_id, limit) do
      entries =
        for key <- keys, {:ok, json, _, _} <- [Store.get(name, key)], {:ok, entry} <- [Jason.decode(json)] do
          Map.put(entry, "id", String.replace_prefix(key, "audit/", ""))
        end

      {:ok, entries, next && String.replace_prefix(next, "audit/", "")}
    end
  end
end
