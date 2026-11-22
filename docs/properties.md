# Property tests

**The question:** which rules of Atanor are checked by property tests
(StreamData), what does each prove, and which rules are left to example tests?

This page is for contributors. It stands alone. Read it when you add a rule
with an invariant and want to know where its property goes. A property here
states a rule once and checks it on generated inputs, so the edges (empty,
maximum sizes, unicode, percent-escapes, IPv6 forms, wildcards) are reached
without being listed by hand.

When you add a property, put a plausible bug (an off-by-one, a flipped
comparison, a dropped clause) into the `lib/` file and check that the property
fails. Properties are deterministic: they use no wall clock (the token bucket
and cron take the time as an argument), and `max_runs` bounds the run time of
each file.

Run the properties of one file with `mix test test/atanor/<file>`; the
cluster ones are tagged `cluster` (`mise run test:cluster`).

## Properties

A test is `file:name` in `test/atanor/` unless the path says otherwise.

| Rule | Module | Test | What it proves |
| --- | --- | --- | --- |
| Canonical path | `Route` | route_property_test: spellings of the same path give the same canonical path | Escapes of unreserved bytes decode, the others keep an upper case escape, empty segments stay |
| Canonical path | `Route` | route_property_test: the canonical path is a fixed point | Canonicalizing twice changes nothing |
| Path refusals | `Route` | route_property_test: refused segments are refused in any position | `.`, `..` (also escaped), escaped `/` and NUL, and bad escapes are refused wherever they sit |
| Path limit | `Route` | route_property_test: the number of segments is bounded | `max_path_segments` passes, one more is refused, empty segments do not count |
| Escape spelling | `Route` | route_property_test: every escaped byte has one canonical spelling | Any byte in either hex case has one canonical form |
| Canonical host | `Route` | route_property_test: the host is lower case..., the number of labels..., the length of a host... | Lower case, one trailing dot dropped, `max_host_labels` and 253 bytes are exact limits |
| Candidates | `Route` | route_property_test: host candidates..., path prefixes... | Candidates run from the most to the least specific and end in `*` and `/` |
| Cron grammar | `Jobs.Cron` | jobs_cron_property_test: parse accepts..., a value above the maximum..., bad steps... | The five-field grammar parses; out-of-range values, step 0, reversed ranges and wrong field counts are refused |
| Cron next time | `Jobs.Cron` | jobs_cron_property_test: the next time is the first firing minute after the instant | Equal to a minute-by-minute scan with an independent matcher (including the day-of-month or day-of-week rule and leap days) |
| Cron order | `Jobs.Cron` | jobs_cron_property_test: next_after is strictly later, aligned, and monotone; from a firing time... | Strictly after, on a minute, monotone in the start; no repeat of the same time |
| Sunday | `Jobs.Cron` | jobs_cron_property_test: day of week 7 is the same as 0 | `7` and `0` give the same times |
| Blocked ranges | `Egress` | egress_property_test: IPv4 follows the table of blocked ranges | Every range edge, and random addresses, agree with an independent table |
| Embedded IPv4 | `Egress` | egress_property_test: an IPv6 form that carries an IPv4 address... | IPv4-mapped, NAT64 and 6to4 are judged as the IPv4 address they carry |
| IPv6 ranges | `Egress` | egress_property_test: the IPv6 special ranges are blocked... | ULA, link-local, multicast, `::/96`, Teredo and local NAT64 are blocked whatever follows the prefix |
| Permit entries | `Egress` | egress_property_test: a CIDR entry parses..., invalid prefix lengths... | An entry parses to its base and length; bad lengths and shapes are refused |
| Permit decision | `Egress` | egress_property_test: an address is refused unless a permitted block of its own family holds it, a block permits exactly its own addresses | A blocked address passes only inside a permitted block of the same family |
| Redirects | `Egress` | egress_property_test: redirects keep credentials inside their origin and never leave https | Credentials only within the origin, https never downgrades, body only on 307/308 |
| Host coverage | `Manifest` | manifest_hosts_property_test: allow_covered? properties, host_covered? | An `http.allow` entry covered by an operator pattern reaches no host the pattern refuses; route hosts are covered by `*` and wider wildcards |
| Outbound match | `Manifest` | manifest_hosts_property_test: entries match by host, scheme and port | Wildcards match subdomains only; scheme and port narrow |
| Auth rule choice | `Auth` | auth_property_test: the most specific covering rule applies... | Host first (exact, longer wildcard, shorter, `*`), then the longest path prefix at segment boundaries |
| Bearer parsing | `Auth` | auth_property_test: the status follows the shape of the Authorization header, tokens with other bytes... | Missing or other scheme is 401, malformed or repeated is 400, a well-shaped token is judged as a token |
| Claims header | `Auth` | auth_property_test: encoded claims decode..., anything else decodes..., strip_claims... | Claims round trip; garbage never raises; every spelling of the header is dropped |
| Admin scopes | `Admin.Scope` | admin_scope_pure_property_test | Format and parse round trip, only the documented forms parse, `allows?` is the exact match with the worker wildcard |
| Frame bucket | `HTTP.Socket` | websocket_bucket_property_test | The burst passes at once and no more; accepted frames stay within burst plus rate times time; a refused bucket recovers after one period; idle time banks at most the burst |
| Job slots | `Jobs.Slots` | jobs_slots_property_test | Against a model: node and worker limits hold, a dead holder gives its slots back, transfer moves ownership, a closed node grants nothing |
| Admission gates | `Admission` | admission_property_test | Against a model: the node never admits at or over the memory or disk mark, never refuses below both, holds its verdict between them, keeps the in-flight count at 0 after every leave, and never refuses by a gate that has no limit or budget |
| Disk budget | `Disk` | disk_property_test | The derived `wal: [checkpoint_bytes:]` and `local_cache: [max_bytes:]` stay within the budget together, an option the operator gave wins, and the escalation never falls as the use rises, with hysteresis between its marks |
| Failed-token throttle | `Admin.Throttle` | admin_throttle_property_test | No address gets more failures than the limit in a window, one under it is never refused, and the table never holds more addresses than its cap |
| WASM batch cap | `Wasm` | wasm_caps_property_test | A batch is refused exactly when the sum of its results passes `wasm.max_batch_bytes`; an accepted one stays under it |
| Manifest parse | `Manifest` | manifest_test: every corrupted manifest is rejected..., valid manifests parse and round trip | Corruption is refused; valid manifests round trip through `to_map` |
| Package id | `Package` | package_test: the same inputs give the same bytes and the same id..., any change to the bytes... | Id is a function of the content, key order does not matter, a changed byte fails or changes the id |
| Cell addressing | `Cell` | cell_test: id and parse round trip, invalid namespaces..., keys with a slash or NUL... | Ids round trip; invalid namespaces and keys are refused |
| Partition routing | `Partition` | partition_test, cluster/partitions_property_test: the routing of partitioned cells is stable; the keys spread | Same key, same partition; spread over partitions |
| Token validation | `Auth.Token` | auth_token_test: valid tokens pass..., no invalid token passes, tokens signed by an unpublished key... | Valid tokens keep their claims; no invalid one passes |
| Admin token scope | `Admin` | admin_scope_property_test (three properties) | Out-of-scope requests get 403 and change nothing; activate needs both scopes; bad tokens get 401 |
| Job enqueue | `Jobs` | jobs_property_test: enqueue keeps the job rows, unique keys and the wake-up consistent | Unique keys and rows agree with a model |
| Job claim | `Jobs` | jobs_claim_test: never more than cell_concurrency..., a batch never claims a job twice... | Concurrency limit, due order, no job lost or claimed twice |
| Fence | `Fence` | fence_test (two properties) | No handler, job or alarm starts before the lease margin |
| Hot cells policy | `HotCells.Policy` | hot_cells_policy_test (six properties) | Hysteresis, hold time, valid move targets, residence, affinity |
| Failure detector | `Detector` | detector_phi_test | Phi never decreases while a heartbeat is awaited |
| Deployments | `Deployments` | deployments_property_test | Each request sees one deployment, active during the request |
| WASM grants | `Wasm` | wasm_properties_test (two properties) | A component instantiates iff its imports are granted; granted bindings still refuse other namespaces, secrets and workers |
| Cluster behavior | cluster | cluster/properties_test (two), alarms_test, channels_test, hot_cells_property_test, jobs_release_test, replica_bound_property_test | Single owner per cell, at-least-once alarms, channel delivery, no job runs twice after a release, bounded reads (tag `cluster`) |

## Rules left to example tests

| Rule | Why |
| --- | --- |
| `Config` option checks | Hundreds of independent options with their own messages; no single invariant to generate against. Covered by the config and limits tests. |
| `Package.parse/2` size limits | The limits are two configured numbers; `package_limits_test` checks both edges by example. |
| `Admin.Tokens` format and expiry | Needs the metadata store; the 401 matrix is already generated in `admin_scope_property_test`. |
| Sweep operation states and job states | Transitions need a running cell; covered by `sweeps_test`, `jobs_test` and the cluster tests. |
| `Registry.claim_refresh`, channel limits, fence eviction | Need processes or several nodes; the cluster tests and `channels_test` cover them. |
| Feed positions and WASM wire encoding | Defined by Alambique and the component model; checked end to end by `feed_test` and `wasm_test`. |

## Wildcard grants

With `http_allow: %{"w" => ["example.com"]}`, a manifest cannot grant itself `*.example.com`. A wildcard entry needs
`*` or a wildcard pattern whose domain is the same or a parent (design §3.3). The example test is
`grants_test: an exact http_allow host does not let a manifest grant its subdomains`.
