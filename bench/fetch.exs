# Latency of sequential outbound HTTP fetches (design §4). Argument: number of fetches (default 500).
# The target is a local plain-HTTP server: a TLS target would need a certificate the client trusts.
alias Atanor.{Env, Request}

n =
  case System.argv() do
    [n | _] -> String.to_integer(n)
    _ -> 500
  end

{_target, port} = Atanor.Test.HTTPTarget.start(self())

node =
  AtanorTestkit.Node.start(
    workers: [Atanor.Test.Manifests.probe("w", allow: ["127.0.0.1"])],
    allow_private_hosts: ["127.0.0.1"]
  )

{:ok, deployment} = Atanor.Registry.deployment(node.name, "w")
env = Env.new(node.name, deployment)
request = %Request{host: "127.0.0.1", port: port, path: "/ok"}

{:ok, _} = Env.fetch(env, request)

times =
  for _ <- 1..n do
    {us, {:ok, %{status: 200}}} = :timer.tc(fn -> Env.fetch(env, request) end)
    us
  end

sorted = Enum.sort(times)
at = fn p -> Enum.at(sorted, min(trunc(p * n), n - 1)) end
IO.puts("fetches: #{n}  total: #{Float.round(Enum.sum(times) / 1000, 1)} ms  p50: #{at.(0.5)} us  p99: #{at.(0.99)} us")
AtanorTestkit.Node.stop(node)
