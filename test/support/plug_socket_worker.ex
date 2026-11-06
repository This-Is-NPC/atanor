defmodule Atanor.Test.PlugSocketWorker do
  @moduledoc "Test plug worker that upgrades to a WebSocket itself, as Phoenix does."
  @behaviour Atanor.Worker
  @behaviour Plug

  import Plug.Conn

  defmodule Handler do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(worker), do: {:ok, worker}

    @impl true
    def handle_in({text, opcode: :text}, worker), do: {:push, {:text, "#{worker}:#{text}"}, worker}

    @impl true
    def handle_info(_message, worker), do: {:ok, worker}
  end

  @impl Atanor.Worker
  def plug(_env), do: {__MODULE__, []}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{request_path: "/ws"} = conn, _opts) do
    WebSockAdapter.upgrade(conn, Handler, Atanor.Env.worker(conn.private[:atanor]), [])
  end

  def call(conn, _opts), do: send_resp(conn, 200, "plain")
end
