defmodule Atanor.Test.AlarmIndex do
  @moduledoc "Reads the alarm index of an instance on a peer node (for failure messages)."

  alias Atanor.Store

  @doc "The index keys that mention `fragment`."
  def keys(instance, fragment) do
    case Store.list(Store.handle(instance), "alarms/", nil, 1_000) do
      {:ok, keys, _} -> Enum.filter(keys, &String.contains?(&1, fragment))
      other -> other
    end
  end
end
