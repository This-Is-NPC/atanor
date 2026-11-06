//! Calls from a guest into Elixir. The guest's thread sends a message to the
//! process that invoked it and waits for the reply, bounded by the request's
//! deadline. Elixir answers with `host_reply/2`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Mutex, OnceLock};

use rustler::{Atom, Encoder, LocalPid, OwnedEnv};
use tokio::sync::oneshot;
use tokio::time::Instant;
use wasmtime::component::HasSelf;

use crate::guest::{LimitHit, State};
use crate::stats;
use crate::wire::Wire;

mod atoms {
    rustler::atoms! { atanor_wasm, host, ok, error }
}

wasmtime::component::bindgen!({
    path: [
        "../../wit/cell",
        "../../wit/config",
        "../../wit/worker",
        "wit",
    ],
    world: "atanor:host/host",
    imports: { default: async | trappable },
});

type Pending = Mutex<HashMap<u64, oneshot::Sender<Wire>>>;

fn pending() -> &'static Pending {
    static PENDING: OnceLock<Pending> = OnceLock::new();
    PENDING.get_or_init(Default::default)
}

/// How a host call ended.
pub enum Reply {
    Ok(Wire),
    Err { kind: String, message: String },
}

/// Where a guest's host calls go.
#[derive(Clone)]
pub struct Link {
    pub pid: LocalPid,
    pub tag: u64,
    pub deadline: Instant,
}

impl Link {
    /// Asks Elixir to run `op`. Traps with the timeout limit when the
    /// deadline passes before the reply.
    pub async fn call(&self, op: &str, args: Vec<Wire>) -> wasmtime::Result<Reply> {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let id = NEXT.fetch_add(1, Relaxed);
        let (tx, rx) = oneshot::channel();
        pending().lock().unwrap().insert(id, tx);
        stats::bump(&stats::HOST_CALLS);

        let sent = OwnedEnv::new().send_and_clear(&self.pid, |env| {
            let op = Atom::from_str(env, op).unwrap();
            (
                atoms::atanor_wasm(),
                self.tag,
                atoms::host(),
                id,
                op,
                Wire::List(args),
            )
                .encode(env)
        });
        if sent.is_err() {
            pending().lock().unwrap().remove(&id);
            return Err(wasmtime::Error::msg("the calling process is gone"));
        }

        match tokio::time::timeout_at(self.deadline, rx).await {
            Ok(Ok(wire)) => Ok(parse_reply(wire)),
            Ok(Err(_)) => Err(wasmtime::Error::msg("host reply dropped")),
            Err(_) => {
                pending().lock().unwrap().remove(&id);
                Err(wasmtime::Error::new(LimitHit::Timeout))
            }
        }
    }
}

fn parse_reply(wire: Wire) -> Reply {
    match wire {
        Wire::Tuple(mut t) if t.len() == 2 && t[0] == Wire::atom("ok") => Reply::Ok(t.remove(1)),
        Wire::Tuple(t) if t.len() == 3 => match (&t[0], &t[1], &t[2]) {
            (Wire::Atom(e), Wire::Atom(kind), Wire::Bin(m)) if e == "error" => Reply::Err {
                kind: kind.clone(),
                message: String::from_utf8_lossy(m).into_owned(),
            },
            _ => Reply::Err {
                kind: "failed".into(),
                message: "malformed host reply".into(),
            },
        },
        _ => Reply::Err {
            kind: "failed".into(),
            message: "malformed host reply".into(),
        },
    }
}

/// Delivers Elixir's answer to the guest waiting for call `id`. A late
/// reply (the guest timed out) is dropped.
pub fn reply(id: u64, wire: Wire) {
    if let Some(tx) = pending().lock().unwrap().remove(&id) {
        let _ = tx.send(wire);
    }
}

// Conversions between WIT values and wire terms.

use atanor::cell::alarms;
use atanor::cell::jobs;
use atanor::cell::sockets;
use atanor::cell::sql as cell;
use atanor::config::secrets;
use atanor::worker::call;

