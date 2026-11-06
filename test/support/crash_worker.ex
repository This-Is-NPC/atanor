defmodule Atanor.Test.CrashWorker do
  @moduledoc "Test worker with no clause for the paths it is asked: it crashes with the request as argument."
  @behaviour Atanor.Worker

  def handle_request(%Atanor.Request{path: "/crash/never"}, _env), do: %Atanor.Response{status: 200}
end

defmodule Atanor.Test.CrashPlug do
  @moduledoc "Test worker served as a Plug with no clause for the paths it is asked."
  @behaviour Atanor.Worker
  @behaviour Plug

  @impl Atanor.Worker
  def plug(_env), do: {__MODULE__, []}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/crash/never"} = conn, _opts), do: conn
end
