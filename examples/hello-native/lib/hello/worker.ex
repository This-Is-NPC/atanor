defmodule Hello.Worker do
  @moduledoc "Greets `/hello/<name>` and counts the greetings of each name in its own cell."
  @behaviour Atanor.Worker

  alias Atanor.{Env, Request, Response}

  @doc "Counts a greeting; shared by the HTTP path and the alarm."
  def greet(env, name) do
    with {:ok, _} <- Env.execute(env, {"hits", name}, "UPDATE hits SET n = n + 1"),
         {:ok, %{rows: [[n]]}} <- Env.query(env, {"hits", name}, "SELECT n FROM hits") do
      {:ok, n}
    end
  end

  # Work for a name runs on the node that owns its cell.
  @impl true
  def route_key(%Request{path: "/hello/" <> rest}, _env) when rest != "" do
    [name | _] = String.split(rest, "/")
    {:cell, "hits", name}
  end

  def route_key(_request, _env), do: :none

  # /hello/<name>/later sets an alarm that greets <name> once more in 3 seconds.
  @impl true
  def handle_request(%Request{path: "/hello/" <> rest}, env) when rest != "" do
    case String.split(rest, "/") do
      [name, "later"] -> later(env, name)
      [name] -> now(env, name)
      _ -> json(404, %{error: "try /hello/<name>"})
    end
  end

  def handle_request(_request, _env), do: json(404, %{error: "try /hello/<name>"})

  # A WebSocket on /hello answers each text frame with a greeting.
  @impl true
  def handle_ws({:text, text}, state, env) do
    name = String.trim(text)

    case greet(env, name) do
      {:ok, n} -> {:reply, [{:text, "hello #{name}, greeting #{n}"}], state}
      _ -> {:reply, [{:text, "invalid name"}], state}
    end
  end

  def handle_ws(_message, state, _env), do: {:ok, state}

  @impl true
  def handle_alarm({"hits", name}, _payload, env) do
    with {:ok, _n} <- greet(env, name), do: :ok
  end

  defp now(env, name) do
    case greet(env, name) do
      {:ok, n} -> json(200, %{hello: name, greetings: n})
      _ -> json(400, %{error: "invalid name"})
    end
  end

  defp later(env, name) do
    at = System.os_time(:millisecond) + 3_000

    case Env.set_alarm(env, {"hits", name}, at, "") do
      :ok -> json(202, %{hello: name, again_at: at})
      _ -> json(400, %{error: "invalid name"})
    end
  end

  defp json(status, body),
    do: %Response{status: status, headers: [{"content-type", "application/json"}], body: Jason.encode!(body)}
end
