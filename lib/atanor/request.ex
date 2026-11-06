defmodule Atanor.Request do
  @moduledoc """
  An HTTP request as plain data, so it can cross node boundaries (design §3.1).

  `headers` is a list of `{lowercase_name, value}`; `query` is the raw query
  string; `body` is a binary.
  """

  # The headers carry credentials and the body personal data: neither is printed in logs and crash reports.
  @derive {Inspect, except: [:headers, :body]}
  defstruct method: "GET", scheme: "http", host: "localhost", port: 80, path: "/", query: "", headers: [], body: ""

  @type t :: %__MODULE__{
          method: String.t(),
          scheme: String.t(),
          host: String.t(),
          port: :inet.port_number(),
          path: String.t(),
          query: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary
        }

  @doc """
  The verified claims of the bearer token, when the route is protected by an
  `:auth` rule (`Atanor.Auth`): a map with string keys, or `nil`. Atanor sets
  this header itself and removes any sent by the client.
  """
  @spec claims(t) :: map | nil
  def claims(%__MODULE__{} = request) do
    with value when is_binary(value) <- header(request, Atanor.Auth.claims_header()),
         {:ok, claims} <- Atanor.Auth.decode_claims(value) do
      claims
    else
      _ -> nil
    end
  end

  @doc "The first value of header `name` (lowercase), or `nil`."
  @spec header(t, String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: headers}, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
