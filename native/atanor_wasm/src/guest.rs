//! One guest call: a fresh store and instance, limits, the incoming request
//! and the collected response.

use std::fmt;
use std::sync::atomic::Ordering::Relaxed;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use rustler::{Encoder, LocalPid, NifMap, OwnedEnv, ResourceArc};
use wasmtime::component::ResourceTable;
use wasmtime::{ResourceLimiter, Store, Trap, UpdateDeadline};
use wasmtime_wasi::p2::pipe::MemoryOutputPipe;
use wasmtime_wasi::{WasiCtx, WasiCtxView, WasiView};
use wasmtime_wasi_http::p2::bindings::http::types::{ErrorCode, Scheme};
use wasmtime_wasi_http::p2::body::HyperOutgoingBody;
use wasmtime_wasi_http::{
    Error as HttpError, WasiBody, WasiHttpCtx, WasiHttpCtxView, WasiHttpHooks, WasiHttpView,
};

use crate::component::Prepared;
use crate::engine::{self, Cpu, INSTANCES, MEMORIES, TABLES};
use crate::handlers::local::atanor::worker::socket_handler::Frame as LocalFrame;
use crate::handlers::local::exports::atanor::worker::socket_local as local;
use crate::handlers::socket::exports::atanor::worker::socket_handler as ws;
use crate::host::{parse_headers, string, Link, Reply};
use crate::stats;
use crate::wire::Wire;

/// What stopped a guest.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LimitHit {
    Timeout,
    Memory,
    Cpu,
}

impl fmt::Display for LimitHit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?} limit reached")
    }
}

impl std::error::Error for LimitHit {}

#[derive(NifMap, Clone)]
pub struct Limits {
    pub timeout_ms: u64,
    pub memory_bytes: u64,
    pub cpu_ms: u64,
    pub fuel: u64,
    pub max_response_bytes: u64,
    pub queue_wait_ms: u64,
    pub stderr_bytes: u64,
    pub table_elements: u64,
    pub max_resources: u64,
    pub max_field_bytes: u64,
}

