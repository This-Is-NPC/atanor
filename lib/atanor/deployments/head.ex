defmodule Atanor.Deployments.Head do
  @moduledoc """
  The pointer of a worker (design §5), stored as JSON at
  `<prefix>/workers/<name>/head`: the active package id (`nil` when the worker
  is deactivated), the previous ones, newest first, and a revision that grows
  with every change.
  """

  @enforce_keys [:worker]
  defstruct [:worker, :active, :updated_at, previous: [], revision: 0]

  @type t :: %__MODULE__{
          worker: String.t(),
          active: String.t() | nil,
          previous: [String.t()],
          revision: non_neg_integer,
          updated_at: String.t() | nil
        }

  @id ~r/\A[0-9a-f]{64}\z/

  @doc "Whether `id` is a package id."
  @spec id?(term) :: boolean
  def id?(id), do: is_binary(id) and Regex.match?(@id, id)

  @doc "The head as a map for API responses."
  @spec to_map(t) :: map
  def to_map(%__MODULE__{} = head) do
    %{
      worker: head.worker,
      active: head.active,
      previous: head.previous,
      revision: head.revision,
      updated_at: head.updated_at
    }
  end

  @doc "The head as JSON."
  @spec encode(t) :: binary
  def encode(%__MODULE__{} = head) do
    Jason.encode!(%{
      worker: head.worker,
      active: head.active,
      previous: head.previous,
      revision: head.revision,
      updated_at: head.updated_at
    })
  end

  @doc "Parses a stored head."
  @spec decode(binary) :: {:ok, t} | {:error, :invalid_head}
  def decode(json) do
    with {:ok, %{"worker" => worker, "active" => active, "previous" => previous, "revision" => revision} = map} <-
           Jason.decode(json),
         true <- is_binary(worker) and (is_nil(active) or id?(active)),
         true <- is_list(previous) and Enum.all?(previous, &id?/1),
         true <- is_integer(revision) and revision >= 0 do
      {:ok,
       %__MODULE__{
         worker: worker,
         active: active,
         previous: previous,
         revision: revision,
         updated_at: map["updated_at"]
       }}
    else
      _ -> {:error, :invalid_head}
    end
  end
end
