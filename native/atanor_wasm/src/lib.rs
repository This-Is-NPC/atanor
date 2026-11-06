//! Wasmtime for Atanor (design section 14): components compiled and cached,
//! guests run on a thread pool this crate owns, with limits and counters.

mod component;
mod engine;
mod guest;
mod handlers;
mod host;
mod stats;
mod wire;

use std::path::Path;
use std::time::Instant;

use rustler::{Atom, Binary, Encoder, Env, LocalPid, NifResult, ResourceArc, Term};

use component::{Compiled, Grants, PrepareError, Prepared, Source};
use guest::{Call, Job, Limits};
use wire::Wire;

#[global_allocator]
static ALLOC: stats::Counted = stats::Counted;

mod atoms {
    rustler::atoms! {
        ok, error, overloaded, not_configured, compiled, disk, recompiled,
        not_granted, unsupported_import, missing_export, prepare_failed,
    }
}

#[rustler::nif]
fn configure(env: Env, settings: engine::Settings) -> Term {
    match engine::configure(settings) {
        Ok(()) => atoms::ok().encode(env),
        Err(message) => (atoms::error(), message).encode(env),
    }
}

/// Compiles `bytes`, using the disk cache in `dir` under `key` when given.
#[rustler::nif(schedule = "DirtyCpu")]
fn compile(
    bytes: Binary,
    dir: Option<String>,
    key: Option<String>,
) -> Result<(ResourceArc<Compiled>, Atom), String> {
    let runtime = engine::runtime().ok_or("not configured")?;
    let cache = dir
        .as_deref()
        .zip(key.as_deref())
        .map(|(d, k)| (Path::new(d), k));
    let (compiled, source) = component::compile(&runtime.engine, bytes.as_slice(), cache)?;
    let source = match source {
        Source::Compiled => atoms::compiled(),
        Source::Disk => atoms::disk(),
        Source::Recompiled => atoms::recompiled(),
    };
    Ok((ResourceArc::new(compiled), source))
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

/// Queues a call (see `guest::Call::parse` for its shape). The result arrives
/// at `pid` as `{:atanor_wasm, tag, :done, result, stderr, timing}`; host
/// calls as `{:atanor_wasm, tag, :host, id, op, args}`.
#[rustler::nif]
fn invoke(
    prepared: ResourceArc<Prepared>,
    call: Wire,
    limits: Limits,
    pid: LocalPid,
    tag: u64,
) -> NifResult<Atom> {
    let call = Call::parse(call).ok_or(rustler::Error::BadArg)?;
    let job = Job {
        pre: prepared,
        call,
        limits,
        pid,
        tag,
        queued_at: Instant::now(),
    };
    Ok(if engine::submit(job).is_ok() {
        atoms::ok()
    } else {
        atoms::overloaded()
    })
}

#[rustler::nif]
fn host_reply(id: u64, reply: Wire) -> Atom {
    host::reply(id, reply);
    atoms::ok()
}

rustler::init!("Elixir.Atanor.Wasm.Native");
