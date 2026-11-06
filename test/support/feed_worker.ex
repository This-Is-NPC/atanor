defmodule Atanor.Test.FeedWorker do
  @moduledoc "Minimal worker for the change feed tests: a response, an alarm and a job."

  @behaviour Atanor.Worker

  alias Atanor.Response

  @impl true
  def handle_request(_request, _env), do: %Response{body: "ok"}

  @impl true
  def handle_alarm(_cell, _payload, _env), do: :ok

  @impl true
  def handle_job(_job, _env), do: :ok
end