pub struct ReqData {
    pub method: String,
    pub scheme: String,
    pub authority: String,
    pub path_query: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// What a job asks of the guest.
pub enum Call {
    Http(ReqData),
    Alarm {
        namespace: String,
        key: String,
        payload: Vec<u8>,
    },
    Job {
        namespace: String,
        key: String,
        id: String,
        idempotency_key: String,
        kind: String,
        payload: Vec<u8>,
        attempt: u32,
    },
    Open {
        socket: String,
        request: SocketRequest,
    },
    Message {
        socket: String,
        message: Incoming,
    },
    Close {
        socket: String,
    },
    Local {
        socket: String,
        frame: Incoming,
    },
}

pub struct SocketRequest {
    pub method: String,
    pub path: String,
    pub query: String,
    pub headers: Vec<(String, String)>,
}

pub enum Incoming {
    Text(String),
    Binary(Vec<u8>),
    Cell(Vec<u8>),
}

impl Call {
    /// Reads the call as Elixir sends it: `{:http, method, scheme, authority,
    /// path_query, headers, body}`, `{:alarm, namespace, key, payload}`,
    /// `{:ws_open, socket, method, path, query, headers}`,
    /// `{:ws_message, socket, :text | :binary | :cell, data}`,
    /// `{:ws_local, socket, :text | :binary, data}` or `{:ws_close, socket}`.
    pub fn parse(wire: Wire) -> Option<Call> {
        let Wire::Tuple(items) = wire else {
            return None;
        };
        let mut it = items.into_iter();
        let Some(Wire::Atom(kind)) = it.next() else {
            return None;
        };
        let it = &mut it;
        match kind.as_str() {
            "http" => {
                let (method, scheme, authority, path_query) =
                    (text(it)?, text(it)?, text(it)?, text(it)?);
                let headers = parse_headers(it.next()?);
                Some(Call::Http(ReqData {
                    method,
                    scheme,
                    authority,
                    path_query,
                    headers,
                    body: bin(it)?,
                }))
            }
            "alarm" => Some(Call::Alarm {
                namespace: text(it)?,
                key: text(it)?,
                payload: bin(it)?,
            }),
            "job" => Some(Call::Job {
                namespace: text(it)?,
                key: text(it)?,
                id: text(it)?,
                idempotency_key: text(it)?,
                kind: text(it)?,
                payload: bin(it)?,
                attempt: match it.next()? {
                    Wire::Int(n) if n >= 0 => n as u32,
                    _ => return None,
                },
            }),
            "ws_open" => {
                let (socket, method, path, query) = (text(it)?, text(it)?, text(it)?, text(it)?);
                let headers = parse_headers(it.next()?);
                Some(Call::Open {
                    socket,
                    request: SocketRequest {
                        method,
                        path,
                        query,
                        headers,
                    },
                })
            }
            "ws_message" => {
                let socket = text(it)?;
                let Some(Wire::Atom(what)) = it.next() else {
                    return None;
                };
                let data = bin(it)?;
                let message = match what.as_str() {
                    "text" => Incoming::Text(String::from_utf8(data).ok()?),
                    "binary" => Incoming::Binary(data),
                    "cell" => Incoming::Cell(data),
                    _ => return None,
                };
                Some(Call::Message { socket, message })
            }
            "ws_local" => {
                let socket = text(it)?;
                let Some(Wire::Atom(what)) = it.next() else {
                    return None;
                };
                let data = bin(it)?;
                let frame = match what.as_str() {
                    "text" => Incoming::Text(String::from_utf8(data).ok()?),
                    "binary" => Incoming::Binary(data),
                    _ => return None,
                };
                Some(Call::Local { socket, frame })
            }
            "ws_close" => Some(Call::Close { socket: text(it)? }),
            _ => None,
        }
    }
}

fn text(it: &mut std::vec::IntoIter<Wire>) -> Option<String> {
    Some(string(it.next()?))
}

fn bin(it: &mut std::vec::IntoIter<Wire>) -> Option<Vec<u8>> {
    match it.next()? {
        Wire::Bin(b) => Some(b),
        _ => None,
    }
}

pub struct Job {
    pub pre: ResourceArc<Prepared>,
    pub call: Call,
    pub limits: Limits,
    pub pid: LocalPid,
    pub tag: u64,
    pub queued_at: Instant,
}

/// Memory cap that traps the guest with the memory limit. The cap is for
/// all the memories of the call together.
pub struct Limiter {
    max: usize,
    table_elements: usize,
    total: usize,
    pub peak: usize,
}

impl ResourceLimiter for Limiter {
    fn memory_growing(
        &mut self,
        current: usize,
        desired: usize,
        _max: Option<usize>,
    ) -> wasmtime::Result<bool> {
        let total = self.total.saturating_add(desired.saturating_sub(current));
        if total > self.max {
            return Err(wasmtime::Error::new(LimitHit::Memory));
        }
        self.total = total;
        self.peak = self.peak.max(total);
        Ok(true)
    }

    fn table_growing(
        &mut self,
        _current: usize,
        desired: usize,
        _max: Option<usize>,
    ) -> wasmtime::Result<bool> {
        Ok(desired <= self.table_elements)
    }

    fn instances(&self) -> usize {
        INSTANCES as usize
    }

    fn tables(&self) -> usize {
        TABLES as usize
    }

    fn memories(&self) -> usize {
        MEMORIES as usize
    }
}

/// Outbound HTTP goes to Elixir, which applies the `http.allow` grant.
pub struct Hooks {
    link: Link,
    max_body: usize,
}

pub struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    http: WasiHttpCtx,
    hooks: Hooks,
    limiter: Limiter,
    pub link: Link,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

impl WasiHttpView for State {
    fn http(&mut self) -> WasiHttpCtxView<'_> {
        WasiHttpCtxView {
            ctx: &mut self.http,
            table: &mut self.table,
            hooks: &mut self.hooks,
        }
    }
}