fn param(v: &cell::Value) -> Wire {
    match v {
        cell::Value::Null => Wire::Nil,
        cell::Value::Integer(i) => Wire::Int(*i),
        cell::Value::Real(f) => Wire::Float(*f),
        cell::Value::Text(s) => Wire::text(s),
        cell::Value::Blob(b) => Wire::Tuple(vec![Wire::atom("blob"), Wire::Bin(b.clone())]),
    }
}

fn value(w: Wire) -> cell::Value {
    match w {
        Wire::Int(i) => cell::Value::Integer(i),
        Wire::Float(f) => cell::Value::Real(f),
        Wire::Bin(b) => match String::from_utf8(b) {
            Ok(s) => cell::Value::Text(s),
            Err(e) => cell::Value::Blob(e.into_bytes()),
        },
        _ => cell::Value::Null,
    }
}

fn rows(w: Wire) -> cell::Rows {
    let Wire::Tuple(mut t) = w else {
        return cell::Rows {
            columns: vec![],
            rows: vec![],
        };
    };
    let (Some(Wire::List(rows)), Some(Wire::List(columns))) = (t.pop(), t.pop()) else {
        return cell::Rows {
            columns: vec![],
            rows: vec![],
        };
    };
    cell::Rows {
        columns: columns.into_iter().map(|c| string(c)).collect(),
        rows: rows
            .into_iter()
            .map(|r| match r {
                Wire::List(cells) => cells.into_iter().map(value).collect(),
                _ => vec![],
            })
            .collect(),
    }
}

pub fn string(w: Wire) -> String {
    match w {
        Wire::Bin(b) => String::from_utf8_lossy(&b).into_owned(),
        _ => String::new(),
    }
}

fn address(a: &cell::Address) -> [Wire; 2] {
    [Wire::text(&a.namespace), Wire::text(&a.key)]
}

fn cell_error(kind: String, message: String) -> cell::Error {
    if kind == "not_granted" {
        cell::Error::NotGranted(message)
    } else {
        cell::Error::Failed(message)
    }
}

fn headers(h: &[(String, String)]) -> Wire {
    Wire::List(
        h.iter()
            .map(|(n, v)| Wire::Tuple(vec![Wire::text(n), Wire::text(v)]))
            .collect(),
    )
}

pub fn parse_headers(w: Wire) -> Vec<(String, String)> {
    let Wire::List(items) = w else { return vec![] };
    items
        .into_iter()
        .filter_map(|h| match h {
            Wire::Tuple(mut t) if t.len() == 2 => {
                let v = t.pop()?;
                let n = t.pop()?;
                Some((string(n), string(v)))
            }
            _ => None,
        })
        .collect()
}

/// A response as Elixir returns it: `{status, headers, body}`.
pub fn parse_response(w: Wire) -> Option<(u16, Vec<(String, String)>, Vec<u8>)> {
    let Wire::Tuple(mut t) = w else { return None };
    if t.len() != 3 {
        return None;
    }
    let body = match t.pop()? {
        Wire::Bin(b) => b,
        _ => return None,
    };
    let headers = parse_headers(t.pop()?);
    let Wire::Int(status) = t.pop()? else {
        return None;
    };
    Some((status as u16, headers, body))
}

impl cell::Host for State {
    async fn partition(
        &mut self,
        c: cell::Address,
        partition_key: String,
    ) -> wasmtime::Result<Result<cell::Address, cell::Error>> {
        let [ns, key] = address(&c);
        Ok(
            match self
                .link
                .call("partition", vec![ns, key, Wire::text(partition_key)])
                .await?
            {
                Reply::Ok(Wire::Tuple(mut t)) if t.len() == 2 => {
                    let key = string(t.pop().unwrap());
                    let namespace = string(t.pop().unwrap());
                    Ok(cell::Address { namespace, key })
                }
                Reply::Ok(_) => Err(cell::Error::Failed("malformed host reply".into())),
                Reply::Err { kind, message } => Err(cell_error(kind, message)),
            },
        )
    }

