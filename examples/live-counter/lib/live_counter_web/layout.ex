defmodule LiveCounterWeb.Layout do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Live counter</title>
        <script src="/assets/phoenix/phoenix.min.js"></script>
        <script src="/assets/live_view/phoenix_live_view.min.js"></script>
        <script>
          const token = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {params: {_csrf_token: token}}).connect()
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
