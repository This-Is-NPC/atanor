defmodule Atanor.Response do
  @moduledoc """
  An HTTP response as plain data (design §3.1). `headers` is a list of
  `{name, value}`; names are lowercased when written.
  """

  defstruct status: 200, headers: [], body: ""

  @type t :: %__MODULE__{status: 100..599, headers: [{String.t(), String.t()}], body: binary}

  @doc "Whether a worker returned a well-formed response."
  @spec valid?(term) :: boolean
  def valid?(%__MODULE__{status: status, headers: headers, body: body}) do
    status in 100..599 and is_binary(body) and is_list(headers) and
      Enum.all?(headers, &match?({n, v} when is_binary(n) and is_binary(v), &1))
  end

  def valid?(_), do: false
end