impl WasiHttpHooks for Hooks {
    fn send_request(
        &mut self,
        request: http::Request<WasiBody>,
        _options: Option<wasmtime_wasi_http::RequestOptions>,
        _fut: Box<dyn std::future::Future<Output = Result<(), HttpError>> + Send>,
    ) -> Box<
        dyn std::future::Future<
                Output = wasmtime_wasi_http::Result<(
                    http::Response<WasiBody>,
                    Box<dyn std::future::Future<Output = Result<(), HttpError>> + Send>,
                )>,
            > + Send,
    > {
        let link = self.link.clone();
        let max = self.max_body;
        Box::new(async move {
            let (parts, body) = request.into_parts();
            let body = collect(body, max)
                .await
                .map_err(|_| HttpError::HttpRequestBodySize(None))?;
            let uri = &parts.uri;
            let headers = parts
                .headers
                .iter()
                .map(|(n, v)| {
                    Wire::Tuple(vec![
                        Wire::text(n.as_str()),
                        Wire::Bin(v.as_bytes().to_vec()),
                    ])
                })
                .collect();
            let args = vec![
                Wire::text(parts.method.as_str()),
                Wire::text(uri.scheme_str().unwrap_or("https")),
                Wire::text(uri.host().unwrap_or("")),
                Wire::Int(uri.port_u16().map(i64::from).unwrap_or(0)),
                Wire::text(uri.path()),
                Wire::text(uri.query().unwrap_or("")),
                Wire::List(headers),
                Wire::Bin(body),
            ];
            let reply = link
                .call("http", args)
                .await
                .map_err(|e| HttpError::InternalError(Some(e.to_string())))?;
            let response = match reply {
                Reply::Ok(wire) => crate::host::parse_response(wire),
                Reply::Err { kind, .. } if kind == "not_granted" => {
                    return Err(HttpError::HttpRequestDenied)
                }
                Reply::Err { .. } => return Err(HttpError::ConnectionRefused),
            };
            let (status, headers, body) = response.ok_or(HttpError::HttpProtocolError)?;
            let mut builder = http::Response::builder().status(status);
            for (n, v) in headers {
                builder = builder.header(n, v);
            }
            let body: WasiBody = Full::new(Bytes::from(body))
                .map_err(|never| match never {})
                .boxed_unsync();
            let response = builder
                .body(body)
                .map_err(|_| HttpError::HttpProtocolError)?;
            let done: Box<dyn std::future::Future<Output = Result<(), HttpError>> + Send> =
                Box::new(std::future::ready(Ok(())));
            Ok((response, done))
        })
    }
}

/// Host resources (fields, streams, pollables) are outside the memory limiter, so their count is capped.
fn resource_table(max: usize) -> ResourceTable {
    let mut table = ResourceTable::new();
    table.set_max_capacity(max);
    table
}

/// Each field set holds host memory up to this size.
fn http_ctx(max_field_bytes: usize) -> WasiHttpCtx {
    let mut ctx = WasiHttpCtx::new();
    ctx.set_field_size_limit(max_field_bytes);
    ctx
}