    async fn query(
        &mut self,
        c: cell::Address,
        sql: String,
        params: Vec<cell::Value>,
    ) -> wasmtime::Result<Result<cell::Rows, cell::Error>> {
        self.sql("query", &c, sql, params, None).await
    }

    async fn query_bounded(
        &mut self,
        c: cell::Address,
        sql: String,
        params: Vec<cell::Value>,
        max_lag_ms: u32,
    ) -> wasmtime::Result<Result<cell::Rows, cell::Error>> {
        self.sql("query_bounded", &c, sql, params, Some(max_lag_ms))
            .await
    }

    async fn execute(
        &mut self,
        c: cell::Address,
        sql: String,
        params: Vec<cell::Value>,
    ) -> wasmtime::Result<Result<cell::Rows, cell::Error>> {
        self.sql("execute", &c, sql, params, None).await
    }

    async fn batch(
        &mut self,
        c: cell::Address,
        statements: Vec<cell::Statement>,
    ) -> wasmtime::Result<Result<Vec<cell::Rows>, cell::Error>> {
        let [ns, key] = address(&c);
        let statements = Wire::List(
            statements
                .iter()
                .map(|s| {
                    Wire::Tuple(vec![
                        Wire::text(&s.sql),
                        Wire::List(s.params.iter().map(param).collect()),
                    ])
                })
                .collect(),
        );
        Ok(
            match self.link.call("batch", vec![ns, key, statements]).await? {
                Reply::Ok(Wire::List(results)) => Ok(results.into_iter().map(rows).collect()),
                Reply::Ok(_) => Err(cell::Error::Failed("malformed host reply".into())),
                Reply::Err { kind, message } => Err(cell_error(kind, message)),
            },
        )
    }
}

impl State {
    async fn sql(
        &mut self,
        op: &str,
        c: &cell::Address,
        sql: String,
        params: Vec<cell::Value>,
        max_lag_ms: Option<u32>,
    ) -> wasmtime::Result<Result<cell::Rows, cell::Error>> {
        let [ns, key] = address(c);
        let mut args = vec![
            ns,
            key,
            Wire::text(sql),
            Wire::List(params.iter().map(param).collect()),
        ];
        args.extend(max_lag_ms.map(|ms| Wire::Int(ms.into())));
        Ok(match self.link.call(op, args).await? {
            Reply::Ok(wire) => Ok(rows(wire)),
            Reply::Err { kind, message } => Err(cell_error(kind, message)),
        })
    }
}

impl secrets::Host for State {
    async fn get(&mut self, name: String) -> wasmtime::Result<Result<String, secrets::Error>> {
        Ok(
            match self.link.call("secret", vec![Wire::text(name)]).await? {
                Reply::Ok(wire) => Ok(string(wire)),
                Reply::Err { kind, message } => Err(if kind == "not_granted" {
                    secrets::Error::NotGranted(message)
                } else {
                    secrets::Error::Missing(message)
                }),
            },
        )
    }
}

impl call::Host for State {
    async fn call(
        &mut self,
        worker: String,
        request: call::Request,
    ) -> wasmtime::Result<Result<call::Response, call::Error>> {
        let args = vec![
            Wire::text(worker),
            Wire::text(request.method),
            Wire::text(request.path),
            Wire::text(request.query),
            headers(&request.headers),
            Wire::Bin(request.body),
        ];
        Ok(match self.link.call("call", args).await? {
            Reply::Ok(wire) => match parse_response(wire) {
                Some((status, headers, body)) => Ok(call::Response {
                    status,
                    headers,
                    body,
                }),
                None => Err(call::Error::Failed("malformed host reply".into())),
            },
            Reply::Err { kind, message } => Err(if kind == "not_granted" {
                call::Error::NotGranted(message)
            } else {
                call::Error::Failed(message)
            }),
        })
    }
}

/// A reply that carries no value: `Err((not_granted, message))` otherwise.
fn unit(reply: Reply) -> Result<(), (bool, String)> {
    match reply {
        Reply::Ok(_) => Ok(()),
        Reply::Err { kind, message } => Err((kind == "not_granted", message)),
    }
}

