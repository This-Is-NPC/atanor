# How to run Atanor in production

**The question:** How do I put Atanor nodes behind a load balancer with TLS, keep the traffic between
nodes on a private network, and keep the bucket, the cookie and the tokens safe?

This guide stands alone for the arrangement; it assumes you have run one node
([README](../README.md#start-here)) and have a bucket on S3 or a compatible store. It describes what
to put around the image. It does not set up a particular balancer, cloud or orchestrator: the examples are
HAProxy and Docker.

## What is exposed, and to whom

| Port | What | Who may reach it |
| --- | --- | --- |
| 4000 | The ingress: your workers over HTTP and WebSocket. Plain HTTP, no TLS. | The load balancer, and so the internet. |
| 4001 | The admin API: health, deploys, tokens, drains. Plain HTTP, bearer token. | The load balancer's health checks and your operators, never the internet. |
| 4002 | The dashboard, read-only, when `ATANOR_DASHBOARD_TOKEN` is set. | Loopback or an operator network. |
| 4369 and 9100 to 9110 | Erlang distribution between nodes: `epmd` and the node ports. | The other nodes only. |
| TCP ports of your manifests | Raw TCP, or TLS terminated by the node. | As your workers need. |

## TLS at the proxy

The ingress, the admin API and the dashboard speak plain HTTP. The node has no TLS for them: a TLS-terminating
proxy (HAProxy, nginx, a cloud load balancer) must sit in front. Without it, the admin and dashboard tokens, and
every `Authorization` header of your workers' clients, cross the network in clear.

1. Terminate TLS at the proxy for 4000, and for 4001 and 4002 when anyone reaches them from outside. Forward to
   the node over the private network. A short HAProxy example (the certificate is a PEM file with the chain and
   the key):

   ```text
   frontend https
       bind :443 ssl crt /etc/haproxy/certs/app.example.com.pem alpn h2,http/1.1
       option httplog
       default_backend atanor_http

   frontend admin_https
       bind :4443 ssl crt /etc/haproxy/certs/admin.example.com.pem
       default_backend atanor_admin
   ```

   The backends are those of step 5.
2. Tell the node. Set `ATANOR_BEHIND_TLS_PROXY=true` (file key `behind_tls_proxy`; library option
   `behind_tls_proxy: true`). The dashboard session cookie then gets `Secure`, and the start warning below does not
   appear.
3. Check the log. A node whose admin or dashboard listener binds outside loopback (the daemon default is
   `0.0.0.0`) and does not have `ATANOR_BEHIND_TLS_PROXY` logs, at start:

   ```text
   atanor: the admin listener binds 0.0.0.0:4001 without TLS, so its token passes in clear; put a TLS proxy in front and set behind_tls_proxy (ATANOR_BEHIND_TLS_PROXY=true), or bind to loopback
   ```

   The setting is a declaration, not a check: the node cannot see whether the proxy is there. To leave nothing to
   declare, bind the listener to loopback (`ATANOR_ADMIN_LISTEN=127.0.0.1:4001`) and reach it through a tunnel or
   a proxy on the same host.

## Who may claim what

Every deploy token with `worker:<name>:deploy` and `activate` can claim any free host route, any cell namespace
that nobody owns, and outbound HTTP to any public host, unless the operator restricts it. Three settings do that;
unset, each one allows everything, and the node says so at start:

```text
atanor: this node trusts every deployer: any route host, cell namespace and outbound HTTP host is allowed; restrict them with ATANOR_HOSTS, ATANOR_NAMESPACES and ATANOR_HTTP_ALLOW
```

`GET /runtime` shows the state under `consent` (`{"hosts": false, "http_allow": false, "namespaces": false,
"open": true}`; `open` is true when none is set). A closed node, with all three set, in the format of
[configuration.md](configuration.md#the-daemon-environment-and-file):

```sh
ATANOR_HOSTS='shop=shop.example.com,*.shop.example.com;blog=blog.example.com'
ATANOR_NAMESPACES='carts=shop;posts=blog'
ATANOR_HTTP_ALLOW='shop=api.payments.example.com;blog=*'
```

- `ATANOR_HOSTS`: the hosts each worker may claim in its routes. A worker that is not listed claims none, and an
  activation outside the list fails with 422 `host_not_allowed`.
- `ATANOR_NAMESPACES`: the workers that may use each cell namespace. A namespace that is not listed stays open to
  the first worker that claims it.
- `ATANOR_HTTP_ALLOW`: the hosts each worker's manifest may list under `http.allow`. A worker that is not listed
  may call none.

## Prerequisites

- Two or more nodes of the image, started as in [configuration.md](configuration.md#the-daemon-environment-and-file),
  each with its own `ATANOR_ADVERTISE`, the same `ATANOR_STORE`, the same cookie and the same
  `ATANOR_GROUP` or none.
- A private network between the nodes and a load balancer that reaches ports 4000 and 4001 of each.

## Steps

1. **Keep the nodes on a private network.** The cookie is the only authentication between nodes, and whoever has
   it runs code on every node: treat it as a root password. Distribution is not encrypted, and forwarded
   requests, with their `Authorization` headers, cross it. Open 4369 and 9100 to 9110 between the nodes
   only (a security group, a firewall rule, a Docker network that has no published ports for them). Give the
   cookie its own random value, never the admin token, and pass it as a file:
   `ATANOR_COOKIE_FILE=/run/secrets/cookie`. Never give the cookie as a command-line argument:
   every user of the host sees arguments in the process list; use `RELEASE_COOKIE` in the environment instead.
   If the network between the nodes is not private, use TLS distribution
   ([how-to-run-a-cluster.md](how-to-run-a-cluster.md), the TLS distribution step;
   [design §4.3, "what the cookie protects"](design.md#43-limits-on-cell-calls-and-their-errors)).

2. **Set the address each node advertises.** `ATANOR_ADVERTISE` is the host name or IP, with a dot, that the other
   nodes reach this one at. The node publishes `atanor@<it>` in the bucket and the others dial it, so it must
   resolve from them and be the same after a restart ([discovery](configuration.md#discovery)). There is no list of
   peers to maintain.

3. **Give the bucket to the nodes, and trust it as you trust the cluster.** Whoever can write `<prefix>/nodes/`
   decides whom the nodes dial, and whoever can write the workers and heads decides what runs. The cookie still
   gates the handshake, but write access to the bucket must be as restricted as access to the nodes. Use a bucket
   (or a prefix with its own policy) that only the nodes and your deploy pipeline can write.

4. **Give the nodes S3 credentials the AWS way.** Prefer credentials that rotate: a web identity token or
   container credentials, or EC2 instance metadata, are used when no key is set ([the chain](configuration.md#aws-credentials)).
   For static keys use `AWS_ACCESS_KEY_ID_FILE` and `AWS_SECRET_ACCESS_KEY_FILE`, so that they do not show in
   `docker inspect`. The log says which source was used (`credentials=...`); it never prints a key.
   Without `ATANOR_S3_ENDPOINT` the endpoint is the AWS one of the region.

5. **Point the balancer at the nodes, and check `/health/serving`.** The ingress has no health path of its own.
   Check the admin port: `GET /health/serving` with the admin token answers 200 while the node is ready and has a
   quorum, and 503 while it starts, drains or has no quorum. A draining node leaves the rotation by itself. With
   HAProxy:

   ```text
   backend atanor_http
       balance roundrobin
       option redispatch
       retries 2
       retry-on conn-failure
       option httpchk
       http-check send meth GET uri /health/serving hdr authorization "Bearer ${ATANOR_ADMIN_TOKEN}"
       http-check expect status 200
       default-server check port 4001 inter 1s fall 2 rise 2
       timeout tunnel 1h
       server node-1 node-1.internal:4000
       server node-2 node-2.internal:4000
   ```

   `retry-on conn-failure` retries only a connection that failed: a request that was sent is never repeated. Use
   `/health/ready` instead only for a rolling restart that must not look at the quorum
   ([how-to-use-the-admin-api.md](how-to-use-the-admin-api.md)). Route a WebSocket and a long TCP
   connection with a tunnel timeout longer than your idle time (`timeout tunnel 1h` above).

6. **Terminate TLS at the balancer, and set `ATANOR_BEHIND_TLS_PROXY`** ([TLS at the proxy](#tls-at-the-proxy)).
   The balancer holds the certificate for your domains and forwards to 4000 on the private network. Do the same for
   4001 if operators or CI reach it from outside, with its own host name and a firewall allowing only them. Atanor
   terminates TLS itself only for TCP listeners that a worker claims (`tls_mode: :implicit` or `:starttls`,
   [how-to-serve-tcp.md](how-to-serve-tcp.md)). Behind a balancer a worker sees the balancer's address; read the
   client address from the header the balancer sets. Atanor logs a warning when a listener's certificate
   is expired, not yet valid or expires within `tls.expiry_warn_days` (14 by default), at start, at each reload
   and when the status changes, and it still serves that certificate. Alert on that log line, and keep a probe
   from outside that reads the served certificate's `notAfter`
   ([design §7.3, "Limits of TLS reload"](design.md#73-tcp-and-websockets)).

   Also restrict what a deployer may claim ([who may claim what](#who-may-claim-what)).

7. **Enforce the limits that a balancer does better.** The ingress bounds each read and each listener. It does not
   bound a whole request or the connections of one client address. Set header and body timeouts and a per-address
   connection limit on the balancer ([design §7.1, Limits](design.md#71-http)).

8. **Let a node leave gracefully.** On `SIGTERM` a node drains its cells and stops. `docker stop` must wait longer
   than `ATANOR_SHUTDOWN_MS` (75 s by default): use `--stop-timeout 90`, systemd `TimeoutStopSec=90` or Kubernetes `terminationGracePeriodSeconds: 90`
   ([the rule](configuration.md#the-stop-grace-period)).
   To replace nodes one by one, see [how-to-replace-a-node.md](how-to-replace-a-node.md).

9. **Plan for the cost of a cell.** The memory of a node grows with its awake cells, and the node limits itself to the cgroup
   limit of its container ([cells, limits and memory](configuration.md#cells-limits-memory-and-store-requests)). The
   data directory `/var/lib/atanor/cells` holds local copies of cells: give it a disk, not a RAM file system.
   [cell-cost.md](cell-cost.md) gives what one cell costs in memory, local disk and store traffic, and how to
   work out your own figures from it.

## Check it

From a machine outside the private network:

```sh
curl -si https://app.example.com/hello/world           # through the balancer, over TLS
curl -s --max-time 3 http://node-1.example.com:4369/ ; echo "exit $? (non-zero: epmd is not reachable from outside)"
```

From a node: `atanor status` ([cli.md](cli.md)), and `GET /health` on the admin port lists the nodes it is connected to.

## Troubleshooting

- **The balancer marks every node down.** The check needs the admin token and the admin port (4001), not 4000.
  `curl -H "authorization: Bearer $TOKEN" http://node:4001/health/serving` shows the reason: `starting`,
  `draining` or `no_quorum`.
- **Nodes do not see each other.** `ATANOR_ADVERTISE` does not resolve from the other node, 4369 or 9100 to 9110 is
  closed, the cookies differ, or the `ATANOR_GROUP` differs. `GET /health` on the admin port lists the connected nodes.
- **A node is ready late.** `/health/ready` answers 503 `starting` with a reason until the node has read its
  deployments from the bucket and joined. A bucket that cannot be read is named there.
- **Requests fail with 503 `no_quorum`.** The node cannot reach a majority of the nodes it knows: check the
  private network between them.

## Next steps

- [how-to-run-a-cluster.md](how-to-run-a-cluster.md): what a node failure does, and how to tune detection.
- [how-to-replace-a-node.md](how-to-replace-a-node.md): rolling a new build over the nodes.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md): scoped deploy tokens and the audit log.
- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md): deploying from CI.
