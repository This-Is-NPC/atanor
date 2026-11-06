defmodule Atanor.Test.AlarmWorker do
  @moduledoc """
  Test worker with alarms. Requests: `/set?key&at&payload`, `/cancel?key`.
  `handle_alarm/3` appends the payload to the cell's table `fires` (a cell
  wakes to run it) and reports to the process registered as `:alarm_probe`.
  Payloads: `fail` fails always, `flaky` fails until it has been delivered
  three times, `raise` raises, `slow` blocks, `rearm` sets the next alarm.
  """
  @behaviour Atanor.Worker

  alias Atanor.{Env, Request, Response}

  @migrations [[1, "CREATE TABLE fires (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)"]]
  def migrations, do: @migrations

  @impl true
  def handle_request(%Request{path: "/set", query: query}, env) do
    %{"key" => key, "at" => at, "payload" => payload} = URI.decode_query(query)
    reply(Env.set_alarm(env, {"clock", key}, String.to_integer(at), payload))
  end

  def handle_request(%Request{path: "/cancel", query: query}, env) do
    %{"key" => key} = URI.decode_query(query)
    reply(Env.cancel_alarm(env, {"clock", key}))
  end

  @impl true
  def handle_alarm({"clock", key} = cell, payload, env) do
    {:ok, _} = Env.execute(env, cell, "INSERT INTO fires (payload) VALUES (?)", [payload])
    {:ok, %{rows: [[count]]}} = Env.query(env, cell, "SELECT count(*) FROM fires WHERE payload = ?", [payload])
    if probe = Process.whereis(:alarm_probe), do: send(probe, {:alarm, key, payload, count})

    case payload do
      "fail" -> {:error, :boom}
      "flaky" when count < 3 -> {:error, :flaky}
      "raise" -> raise "secret internals"
      "slow" -> Process.sleep(:infinity)
      "rearm" -> Env.set_alarm(env, cell, 10_000_000_000_000, "rearmed")
      _ -> :ok
    end
  end

  defp reply(result), do: %Response{body: inspect(result)}
end
