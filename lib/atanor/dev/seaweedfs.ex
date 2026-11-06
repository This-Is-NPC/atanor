defmodule Atanor.Dev.SeaweedFS do
  @moduledoc "The container from `scripts/seaweedfs-up` (`mise run seaweedfs:up`)."

  @endpoint "http://127.0.0.1:18343"
  @access_key "atanor"
  @secret_key "atanor-secret"

  @doc "The bucket that `mix atanor.dev` and the deploy tasks share by default."
  def dev_bucket, do: "atanor-dev"

  @doc """
  Store config for `bucket` in the local container, created if missing. By
  default the bucket is fresh and random.
  """
  @spec config(String.t() | nil) :: map
  def config(bucket \\ nil) do
    config = %{
      endpoint: @endpoint,
      bucket: bucket || "atanor-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
      access_key_id: @access_key,
      secret_access_key: @secret_key
    }

    create_bucket!(config)
    config
  end

  defp create_bucket!(config) do
    {:ok, %{status: status}} =
      Req.put(
        url: "#{config.endpoint}/#{config.bucket}",
        aws_sigv4: [
          access_key_id: config.access_key_id,
          secret_access_key: config.secret_access_key,
          service: "s3",
          region: "us-east-1"
        ],
        retry: false
      )

    status in [200, 409] or raise "could not create bucket #{config.bucket}: HTTP #{status}"
  end
end