/// The CPU time this thread has used, from the kernel.
fn thread_cpu() -> Duration {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

struct TooLarge;

/// Reads a body up to `max` bytes.
async fn collect<B>(mut body: B, max: usize) -> Result<Vec<u8>, TooLarge>
where
    B: http_body::Body<Data = Bytes> + Unpin,
{
    let mut out = Vec::new();
    while let Some(Ok(frame)) = body.frame().await {
        if let Some(data) = frame.data_ref() {
            if out.len() + data.len() > max {
                return Err(TooLarge);
            }
            out.extend_from_slice(data);
        }
    }
    Ok(out)
}

type Collected = Result<(u16, Vec<(String, String)>, Vec<u8>), Failure>;

enum Failure {
    TooLarge,
    NoResponse,
    Guest(ErrorCode),
}

async fn collect_response(
    rx: tokio::sync::oneshot::Receiver<Result<http::Response<HyperOutgoingBody>, ErrorCode>>,
    max: usize,
) -> Collected {
    let response = rx
        .await
        .map_err(|_| Failure::NoResponse)?
        .map_err(Failure::Guest)?;
    let (parts, body) = response.into_parts();
    let headers = parts
        .headers
        .iter()
        .map(|(n, v)| {
            (
                n.as_str().to_string(),
                String::from_utf8_lossy(v.as_bytes()).into_owned(),
            )
        })
        .collect();
    let body = collect(body, max).await.map_err(|_| Failure::TooLarge)?;
    Ok((parts.status.as_u16(), headers, body))
}

#[derive(Default)]
struct Timing {
    instantiate_ns: u64,
    run_ns: u64,
    cpu_ns: u64,
    memory_bytes: u64,
    fuel_used: u64,
}

impl Timing {
    /// Records the end of the guest's run.
    fn finish(
        &mut self,
        store: &Store<State>,
        cpu: Cpu,
        limits: &Limits,
        run0: Instant,
        cpu_start: Duration,
    ) {
        self.run_ns = run0.elapsed().as_nanos() as u64;
        self.cpu_ns = (thread_cpu() - cpu_start).as_nanos() as u64;
        self.memory_bytes = store.data().limiter.peak as u64;
        if cpu == Cpu::Fuel {
            self.fuel_used = limits.fuel.saturating_sub(store.get_fuel().unwrap_or(0));
        }
    }
}

/// Runs a job and sends the result to the process that submitted it.
pub async fn run(job: Job) {
    let runtime = engine::runtime().expect("configured");
    let started = tokio::time::Instant::now();
    let mut timing = Timing::default();
    let mut stderr = Vec::new();

    stats::bump(&stats::CALLS);
    let result = if job.queued_at.elapsed() > Duration::from_millis(job.limits.queue_wait_ms) {
        stats::bump(&stats::REJECTED);
        Wire::Tuple(vec![Wire::atom("error"), Wire::atom("overloaded")])
    } else {
        stats::LIVE_INSTANCES.fetch_add(1, Relaxed);
        let result = execute(&job, runtime.cpu, started, &mut timing, &mut stderr).await;
        stats::LIVE_INSTANCES.fetch_sub(1, Relaxed);
        stats::add(&stats::INSTANTIATE_NS, timing.instantiate_ns);
        stats::add(&stats::CALL_NS, timing.run_ns);
        stats::add(&stats::MEMORY_PEAK_TOTAL, timing.memory_bytes);
        result
    };

    let timing = Wire::List(vec![
        Wire::Int(timing.instantiate_ns as i64),
        Wire::Int(timing.run_ns as i64),
        Wire::Int(timing.cpu_ns as i64),
        Wire::Int(timing.memory_bytes as i64),
        Wire::Int(timing.fuel_used as i64),
    ]);
    report(&job.pid, job.tag, result, Wire::Bin(stderr), timing);
}

/// Sends the end of a call to the process that submitted it.
fn report(pid: &LocalPid, tag: u64, result: Wire, stderr: Wire, timing: Wire) {
    let _ = OwnedEnv::new().send_and_clear(pid, |env| {
        (
            rustler::Atom::from_str(env, "atanor_wasm").unwrap(),
            tag,
            rustler::Atom::from_str(env, "done").unwrap(),
            result,
            stderr,
            timing,
        )
            .encode(env)
    });
}

/// Ends a call whose run panicked.
pub fn report_panic(pid: &LocalPid, tag: u64) {
    report(
        pid,
        tag,
        error("guest", Wire::text("the host panicked")),
        Wire::Bin(Vec::new()),
        Wire::Nil,
    );
}

fn error(kind: &str, detail: Wire) -> Wire {
    Wire::Tuple(vec![
        Wire::atom("error"),
        Wire::Tuple(vec![Wire::atom(kind), detail]),
    ])
}

fn limit(kind: LimitHit) -> Wire {
    match kind {
        LimitHit::Timeout => stats::bump(&stats::TRAPS_TIMEOUT),
        LimitHit::Memory => stats::bump(&stats::TRAPS_MEMORY),
        LimitHit::Cpu => stats::bump(&stats::TRAPS_CPU),
    }
    error("limit", Wire::atom(&format!("{kind:?}").to_lowercase()))
}

fn classify(e: &wasmtime::Error, cpu: Cpu) -> Wire {
    if let Some(hit) = e.downcast_ref::<LimitHit>() {
        if *hit == LimitHit::Cpu {
            stats::bump(&stats::EPOCH_INTERRUPTS);
        }
        return limit(*hit);
    }
    if e.downcast_ref::<Trap>() == Some(&Trap::OutOfFuel) && cpu == Cpu::Fuel {
        stats::bump(&stats::FUEL_INTERRUPTS);
        return limit(LimitHit::Cpu);
    }
    stats::bump(&stats::TRAPS_OTHER);
    let kind = if e.downcast_ref::<Trap>().is_some() {
        "trap"
    } else {
        "guest"
    };
    error(kind, Wire::text(format!("{e:#}")))
}

async fn execute(
    job: &Job,
    cpu: Cpu,
    started: tokio::time::Instant,
    timing: &mut Timing,
    stderr_out: &mut Vec<u8>,
) -> Wire {
    let limits = &job.limits;
    let runtime = engine::runtime().expect("configured");
    let deadline = started + Duration::from_millis(limits.timeout_ms);
    let wall_deadline = Instant::now() + Duration::from_millis(limits.timeout_ms);
    let link = Link {
        pid: job.pid,
        tag: job.tag,
        deadline,
    };
    let stderr = MemoryOutputPipe::new(limits.stderr_bytes as usize);

    let mut store = Store::new(
        &runtime.engine,
        State {
            wasi: WasiCtx::builder().stderr(stderr.clone()).build(),
            table: resource_table(limits.max_resources as usize),
            http: http_ctx(limits.max_field_bytes as usize),
            hooks: Hooks {
                link: link.clone(),
                max_body: limits.max_response_bytes as usize,
            },
            limiter: Limiter {
                max: limits.memory_bytes as usize,
                table_elements: limits.table_elements as usize,
                total: 0,
                peak: 0,
            },
            link,
        },
    );
    store.limiter(|s| &mut s.limiter);
    store.set_epoch_deadline(1);

    let cpu_start = thread_cpu();
    let cpu_limit = Duration::from_millis(limits.cpu_ms);
    store.epoch_deadline_callback(move |_| {
        if Instant::now() >= wall_deadline {
            return Err(wasmtime::Error::new(LimitHit::Timeout));
        }
        if cpu == Cpu::Epoch && thread_cpu() - cpu_start >= cpu_limit {
            return Err(wasmtime::Error::new(LimitHit::Cpu));
        }
        Ok(UpdateDeadline::Continue(1))
    });
    if cpu == Cpu::Fuel {
        let _ = store.set_fuel(limits.fuel);
    }

    let outcome = tokio::time::timeout_at(deadline, async {
        match &job.call {
            Call::Http(req) => http(job, req, store, cpu, cpu_start, timing).await,
            _ => handler(job, store, cpu, cpu_start, timing).await,
        }
    })
    .await;

    *stderr_out = stderr.contents().to_vec();
    match outcome {
        Ok(wire) => wire,
        Err(_) => limit(LimitHit::Timeout),
    }
}

/// Serves an HTTP request through `wasi:http/incoming-handler`.
async fn http(
    job: &Job,
    req: &ReqData,
    mut store: Store<State>,
    cpu: Cpu,
    cpu_start: Duration,
    timing: &mut Timing,
) -> Wire {
    let limits = &job.limits;
    let request = match build_request(req) {
        Ok(r) => r,
        Err(e) => return error("guest", Wire::text(e)),
    };
    let scheme = if req.scheme == "https" {
        Scheme::Https
    } else {
        Scheme::Http
    };
    let (tx, rx) = tokio::sync::oneshot::channel();
    let slot = Arc::new(Mutex::new(Some(tx)));
    let (incoming, out) = {
        let mut http = store.data_mut().http();
        let incoming = http.new_incoming_request(scheme, request);
        let sender = slot.clone();
        let out = http.new_response_outparam_from_callback(move |r| {
            if let Some(tx) = sender.lock().unwrap().take() {
                let _ = tx.send(r);
            }
        });
        match (incoming, out) {
            (Ok(i), Ok(o)) => (i, o),
            _ => return error("guest", Wire::text("cannot build the request")),
        }
    };

    let t0 = Instant::now();
    let proxy = match job.pre.pre.instantiate_async(&mut store).await {
        Ok(p) => p,
        Err(e) => return classify(&e, cpu),
    };
    timing.instantiate_ns = t0.elapsed().as_nanos() as u64;

    let run0 = Instant::now();
    let mut call = Box::pin(
        proxy
            .wasi_http_incoming_handler()
            .call_handle(&mut store, incoming, out),
    );
    let mut collect = Box::pin(collect_response(rx, limits.max_response_bytes as usize));

    enum First {
        Guest(wasmtime::Result<()>),
        Response(Collected),
    }
    let first = tokio::select! {
        r = &mut call => First::Guest(r),
        c = &mut collect => First::Response(c),
    };
    drop(call);
    timing.finish(&store, cpu, limits, run0, cpu_start);

    let collected = match first {
        First::Guest(Err(e)) => return classify(&e, cpu),
        First::Guest(Ok(())) => {
            // Closing the sender and the store ends a response the guest
            // never finished.
            slot.lock().unwrap().take();
            drop(store);
            collect.await
        }
        First::Response(c) => c,
    };
    match collected {
        Ok((status, headers, body)) => {
            stats::bump(&stats::CALLS_OK);
            let headers = headers
                .into_iter()
                .map(|(n, v)| Wire::Tuple(vec![Wire::text(n), Wire::text(v)]))
                .collect();
            Wire::Tuple(vec![
                Wire::atom("ok"),
                Wire::Tuple(vec![
                    Wire::Int(status as i64),
                    Wire::List(headers),
                    Wire::Bin(body),
                ]),
            ])
        }
        Err(Failure::TooLarge) => {
            Wire::Tuple(vec![Wire::atom("error"), Wire::atom("response_too_large")])
        }
        Err(Failure::NoResponse) => {
            error("guest", Wire::text("the guest returned without a response"))
        }
        Err(Failure::Guest(code)) => error("guest", Wire::text(format!("{code:?}"))),
    }
}

/// Calls the alarm or socket handler the component exports.
async fn handler(
    job: &Job,
    mut store: Store<State>,
    cpu: Cpu,
    cpu_start: Duration,
    timing: &mut Timing,
) -> Wire {
    let t0 = Instant::now();
    let run0;
    let result = match &job.call {
        Call::Alarm {
            namespace,
            key,
            payload,
        } => {
            let Some(pre) = &job.pre.alarm else {
                return error("guest", Wire::text("no alarm handler"));
            };
            let guest = match pre.instantiate_async(&mut store).await {
                Ok(g) => g,
                Err(e) => return classify(&e, cpu),
            };
            timing.instantiate_ns = t0.elapsed().as_nanos() as u64;
            run0 = Instant::now();
            guest
                .atanor_worker_alarm_handler()
                .call_handle_alarm(&mut store, namespace, key, payload)
                .await
                .map(|r| r.map(|()| Wire::Nil))
        }
        Call::Job {
            namespace,
            key,
            id,
            idempotency_key,
            kind,
            payload,
            attempt,
        } => {
            let Some(pre) = &job.pre.job else {
                return error("guest", Wire::text("no job handler"));
            };
            let guest = match pre.instantiate_async(&mut store).await {
                Ok(g) => g,
                Err(e) => return classify(&e, cpu),
            };
            timing.instantiate_ns = t0.elapsed().as_nanos() as u64;
            run0 = Instant::now();
            guest
                .atanor_worker_job_handler()
                .call_handle_job(
                    &mut store,
                    namespace,
                    key,
                    id,
                    idempotency_key,
                    kind,
                    payload,
                    *attempt,
                )
                .await
                .map(|r| r.map(|()| Wire::Nil))
        }
        Call::Http(_) => unreachable!("served by `http`"),
        Call::Local { socket, frame } => {
            let Some(pre) = &job.pre.local else {
                return error("guest", Wire::text("no local socket handler"));
            };
            let guest = match pre.instantiate_async(&mut store).await {
                Ok(g) => g,
                Err(e) => return classify(&e, cpu),
            };
            timing.instantiate_ns = t0.elapsed().as_nanos() as u64;
            run0 = Instant::now();
            let frame = match frame {
                Incoming::Text(t) => LocalFrame::Text(t.clone()),
                Incoming::Binary(b) => LocalFrame::Binary(b.clone()),
                Incoming::Cell(_) => unreachable!("not a frame"),
            };
            guest
                .atanor_worker_socket_local()
                .call_on_frame(&mut store, socket, &frame)
                .await
                .map(|r| {
                    r.map(|verdict| match verdict {
                        local::Verdict::Pass => Wire::atom("pass"),
                        local::Verdict::Drop => Wire::atom("drop"),
                    })
                })
        }
        socket_call => {
            let Some(pre) = &job.pre.socket else {
                return error("guest", Wire::text("no socket handler"));
            };
            let guest = match pre.instantiate_async(&mut store).await {
                Ok(g) => g,
                Err(e) => return classify(&e, cpu),
            };
            timing.instantiate_ns = t0.elapsed().as_nanos() as u64;
            run0 = Instant::now();
            socket(
                guest.atanor_worker_socket_handler(),
                &mut store,
                socket_call,
            )
            .await
        }
    };
    timing.finish(&store, cpu, &job.limits, run0, cpu_start);

    match result {
        Ok(Ok(wire)) => {
            stats::bump(&stats::CALLS_OK);
            Wire::Tuple(vec![Wire::atom("ok"), wire])
        }
        Ok(Err(message)) => error("guest", Wire::text(message)),
        Err(e) => classify(&e, cpu),
    }
}

/// One call of the socket handler, with its result as the wire term Elixir expects.
async fn socket(
    handler: &ws::Guest,
    store: &mut Store<State>,
    call: &Call,
) -> wasmtime::Result<Result<Wire, String>> {
    Ok(match call {
        Call::Open { socket, request } => {
            let request = ws::Request {
                method: request.method.clone(),
                path: request.path.clone(),
                query: request.query.clone(),
                headers: request.headers.clone(),
            };
            handler
                .call_on_open(store, socket, &request)
                .await?
                .map(|upgrade| match upgrade {
                    ws::Upgrade::Accept => Wire::atom("accept"),
                    ws::Upgrade::Reject(r) => Wire::Tuple(vec![
                        Wire::atom("reject"),
                        Wire::Tuple(vec![
                            Wire::Int(r.status as i64),
                            headers_wire(r.headers),
                            Wire::Bin(r.body),
                        ]),
                    ]),
                })
        }
        Call::Message { socket, message } => {
            let message = match message {
                Incoming::Text(t) => ws::Incoming::Text(t.clone()),
                Incoming::Binary(b) => ws::Incoming::Binary(b.clone()),
                Incoming::Cell(b) => ws::Incoming::Cell(b.clone()),
            };
            handler
                .call_on_message(store, socket, &message)
                .await?
                .map(|reply| {
                    let frames = reply
                        .frames
                        .into_iter()
                        .map(|f| match f {
                            ws::Frame::Text(t) => {
                                Wire::Tuple(vec![Wire::atom("text"), Wire::text(t)])
                            }
                            ws::Frame::Binary(b) => {
                                Wire::Tuple(vec![Wire::atom("binary"), Wire::Bin(b)])
                            }
                        })
                        .collect();
                    Wire::Tuple(vec![
                        Wire::List(frames),
                        Wire::atom(if reply.close { "true" } else { "false" }),
                    ])
                })
        }
        Call::Close { socket } => {
            handler.call_on_close(store, socket).await?;
            Ok(Wire::Nil)
        }
        Call::Http(_) | Call::Alarm { .. } | Call::Job { .. } | Call::Local { .. } => {
            unreachable!("not a socket call")
        }
    })
}

fn headers_wire(headers: Vec<(String, String)>) -> Wire {
    Wire::List(
        headers
            .into_iter()
            .map(|(n, v)| Wire::Tuple(vec![Wire::text(n), Wire::text(v)]))
            .collect(),
    )
}

fn build_request(r: &ReqData) -> Result<http::Request<Full<Bytes>>, String> {
    let mut builder = http::Request::builder()
        .method(r.method.as_str())
        .uri(format!("{}://{}{}", r.scheme, r.authority, r.path_query));
    for (n, v) in &r.headers {
        builder = builder.header(n.as_str(), v.as_str());
    }
    builder
        .body(Full::new(Bytes::from(r.body.clone())))
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn growing_memory_past_the_cap_is_the_memory_limit() {
        let mut limiter = Limiter {
            max: 1000,
            table_elements: 100_000,
            total: 0,
            peak: 0,
        };
        assert!(limiter.memory_growing(0, 600, None).unwrap());
        assert!(limiter.memory_growing(600, 1000, None).unwrap());
        let error = limiter.memory_growing(1000, 1001, None).unwrap_err();
        assert_eq!(error.downcast_ref::<LimitHit>(), Some(&LimitHit::Memory));
        assert_eq!(limiter.peak, 1000);
    }

    #[test]
    fn the_memory_cap_is_for_all_memories_together() {
        let mut limiter = Limiter {
            max: 1000,
            table_elements: 100_000,
            total: 0,
            peak: 0,
        };
        assert!(limiter.memory_growing(0, 600, None).unwrap());
        // A second memory starts at 0: 600 + 600 is over the cap.
        let error = limiter.memory_growing(0, 600, None).unwrap_err();
        assert_eq!(error.downcast_ref::<LimitHit>(), Some(&LimitHit::Memory));
        assert!(limiter.memory_growing(0, 400, None).unwrap());
        assert_eq!(limiter.peak, 1000);
    }

    #[test]
    fn thread_cpu_time_counts_work_and_not_sleep() {
        let start = thread_cpu();
        std::thread::sleep(Duration::from_millis(50));
        assert!(thread_cpu() - start < Duration::from_millis(20));
        // Spin until the thread has used 30 ms of CPU; wall time would be
        // shorter when other threads compete for the core.
        let mut x = 0u64;
        let give_up = Instant::now() + Duration::from_secs(10);
        while thread_cpu() - start < Duration::from_millis(30) && Instant::now() < give_up {
            x = std::hint::black_box(x.wrapping_add(1));
        }
        assert!(
            thread_cpu() - start >= Duration::from_millis(30),
            "spinning did not count as CPU time"
        );
    }

    #[test]
    fn a_body_over_the_cap_is_refused() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let body = || Full::new(Bytes::from(vec![0u8; 10]));
        assert_eq!(
            rt.block_on(collect(body(), 10)).ok().map(|v| v.len()),
            Some(10)
        );
        assert!(rt.block_on(collect(body(), 9)).is_err());
    }
}
