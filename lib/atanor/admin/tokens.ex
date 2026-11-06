defmodule Atanor.Admin.Tokens do
  @moduledoc """
  Scoped admin tokens (design §10.2), kept in the instance's metadata store
  at `<prefix>/tokens/<id>` so every node sees them.

  A token is `atn_<id>_<secret>`: a 24-character hex id and 32 random bytes
  (base64url). Only the SHA-256 of the secret is stored. A request reads the
  token from the store, so a revocation is in effect on every node as soon as
  the write is visible in the store. A token has a name, an optional
  description, scopes (see `Atanor.Admin.Scope`), `created_at`, an optional
  `expires_at` and `revoked_at`.
  """

  alias Atanor.Admin.Scope
  alias Atanor.{Registry, Store}

  @format ~r/\A(atn_[0-9a-f]{24})_([A-Za-z0-9_-]{43})\z/
  @id ~r/\Aatn_[0-9a-f]{24}\z/
  @max_name 100
  @max_description 1_000
  @max_attempts 8

  @type principal :: :operator | %{id: String.t(), name: String.t(), scopes: [Scope.t()]}

  @doc """
  Creates a token. Attributes (string keys): `"name"` (required),
  `"description"`, `"scopes"` (a non-empty list) and `"expires_at"` (ISO 8601,
  in the future). Returns the record and the secret token, which is shown
  only here.
  """
  @spec create(atom, map, String.t()) :: {:ok, map, String.t()} | {:error, {:invalid, String.t()} | term}
  def create(name, attrs, created_by) do
    max_scopes = Registry.config(name).admin.max_scopes

    with {:ok, token_name} <- text(attrs["name"], "name", @max_name, true),
         {:ok, description} <- text(attrs["description"], "description", @max_description, false),
         {:ok, scopes} <- scopes(attrs["scopes"], max_scopes),
         {:ok, expires_at} <- expiry(attrs["expires_at"]) do
      id = "atn_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      record = %{
        "id" => id,
        "name" => token_name,
        "description" => description,
        "scopes" => scopes,
        "created_at" => now(),
        "created_by" => created_by,
        "expires_at" => expires_at,
        "revoked_at" => nil,
        "hash" => hash(secret)
      }

      case Store.put(name, key(id), Jason.encode!(record), :if_none_match) do
        {:ok, _etag} -> {:ok, public(record), "#{id}_#{secret}"}
        {:error, reason} -> {:error, {:store, reason}}
      end
    end
  end

  @doc "Finds the principal of a bearer token."
  @spec authenticate(atom, String.t()) :: {:ok, principal} | {:error, :unauthorized | {:store, term}}
  def authenticate(name, bearer) do
    operator = Registry.config(name).admin.token

    cond do
      Plug.Crypto.secure_compare(bearer, operator) -> {:ok, :operator}
      match = Regex.run(@format, bearer) -> scoped(name, match)
      true -> {:error, :unauthorized}
    end
  end

  # An id the store does not have is refused from memory for `admin.unknown_token_ms`, so well-formed
  # random tokens do not each cost a store read. A token created meanwhile works after that time.
  defp scoped(name, [_, id, secret]) do
    admin = Registry.config(name).admin

    if Registry.unknown_token?(name, id, admin.unknown_token_ms),
      do: {:error, :unauthorized},
      else: scoped(name, id, secret, admin)
  end

  defp scoped(name, id, secret, admin) do
    case read(name, id) do
      {:ok, record, _etag} ->
        if Plug.Crypto.secure_compare(hash(secret), record["hash"]) and active?(record) do
          {:ok, %{id: id, name: record["name"], scopes: Enum.map(record["scopes"], &elem(Scope.parse(&1), 1))}}
        else
          {:error, :unauthorized}
        end

      {:error, :not_found} ->
        Registry.put_unknown_token(name, id, admin.unknown_tokens)
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, {:store, reason}}
    end
  end

  defp active?(record) do
    is_nil(record["revoked_at"]) and
      (is_nil(record["expires_at"]) or DateTime.compare(parse_time(record["expires_at"]), DateTime.utc_now()) == :gt)
  end

  @doc "A token's record, without its hash."
  @spec get(atom, String.t()) :: {:ok, map} | {:error, :not_found | term}
  def get(name, id) do
    with true <- Regex.match?(@id, id),
         {:ok, record, _etag} <- read(name, id) do
      {:ok, public(record)}
    else
      false -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  @doc "A page of token records, ordered by id, after the id `after_id`."
  @spec list(atom, String.t() | nil, pos_integer) :: {:ok, [map], String.t() | nil} | {:error, term}
  def list(name, after_id, limit) do
    start = after_id && key(after_id)

    with {:ok, keys, next} <- Store.list(name, "tokens/", start, limit) do
      records =
        for key <- keys, {:ok, json, _, _} <- [Store.get(name, key)], {:ok, record} <- [Jason.decode(json)] do
          public(record)
        end

      {:ok, records, next && String.replace_prefix(next, "tokens/", "")}
    else
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  @doc "Revokes a token. Revoking a revoked token keeps its first revocation."
  @spec revoke(atom, String.t(), String.t(), pos_integer) :: {:ok, map} | {:error, :not_found | term}
  def revoke(name, id, revoked_by, attempt \\ 1) do
    with true <- Regex.match?(@id, id),
         {:ok, record, etag} <- read(name, id) do
      if record["revoked_at"] do
        {:ok, public(record)}
      else
        record = Map.merge(record, %{"revoked_at" => now(), "revoked_by" => revoked_by})

        case Store.put(name, key(id), Jason.encode!(record), {:if_match, etag}) do
          {:ok, _} -> {:ok, public(record)}
          {:error, :precondition_failed} when attempt < @max_attempts -> revoke(name, id, revoked_by, attempt + 1)
          {:error, reason} -> {:error, {:store, reason}}
        end
      end
    else
      false -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  defp read(name, id) do
    with {:ok, json, etag, _meta} <- Store.get(name, key(id)),
         {:ok, record} <- Jason.decode(json) do
      {:ok, record, etag}
    end
  end

  defp key(id), do: "tokens/" <> id
  defp hash(secret), do: :sha256 |> :crypto.hash(secret) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp public(record), do: Map.delete(record, "hash")

  defp parse_time(text) do
    {:ok, time, _} = DateTime.from_iso8601(text)
    time
  end

  defp text(nil, _field, _max, false), do: {:ok, nil}

  defp text(value, field, max, _required) when is_binary(value) and byte_size(value) in 1..max//1,
    do: if(String.valid?(value), do: {:ok, value}, else: invalid("#{field} must be valid UTF-8"))

  defp text(_, field, max, _), do: invalid("#{field} must be a string of 1 to #{max} bytes")

  defp scopes(list, max) when is_list(list) and list != [] and length(list) <= max do
    parsed = Enum.map(list, &Scope.parse/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)),
      do: {:ok, list |> Enum.map(fn s -> s |> Scope.parse() |> elem(1) |> Scope.format() end) |> Enum.uniq()},
      else: invalid("scopes must be cluster:admin or worker:<name|*>:<deploy|activate|rollback|read>")
  end

  defp scopes(_, max), do: invalid("scopes must be a list of 1 to #{max} scopes")

  defp expiry(nil), do: {:ok, nil}

  defp expiry(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _} ->
        if DateTime.compare(time, DateTime.utc_now()) == :gt,
          do: {:ok, time |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second) |> DateTime.to_iso8601()},
          else: invalid("expires_at must be in the future")

      _ ->
        invalid("expires_at must be an ISO 8601 date and time with an offset")
    end
  end

  defp expiry(_), do: invalid("expires_at must be an ISO 8601 date and time with an offset")

  defp invalid(message), do: {:error, {:invalid, message}}
end
