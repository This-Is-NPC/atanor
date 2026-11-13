//! Wasmtime for Atanor (design section 14): components compiled and cached,
//! guests run on a thread pool this crate owns, with limits and counters.

mod admission;
mod compiler;
mod component;
mod engine;
mod guest;
mod handlers;
mod host;
mod stats;
mod wire;

use std::time::Instant;

use rustler::{Atom, Binary, Encoder, Env, LocalPid, NifResult, ResourceArc, Term};

use component::{Compiled, Grants, PrepareError, Prepared};
use guest::{Call, Job, Limits, Ticket};
use wire::Wire;

#[global_allocator]
static ALLOC: stats::Counted = stats::Counted;

mod atoms {
    rustler::atoms! {
        ok, error, overloaded, not_configured, compiled, disk, recompiled,
        atanor_compile, not_granted, unsupported_import, missing_export, prepare_failed,
    }
}

#[rustler::nif]
fn configure(env: Env, settings: engine::Settings) -> Term {
    match engine::configure(settings) {
        Ok(()) => atoms::ok().encode(env),
        Err(message) => (atoms::error(), message).encode(env),
    }
}

#[rustler::nif]
fn configure_compile(env: Env, settings: compiler::Settings) -> Term {
    match compiler::configure(settings) {
        Ok(()) => atoms::ok().encode(env),
        Err(message) => (atoms::error(), message).encode(env),
    }
}

/// Queues the compile of `bytes` (using the disk cache in `dir` under `key`
/// when given) and returns at once. The result arrives at `pid` as
/// `{:atanor_compile, tag, {:ok, {compiled, source}} | {:error, message}}`;
/// a full queue answers `:overloaded` instead.
#[rustler::nif]
fn compile(
    bytes: Binary,
    dir: Option<String>,
    key: Option<String>,
    pid: LocalPid,
    tag: String,
) -> Atom {
    let request = compiler::Request {
        bytes: bytes.as_slice().to_vec(),
        dir,
        key,
        pid,
        tag,
    };
    if compiler::submit(request).is_ok() {
        atoms::ok()
    } else {
        atoms::overloaded()
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn prepare(
    component: ResourceArc<Compiled>,
    grants: Grants,
) -> Result<(ResourceArc<Prepared>, bool, bool), (Atom, String)> {
    component::prepare(&component, grants)
        .map(|p| {
            let (sockets, local) = (p.socket.is_some(), p.local.is_some());
            (ResourceArc::new(p), sockets, local)
        })
        .map_err(|e| match e {
            PrepareError::NotGranted(name) => (atoms::not_granted(), name),
            PrepareError::Unsupported(name) => (atoms::unsupported_import(), name),
            PrepareError::MissingExport(name) => (atoms::missing_export(), name),
            PrepareError::Other(message) => (atoms::prepare_failed(), message),
        })
}

/// Queues a call (see `guest::Call::parse` for its shape) and returns
/// `{:ok, ticket}`, or `:overloaded` when it is refused. The result arrives
/// at `pid` as `{:atanor_wasm, tag, :done, result, stderr, timing}`; host
/// calls as `{:atanor_wasm, tag, :host, id, op, args}`. `withdraw/1` takes the
/// call back while it is queued.
#[rustler::nif]
fn invoke<'a>(
    env: Env<'a>,
    prepared: ResourceArc<Prepared>,
    call: Wire,
    limits: Limits,
    pid: LocalPid,
    tag: u64,
) -> NifResult<Term<'a>> {
    let call = Call::parse(call).ok_or(rustler::Error::BadArg)?;
    let ticket = ResourceArc::new(Ticket::new());
    let job = Job {
        pre: prepared,
        call,
        limits,
        pid,
        tag,
        queued_at: Instant::now(),
        ticket: ticket.clone(),
        slot: None,
    };
    Ok(if engine::submit(job).is_ok() {
        (atoms::ok(), ticket).encode(env)
    } else {
        atoms::overloaded().encode(env)
    })
}

/// Takes a call back that no thread has started: true, and it never runs and
/// sends nothing; false when it started (or ended), and its result still comes.
#[rustler::nif]
fn withdraw(ticket: ResourceArc<Ticket>) -> bool {
    ticket.withdraw()
}

/// Answers a host call. Small replies decode on a normal scheduler.
#[rustler::nif]
fn host_reply_small(id: u64, reply: Wire) -> Atom {
    answer(id, reply)
}

/// The same for a large reply, whose copy would hold a normal scheduler for
/// milliseconds. Elixir picks the entry point (`Native.host_reply/2`).
#[rustler::nif(schedule = "DirtyCpu")]
fn host_reply_large(id: u64, reply: Wire) -> Atom {
    answer(id, reply)
}

fn answer(id: u64, reply: Wire) -> Atom {
    host::reply(id, reply);
    atoms::ok()
}

rustler::init!("Elixir.Atanor.Wasm.Native");
