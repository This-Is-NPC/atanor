defmodule LiveCounter.Worker do
  @moduledoc """
  The native worker `counter`. `GET /counter` reads the count and `POST /counter` adds one, in the cell
  `{"counter", "main"}`. The page of `LiveCounterWeb.CounterLive` calls it with `call/1`, in the same VM,
  without going through the network.
  """
  @behaviour Atanor.Worker

  alias Atanor.{Env, Request, Response}

  @cell {"counter", "main"}

  @doc "Runs the active `counter` deployment on a request of this node, as the ingress does."
  @spec call(String.t()) :: {:ok, integer} | {:error, term}
  def call(method) do
    instance = Atanor.Daemon.instance()

    with {:ok, deployment} <- deployment(instance),
         {:ok, %Response{body: body}} <-
           Atanor.Workers.invoke(Env.new(instance, deployment), %Request{method: method, path: "/counter"}) do
      {:ok, body |> Jason.decode!() |> Map.fetch!("count")}
    end
  end

  defp deployment(instance) do
    case Atanor.Registry.deployment(instance, "counter") do
      {:ok, deployment} -> {:ok, deployment}
      :error -> {:error, :not_deployed}
    end
  end

  @impl true
  def handle_request(%Request{method: "POST"}, env) do
    {:ok, _} = Env.execute(env, @cell, "UPDATE hits SET n = n + 1")
    reply(env)
  end

  def handle_request(%Request{}, env), do: reply(env)

  defp reply(env) do
    {:ok, %{rows: [[n]]}} = Env.query(env, @cell, "SELECT n FROM hits")
    %Response{headers: [{"content-type", "application/json"}], body: Jason.encode!(%{count: n})}
  end
end