impl alarms::Host for State {
    async fn set_alarm(
        &mut self,
        namespace: String,
        key: String,
        at_ms: i64,
        payload: Vec<u8>,
    ) -> wasmtime::Result<Result<(), alarms::Error>> {
        let args = vec![
            Wire::text(namespace),
            Wire::text(key),
            Wire::Int(at_ms),
            Wire::Bin(payload),
        ];
        let reply = self.link.call("set_alarm", args).await?;
        Ok(unit(reply).map_err(|(denied, m)| {
            if denied {
                alarms::Error::NotGranted(m)
            } else {
                alarms::Error::Failed(m)
            }
        }))
    }

    async fn cancel_alarm(
        &mut self,
        namespace: String,
        key: String,
    ) -> wasmtime::Result<Result<(), alarms::Error>> {
        let reply = self
            .link
            .call("cancel_alarm", vec![Wire::text(namespace), Wire::text(key)])
            .await?;
        Ok(unit(reply).map_err(|(denied, m)| {
            if denied {
                alarms::Error::NotGranted(m)
            } else {
                alarms::Error::Failed(m)
            }
        }))
    }
}

impl jobs::Host for State {
    async fn enqueue(
        &mut self,
        c: jobs::Address,
        job: jobs::NewJob,
    ) -> wasmtime::Result<Result<String, jobs::Error>> {
        let mut args = vec![Wire::text(&c.namespace), Wire::text(&c.key)];
        args.extend(job_args(&job));
        self.job_call("enqueue", args).await
    }

    async fn enqueue_batch(
        &mut self,
        c: jobs::Address,
        statements: Vec<jobs::Statement>,
        job: jobs::NewJob,
    ) -> wasmtime::Result<Result<String, jobs::Error>> {
        let statements = Wire::List(
            statements
                .iter()
                .map(|s| {
                    Wire::Tuple(vec![
                        Wire::text(&s.sql),
                        Wire::List(s.params.iter().map(param).collect()),
                    ])
                })
                .collect(),
        );
        let mut args = vec![Wire::text(&c.namespace), Wire::text(&c.key), statements];
        args.extend(job_args(&job));
        self.job_call("enqueue_batch", args).await
    }
}

fn job_args(job: &jobs::NewJob) -> Vec<Wire> {
    vec![
        Wire::text(&job.kind),
        Wire::Bin(job.payload.clone()),
        option_int(job.scheduled_at_ms),
        option_int(job.max_attempts.map(|n| n as i64)),
        option_text(job.unique_key.clone()),
        option_period(job.unique_period.clone()),
        option_text(job.idempotency_key.clone()),
    ]
}

fn option_int(value: Option<i64>) -> Wire {
    match value {
        Some(n) => Wire::Int(n),
        None => Wire::Nil,
    }
}

fn option_text(value: Option<String>) -> Wire {
    match value {
        Some(text) => Wire::text(&text),
        None => Wire::Nil,
    }
}

fn option_period(value: Option<jobs::UniquePeriod>) -> Wire {
    match value {
        None => Wire::Nil,
        Some(jobs::UniquePeriod::UntilDone) => Wire::atom("until_done"),
        Some(jobs::UniquePeriod::Forever) => Wire::atom("forever"),
        Some(jobs::UniquePeriod::Seconds(n)) => {
            Wire::Tuple(vec![Wire::atom("seconds"), Wire::Int(n)])
        }
    }
}

impl State {
    async fn job_call(
        &mut self,
        op: &str,
        args: Vec<Wire>,
    ) -> wasmtime::Result<Result<String, jobs::Error>> {
        Ok(match self.link.call(op, args).await? {
            Reply::Ok(wire) => Ok(string(wire)),
            Reply::Err { kind, message } => Err(if kind == "not_granted" {
                jobs::Error::NotGranted(message)
            } else {
                jobs::Error::Failed(message)
            }),
        })
    }
}

