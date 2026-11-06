defmodule Atanor.Test.PlugWorker do
  @moduledoc "Test worker served as a Plug; it reads its env from `conn.private[:atanor]`."
  @behaviour Atanor.Worker
  @behaviour Plug

  import Plug.Conn

  @impl Atanor.Worker
  def plug(_env), do: {__MODULE__, mode: :normal}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{request_path: "/boom"}, _opts), do: raise("secret internals")

  def call(conn, _opts) do
    env = conn.private[:atanor]
    {:ok, body, conn} = read_body(conn)
    ns_ok? = match?({:error, {:not_granted, _}}, Atanor.Env.query(env, {"nope", "k"}, "SELECT 1"))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        worker: Atanor.Env.worker(env),
        body: body,
        ungranted_denied: ns_ok?,
        claims: get_req_header(conn, "x-atanor-claims")
      })
    )
  end
end
