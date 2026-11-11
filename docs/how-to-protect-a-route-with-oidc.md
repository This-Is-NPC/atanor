# How to protect a route with an OIDC access token

**The question:** How do I make Atanor accept only requests that carry a valid
OIDC access token on a route, whatever the provider, and read the token's
claims in the worker?

This guide stands alone for the operator side. It assumes a worker that
already serves a route
([how-to-write-a-native-worker.md](how-to-write-a-native-worker.md)) and an
instance you start yourself, as in the README. The design is in
[design §7.5](design.md#75-bearer-tokens-on-a-route).

## What Atanor checks, and what it leaves to the worker

Atanor checks the token locally, with the provider's published keys: the
signature, `iss`, `aud`, `exp`, `nbf`, `iat`, the `typ` header and the scopes.
It never calls the provider for a request. It knows no provider-specific rule.
Whether `org_ids` contains an organization, whether `act` names an acceptable
client, whether `sub` equals `client_id`: the worker decides that, from the
claims.

The configuration is the operator's (the `auth:` option), not the manifest's:
a package must not choose which issuers the node trusts.

## Prerequisites

- The tools of the [README](../README.md#requirements).
- An OIDC provider that publishes `<issuer>/.well-known/openid-configuration`
  with a `jwks_uri`, and that signs access tokens as JWTs (RS256 by default).
- The host and the path prefix to protect, written as in a manifest route
  (a lower-case host or `*.domain` or `*`; a path starting with `/`).

## Steps

1. Add an `auth:` rule for the route to the instance. The `host` and `path`
   are a host pattern and a path prefix, written as in a manifest route: a rule
   for `{"api.example.com", "/api"}` protects `/api` and everything below it
   on that host, whichever worker's route serves it (see
   [how a rule is chosen](#how-a-rule-is-chosen)).

   ```elixir
   {Atanor,
    name: MyApp.Atanor,
    store: {Alambique.Store.S3, s3_config},
    data_dir: "/var/lib/myapp/cells",
    hosts: %{"api" => ["api.example.com"]},
    auth: [
      [
        host: "api.example.com",
        path: "/api",
        issuer: "https://id.example.com",
        audience: "https://api.example.com",
        scopes: ["notes.read"],
        types: ["at+jwt"],
        realm: "example"
      ]
    ]}
   ```

   `issuer` and `audience` are required. The other keys, with their defaults,
   are in the table of [design §7.5](design.md#75-bearer-tokens-on-a-route):
   `algorithms: ["RS256"]`, `leeway_s: 60`, `scopes: []`, `types` any (set it to
   what your provider issues, so that an ID token of the same issuer is not
   accepted as an access token). An
   invalid rule raises `ArgumentError` when the instance starts. An `http:`
   issuer is refused unless you set `oidc: [allow_http: true]` (loopback
   development only).

2. Call the route without a token. The worker is not called.

   ```sh
   curl -si http://127.0.0.1:4000/api/claims
   ```

   ```text
   HTTP/1.1 401 Unauthorized
   www-authenticate: Bearer realm="example"
   content-type: application/json; charset=utf-8

   {"error":"unauthorized"}
   ```

3. Call it with a token from your provider.

   ```sh
   curl -si -H "authorization: Bearer $TOKEN" http://127.0.0.1:4000/api/claims
   ```

   ```text
   HTTP/1.1 200 OK
   content-type: application/json

   {"claims":{"aud":"http://127.0.0.1:45595/v1","client_id":"web-portal","iss":"http://127.0.0.1:45595","org_ids":["org_personal_5f2c","org_company_8a91"],"scope":"openid email organizations","sub":"0b7d4a52-...","exp":1793566776,"iat":1793565876, ...}}
   ```

   The output above is abridged. It comes from a test OIDC provider as issuer and the probe
   worker of the test suite, which answers with `Atanor.Request.claims/1`; the
   claims are the ones the provider signed, unchanged.

4. Read the claims in the worker.

   - Native: `Atanor.Request.claims(request)` returns the claims as a map with
     string keys, or `nil` on a route without a rule.

     ```elixir
     def handle_request(request, env) do
       claims = Atanor.Request.claims(request)
       if "org_x" in List.wrap(claims["org_ids"]), do: ..., else: %Atanor.Response{status: 403}
     end
     ```

   - WASM and Plug workers: read the request header `x-atanor-claims`. Its
     value is the claims as JSON, base64url-encoded without padding. The WIT
     interfaces are unchanged.

   Atanor removes every `x-atanor-claims` header sent by a client (all
   copies, not only the first), on every route, so a worker may trust it on a
   route that has a rule. On a route without a rule it is always absent. A
   worker that calls another with `Atanor.Env.call/3` cannot set it either: the
   callee sees no claims, and the callee's rule does not apply to the call
   (workers you grant `workers:` are trusted); pass the user's identity in the
   request if the callee needs it.

5. Check the error answers. A token without a required scope, an invalid or
   expired token and a malformed request give these:

   ```text
   HTTP/1.1 403 Forbidden
   www-authenticate: Bearer realm="example", error="insufficient_scope", scope="openid"

   {"error":"insufficient_scope"}

   HTTP/1.1 401 Unauthorized
   www-authenticate: Bearer realm="example", error="invalid_token"

   {"error":"invalid_token"}
   ```

   | Case | Status | `error` |
   | --- | --- | --- |
   | No `Authorization`, or another scheme | 401 | none (the challenge has no `error`) |
   | Two `Authorization` headers, or `Bearer` with an empty or malformed token | 400 | `invalid_request` |
   | Bad signature, wrong `iss`/`aud`/`typ`/algorithm, expired, `nbf`/`iat` in the future, no `exp` | 401 | `invalid_token` |
   | Valid token without all the scopes | 403 | `insufficient_scope` |
   | No key could be fetched from the provider | 503, with `Retry-After` | `auth_unavailable` |

   The body carries the error code only, never the token or a claim. The
   precise reason is in telemetry (`[:atanor, :auth, :reject]`, see
   [telemetry.md](telemetry.md)), as an atom.

## How a rule is chosen

A rule does not belong to a route: it covers every request whose host and path
match it. Atanor first puts the request in one canonical form, the same one
routing uses ([design §7.1](design.md#71-http)): the host in lower case without
a trailing dot, the path with percent-escapes of unreserved characters decoded
(`/%61pi` is `/api`). A path with a `.` or `..` segment, an escaped `/`, a bad
escape or too many segments is answered 400 before any rule or route is looked
at. Then:

- A route below a protected prefix is protected too: with a rule for
  `/api`, a second worker's route `/api/public` still asks for a token.
- A rule for a host protects that host whichever worker serves it, and a
  rule for `*` every host.
- When several rules cover a request, the most specific wins: the exact host
  before `*.` suffixes before `*`, then the longest path prefix.
- To leave a part open, protect the specific paths, not their parent.
- A rule that matches no route protects nothing, and nothing warns about it:
  check a new rule with a request without a token, which must be 401.

Calls from one worker to another (`Atanor.Env.call/3`) are not requests to a
route: no rule applies, and the callee never sees claims. Grant `workers:`
only to workers you trust.

## Settings

The `oidc:` option sets the fetches of the discovery document and the JWKS.
Every value is a positive integer in milliseconds unless noted.

| Key | Default | Meaning |
| --- | --- | --- |
| `min_refresh_ms` | 60000 | A `kid` the cache does not know refreshes the JWKS at most once in this interval per issuer |
| `error_backoff_ms` | 5000 | After a failed fetch, the wait before the next attempt (not above `min_refresh_ms`) |
| `jwks_max_age_ms` | 3600000 | The keys are refreshed by the next request after this age; old keys keep serving if the refresh fails |
| `jwks_max_stale_ms` | 86400000 | How long old keys keep serving after `jwks_max_age_ms` while every refresh fails; then the answer is 503 `auth_unavailable` |
| `discovery_ttl_ms` | 3600000 | How long the `jwks_uri` of the discovery document is kept |
| `connect_timeout_ms` | 2000 | Connection timeout of a fetch |
| `receive_timeout_ms` | 5000 | Response timeout of a fetch |
| `max_response_bytes` | 1000000 | Larger discovery documents and JWKS are refused; the read stops at the limit |
| `allow_http` | false | Accept an `http:` issuer |

To drop the cached keys of a node at once, for example after the provider
withdrew a key, call `POST /auth/keys/flush` on the admin API of each node
([step 14](how-to-use-the-admin-api.md)). The next request fetches the keys
again.

Concurrent requests never stampede the provider: one process makes the
fetches, one at a time, and the requests that waited find the keys cached.

## Troubleshooting

- **Every request is 401 `invalid_token`.** Look at the `reason` of
  `[:atanor, :auth, :reject]`. `:issuer` and `:audience` mean the rule differs
  from the token's `iss` or `aud` (the issuer must match character for
  character, a trailing slash included). `:type` means the `typ` header is
  not in `types:`; many providers issue `JWT`, not `at+jwt`. `:algorithm`
  means the token uses an algorithm other than the rule's; add it to
  `algorithms:`. `:no_key` means no published key fits the `kid` and
  algorithm.
- **Every request is 503 `auth_unavailable`.** Atanor could not fetch the
  keys. Check the `[:atanor, :auth, :fetch]` events: `:unreachable` is a
  network or timeout problem, `{:status, code}` a refusal. The discovery
  document must name the same `issuer` and a `jwks_uri` on the same scheme,
  host and port, or it is refused.
- **A token signed with a freshly rotated key is rejected.** At most one
  refresh per `min_refresh_ms` happens. The token is accepted after the
  interval; lower the setting only if the provider tolerates it.
- **A key the provider withdrew still verifies.** The node keeps the keys for
  `jwks_max_age_ms`, and for `jwks_max_stale_ms` while the provider is
  unreachable. Flush them with `POST /auth/keys/flush` on each node.
- **A WebSocket closes with 1008 while frames flow.** The token of its
  upgrade expired (`exp`). The client connects again with a fresh token.
- **403 where the token has the scope.** Atanor reads `scope` (a
  space-separated string) and `scp` (an array, or a string). A provider that
  puts scopes in another claim needs the worker to check them.
- **A clock-skewed token is refused.** `leeway_s` (default 60) is added to
  `exp` and subtracted from `nbf` and `iat`.

## Next steps

- [design §7.5](design.md#75-bearer-tokens-on-a-route) for the algorithm rules
  and the key cache.
- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) to put the worker
  behind the route.