impl sockets::Host for State {
    async fn attach(
        &mut self,
        namespace: String,
        key: String,
    ) -> wasmtime::Result<Result<(), sockets::Error>> {
        let reply = self
            .link
            .call("attach", vec![Wire::text(namespace), Wire::text(key)])
            .await?;
        Ok(unit(reply).map_err(socket_error))
    }

    async fn send_to_cell(
        &mut self,
        namespace: String,
        key: String,
        message: Vec<u8>,
    ) -> wasmtime::Result<Result<(), sockets::Error>> {
        let args = vec![Wire::text(namespace), Wire::text(key), Wire::Bin(message)];
        let reply = self.link.call("send_to_cell", args).await?;
        Ok(unit(reply).map_err(socket_error))
    }

    async fn join_channel(
        &mut self,
        namespace: String,
        key: String,
        id: Option<String>,
    ) -> wasmtime::Result<Result<(), sockets::Error>> {
        let id = id.map_or(Wire::Nil, Wire::text);
        let reply = self
            .link
            .call(
                "join_channel",
                vec![Wire::text(namespace), Wire::text(key), id],
            )
            .await?;
        Ok(unit(reply).map_err(socket_error))
    }

    async fn leave_channel(
        &mut self,
        namespace: String,
        key: String,
    ) -> wasmtime::Result<Result<(), sockets::Error>> {
        let reply = self
            .link
            .call(
                "leave_channel",
                vec![Wire::text(namespace), Wire::text(key)],
            )
            .await?;
        Ok(unit(reply).map_err(socket_error))
    }

    async fn publish(
        &mut self,
        namespace: String,
        key: String,
        message: sockets::Message,
    ) -> wasmtime::Result<Result<(), sockets::Error>> {
        let frame = match message {
            sockets::Message::Text(t) => Wire::Tuple(vec![Wire::atom("text"), Wire::text(t)]),
            sockets::Message::Binary(b) => Wire::Tuple(vec![Wire::atom("binary"), Wire::Bin(b)]),
        };
        let reply = self
            .link
            .call(
                "publish",
                vec![Wire::text(namespace), Wire::text(key), frame],
            )
            .await?;
        Ok(unit(reply).map_err(socket_error))
    }

    async fn channel_members(
        &mut self,
        namespace: String,
        key: String,
    ) -> wasmtime::Result<Result<sockets::Members, sockets::Error>> {
        let reply = self
            .link
            .call(
                "channel_members",
                vec![Wire::text(namespace), Wire::text(key)],
            )
            .await?;
        Ok(match reply {
            Reply::Ok(Wire::Tuple(mut t)) if t.len() == 2 => {
                let ids = match t.pop() {
                    Some(Wire::List(ids)) => ids.into_iter().map(string).collect(),
                    _ => vec![],
                };
                let count = match t.pop() {
                    Some(Wire::Int(n)) => n as u32,
                    _ => 0,
                };
                Ok(sockets::Members { count, ids })
            }
            Reply::Ok(_) => Err(sockets::Error::Failed("bad reply".into())),
            Reply::Err { kind, message } => Err(socket_error((kind == "not_granted", message))),
        })
    }
}

fn socket_error((denied, message): (bool, String)) -> sockets::Error {
    if denied {
        sockets::Error::NotGranted(message)
    } else {
        sockets::Error::Failed(message)
    }
}

/// Links the atanor interface the guest's grants allow.
pub fn link_cell(l: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    cell::add_to_linker::<State, HasSelf<State>>(l, |s| s)
}

pub fn link_secrets(l: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    secrets::add_to_linker::<State, HasSelf<State>>(l, |s| s)
}

pub fn link_call(l: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    call::add_to_linker::<State, HasSelf<State>>(l, |s| s)
}

pub fn link_alarms(l: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    alarms::add_to_linker::<State, HasSelf<State>>(l, |s| s)
}

pub fn link_jobs(l: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    jobs::add_to_linker::<State, HasSelf<State>>(l, |s| s)
}

pub fn link_sockets(l: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    sockets::add_to_linker::<State, HasSelf<State>>(l, |s| s)
}
