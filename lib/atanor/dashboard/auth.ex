if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Auth do
    @moduledoc false
    # Every layer checks the signed session: the plug before any page or asset,
    # the socket before it accepts a connection and the LiveView before it
    # mounts. `?token=` on a GET trades the token for the session.
    @behaviour Plug

    import Plug.Conn

    @key "atanor_dashboard"

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn = conn |> fetch_session() |> fetch_query_params()

      cond do
        authorized?(get_session(conn)) ->
          conn

        conn.method == "GET" and is_binary(conn.query_params["token"]) ->
          attempt(conn)

        true ->
          unauthorized(conn)
      end
    end

    @doc "Whether a session map carries the sign-in."
    def authorized?(session), do: is_map(session) and Map.get(session, @key) == true

    # The pages that stay. LiveDashboard's Processes, Ports, Sockets, ETS and OS Data pages, and the
    # detail view (`?info=`, which any page opens), show process state and dictionaries, which can
    # hold secrets, and the dependency has no option to leave them out.
    @pages ~w(home metrics applications memory_allocators workers deployments routes cells alarms jobs)

    def on_mount(:default, params, session, socket) do
      cond do
        not authorized?(session) -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
        not in_scope?(params) -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
        true -> {:cont, Phoenix.LiveView.attach_hook(socket, :atanor_scope, :handle_params, &scope/3)}
      end
    end

    # A patch inside the LiveView skips the plug and `on_mount`, so each one is checked again.
    defp scope(params, _uri, socket) do
      if in_scope?(params),
        do: {:cont, hide_links(socket)},
        else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end

    defp in_scope?(params) do
      is_map(params) and not is_map_key(params, "info") and Map.get(params, "page", "home") in @pages
    end

    # The menu is built at mount from every page.
    defp hide_links(socket) do
      Phoenix.Component.update(socket, :menu, fn menu ->
        links =
          Enum.map(menu.links, fn
            {:enabled, _anchor, route} = link -> if Atom.to_string(route) in @pages, do: link, else: :skip
            {:disabled, _anchor} -> :skip
            {:disabled, _anchor, _url} -> :skip
            link -> link
          end)

        %{menu | links: links}
      end)
    end

    # Failed tokens are limited per client address, like the admin listener's.
    defp attempt(conn) do
      name = Atanor.Dashboard.Endpoint.config(:atanor_instance)
      limits = Atanor.Registry.config(name).dashboard

      result =
        Atanor.Admin.Throttle.run(name, :dashboard, conn.remote_ip, limits, fn ->
          if Plug.Crypto.secure_compare(conn.query_params["token"], limits.token),
            do: {:ok, :signed_in},
            else: {:error, :unauthorized}
        end)

      case result do
        {:ok, _} ->
          sign_in(conn)

        {:error, {:throttled, seconds}} ->
          conn
          |> put_resp_header("retry-after", Integer.to_string(seconds))
          |> put_resp_content_type("text/plain")
          |> send_resp(429, "Too many failed attempts. Try again later.\n")
          |> halt()

        {:error, :unauthorized} ->
          unauthorized(conn)
      end
    end

    defp unauthorized(conn),
      do: conn |> put_resp_content_type("text/plain") |> send_resp(401, "Open the URL with ?token=<token>.\n") |> halt()

    # Sends the browser back to the same page without the token in its URL.
    defp sign_in(conn) do
      query = conn.query_params |> Map.delete("token") |> URI.encode_query()
      location = if query == "", do: conn.request_path, else: conn.request_path <> "?" <> query

      conn
      |> configure_session(renew: true)
      |> put_session(@key, true)
      |> put_resp_header("location", location)
      |> send_resp(303, "")
      |> halt()
    end
  end

  defmodule Atanor.Dashboard.Socket do
    @moduledoc false
    use Phoenix.LiveView.Socket

    def connect(_params, socket, connect_info) do
      if Atanor.Dashboard.Auth.authorized?(connect_info[:session]), do: {:ok, socket}, else: :error
    end
  end
end
