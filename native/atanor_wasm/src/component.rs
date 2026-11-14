//! Compiling components, the disk cache of compiled code, and preparing a
//! component with the imports its manifest grants.

use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::Write;
use std::panic::AssertUnwindSafe;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::sync::Arc;

use rustler::{NifMap, Resource};
use sha2::{Digest, Sha256};
use wasmtime::component::{types::ComponentItem, Component, Linker};
use wasmtime::Engine;
use wasmtime_wasi_http::p2::bindings::ProxyPre;

use crate::admission::Gate;
use crate::engine;
use crate::guest::State;
use crate::handlers::{alarm, job, local, socket};
use crate::host;
use crate::stats;

/// A compiled component.
pub struct Compiled {
    component: AssertUnwindSafe<Component>,
}

#[rustler::resource_impl]
impl Resource for Compiled {}

/// A component linked with its grants, ready to instantiate per call. The
/// handlers are present when the component exports them.
pub struct Prepared {
    pub pre: AssertUnwindSafe<ProxyPre<State>>,
    pub alarm: Option<AssertUnwindSafe<alarm::AlarmGuestPre<State>>>,
    pub socket: Option<AssertUnwindSafe<socket::SocketGuestPre<State>>>,
    pub local: Option<AssertUnwindSafe<local::LocalGuestPre<State>>>,
    pub job: Option<AssertUnwindSafe<job::JobGuestPre<State>>>,
    /// The busy calls of this component (`worker_calls`).
    pub calls: Arc<Gate>,
    /// Jobs of this component in the queue, bounded by `worker_queue`.
    pub queued: AtomicUsize,
}

#[rustler::resource_impl]
impl Resource for Prepared {}

impl Drop for Compiled {
    fn drop(&mut self) {
        stats::LIVE_COMPONENTS.fetch_sub(1, Relaxed);
    }
}

#[derive(NifMap, Clone, Copy, Default, Debug)]
pub struct Grants {
    pub sql: bool,
    pub secrets: bool,
    pub call: bool,
    pub http: bool,
    pub alarms: bool,
    pub sockets: bool,
    pub jobs: bool,
}

const ALARM_HANDLER: &str = "atanor:worker/alarm-handler@0.1.0";
const SOCKET_HANDLER: &str = "atanor:worker/socket-handler@0.1.0";
const SOCKET_LOCAL: &str = "atanor:worker/socket-local@0.1.0";
const JOB_HANDLER: &str = "atanor:worker/job-handler@0.1.0";

#[derive(Debug, PartialEq)]
pub enum Source {
    Compiled,
    Disk,
    /// A cache file existed but could not be used.
    Recompiled,
}

#[derive(Debug)]
pub enum PrepareError {
    /// The component imports an interface the manifest does not grant.
    NotGranted(String),
    /// The component imports something the host does not provide.
    Unsupported(String),
    /// The manifest grants a binding whose handler the component does not export.
    MissingExport(String),
    Other(String),
}

fn tracked(component: Component) -> Compiled {
    stats::LIVE_COMPONENTS.fetch_add(1, Relaxed);
    Compiled {
        component: AssertUnwindSafe(component),
    }
}

/// Names the engine's version and settings in cache file names.
fn fingerprint(engine: &Engine) -> String {
    let mut hasher = DefaultHasher::new();
    engine.precompile_compatibility_hash().hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

/// Compiles `bytes`, or loads the compiled code from `<dir>/<key>-<engine>.cwasm`
/// and writes it there after a compile. Wasmtime checks that a file matches
/// the engine's version and settings; the digest in front of the payload
/// catches truncation and bit rot, because deserializing damaged code is not
/// safe. Any failure to use the file means a recompile.
pub fn compile(
    engine: &Engine,
    bytes: &[u8],
    cache: Option<(&Path, &str)>,
) -> Result<(Compiled, Source), String> {
    let path = cache.map(|(dir, key)| dir.join(format!("{key}-{}.cwasm", fingerprint(engine))));
    let mut source = Source::Compiled;

    if let Some(path) = &path {
        if let Ok(file) = std::fs::read(path) {
            match load(engine, &file) {
                Some(component) => {
                    stats::bump(&stats::DISK_HITS);
                    return Ok((tracked(component), Source::Disk));
                }
                None => source = Source::Recompiled,
            }
        }
        stats::bump(&stats::DISK_MISSES);
    }

    let component = Component::new(engine, bytes).map_err(|e| format!("{e:#}"))?;
    stats::bump(&stats::COMPILED);
    if let Some(path) = &path {
        // A cache that cannot be written only costs the next start a compile.
        if let Ok(serialized) = component.serialize() {
            let _ = store(path, &serialized);
        }
    }
    Ok((tracked(component), source))
}

fn load(engine: &Engine, file: &[u8]) -> Option<Component> {
    let (digest, payload) = file.split_at_checked(32)?;
    if Sha256::digest(payload).as_slice() != digest {
        return None;
    }
    // SAFETY: the payload is the output of `Component::serialize` that this
    // process or an earlier one wrote to the node's own data directory, and
    // the digest shows it is unchanged.
    unsafe { Component::deserialize(engine, payload).ok() }
}

fn store(path: &Path, serialized: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    let mut file = std::fs::File::create(&tmp)?;
    file.write_all(&Sha256::digest(serialized))?;
    file.write_all(serialized)?;
    file.sync_all()?;
    std::fs::rename(tmp, path)
}

/// Whether the host provides `name` under `grants`.
fn granted(name: &str, grants: Grants) -> Result<(), PrepareError> {
    let denied = |g: bool| {
        if g {
            Ok(())
        } else {
            Err(PrepareError::NotGranted(name.to_string()))
        }
    };
    if name.starts_with("atanor:cell/sql@0.1.0") {
        denied(grants.sql)
    } else if name == "atanor:cell/alarms@0.1.0" {
        denied(grants.alarms)
    } else if name == "atanor:cell/sockets@0.1.0" {
        denied(grants.sockets)
    } else if name == "atanor:cell/jobs@0.1.0" {
        denied(grants.jobs)
    } else if name == "atanor:config/secrets@0.1.0" {
        denied(grants.secrets)
    } else if name == "atanor:worker/call@0.1.0" {
        denied(grants.call)
    } else if name.starts_with("wasi:http/outgoing-handler@0.2") {
        denied(grants.http)
    } else if name.starts_with("wasi:") {
        // Provided by Wasmtime, with no authority behind them.
        Ok(())
    } else {
        Err(PrepareError::Unsupported(name.to_string()))
    }
}

/// Links the granted imports and pre-instantiates. Names the first import
/// that is not granted, so a manifest error is clear, and the handler a
/// granted binding needs but the component does not export.
pub fn prepare(compiled: &Compiled, grants: Grants) -> Result<Prepared, PrepareError> {
    let engine = &engine::runtime()
        .ok_or_else(|| PrepareError::Other("not configured".into()))?
        .engine;
    let component_type = compiled.component.component_type();
    for (name, item) in component_type.imports(engine) {
        if matches!(item.ty, ComponentItem::ComponentInstance(_)) {
            granted(name, grants)?;
        }
    }
    let exports = |wanted: &str| {
        component_type
            .exports(engine)
            .any(|(name, _)| name == wanted)
    };
    let (alarm_handler, socket_handler, job_handler) = (
        exports(ALARM_HANDLER),
        exports(SOCKET_HANDLER),
        exports(JOB_HANDLER),
    );
    let socket_local = exports(SOCKET_LOCAL);
    for (needed, present, name) in [
        (grants.alarms, alarm_handler, ALARM_HANDLER),
        (grants.sockets, socket_handler, SOCKET_HANDLER),
        (grants.jobs, job_handler, JOB_HANDLER),
    ] {
        if needed && !present {
            return Err(PrepareError::MissingExport(name.to_string()));
        }
    }

    let other = |e: wasmtime::Error| PrepareError::Other(format!("{e:#}"));
    let mut linker = Linker::<State>::new(engine);
    wasmtime_wasi::p2::add_to_linker_async(&mut linker).map_err(other)?;
    wasmtime_wasi_http::p2::bindings::http::types::add_to_linker::<
        State,
        wasmtime_wasi_http::WasiHttp,
    >(
        &mut linker,
        &Default::default(),
        <State as wasmtime_wasi_http::WasiHttpView>::http,
    )
    .map_err(other)?;
    if grants.http {
        wasmtime_wasi_http::p2::bindings::http::outgoing_handler::add_to_linker::<
            State,
            wasmtime_wasi_http::WasiHttp,
        >(
            &mut linker,
            <State as wasmtime_wasi_http::WasiHttpView>::http,
        )
        .map_err(other)?;
    }
    if grants.sql {
        host::link_cell(&mut linker).map_err(other)?;
    }
    if grants.secrets {
        host::link_secrets(&mut linker).map_err(other)?;
    }
    if grants.call {
        host::link_call(&mut linker).map_err(other)?;
    }
    if grants.alarms {
        host::link_alarms(&mut linker).map_err(other)?;
    }
    if grants.sockets {
        host::link_sockets(&mut linker).map_err(other)?;
    }
    if grants.jobs {
        host::link_jobs(&mut linker).map_err(other)?;
    }

    let instance_pre = linker.instantiate_pre(&compiled.component).map_err(other)?;
    let alarm = alarm_handler
        .then(|| alarm::AlarmGuestPre::new(instance_pre.clone()).map(AssertUnwindSafe))
        .transpose()
        .map_err(other)?;
    let socket = socket_handler
        .then(|| socket::SocketGuestPre::new(instance_pre.clone()).map(AssertUnwindSafe))
        .transpose()
        .map_err(other)?;
    let local = socket_local
        .then(|| local::LocalGuestPre::new(instance_pre.clone()).map(AssertUnwindSafe))
        .transpose()
        .map_err(other)?;
    let job = job_handler
        .then(|| job::JobGuestPre::new(instance_pre.clone()).map(AssertUnwindSafe))
        .transpose()
        .map_err(other)?;
    let pre = ProxyPre::new(instance_pre).map_err(other)?;
    Ok(Prepared {
        pre: AssertUnwindSafe(pre),
        alarm,
        socket,
        local,
        job,
        calls: engine::worker_gate(),
        queued: AtomicUsize::new(0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine;

    fn fixture(name: &str) -> Vec<u8> {
        let path = format!(
            "{}/../../test/fixtures/wasm/{name}.wasm",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::read(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
    }

    fn engine() -> &'static Engine {
        engine::configure(engine::test_settings()).unwrap();
        &engine::runtime().unwrap().engine
    }

    #[test]
    fn serialized_code_is_reused_from_disk() {
        let dir = tempfile::tempdir().unwrap();
        let bytes = fixture("hello");
        let cache = Some((dir.path(), "abc"));

        let (_, first) = compile(engine(), &bytes, cache).unwrap();
        let (_, second) = compile(engine(), &bytes, cache).unwrap();
        assert_eq!((first, second), (Source::Compiled, Source::Disk));
    }

    #[test]
    fn damaged_cache_files_are_recompiled_and_rewritten() {
        let dir = tempfile::tempdir().unwrap();
        let bytes = fixture("hello");
        let cache = Some((dir.path(), "abc"));
        compile(engine(), &bytes, cache).unwrap();
        let file = std::fs::read_dir(dir.path())
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let original = std::fs::read(&file).unwrap();

        let mut flipped = original.clone();
        let middle = flipped.len() / 2;
        flipped[middle] ^= 0xff;
        let truncated = original[..original.len() / 2].to_vec();
        for damaged in [flipped, truncated, vec![1, 2, 3], vec![]] {
            std::fs::write(&file, damaged).unwrap();
            let (_, source) = compile(engine(), &bytes, cache).unwrap();
            assert_eq!(source, Source::Recompiled);
            let (_, source) = compile(engine(), &bytes, cache).unwrap();
            assert_eq!(source, Source::Disk, "the recompile rewrote the file");
        }
    }

    #[test]
    fn a_file_for_another_key_is_not_used() {
        let dir = tempfile::tempdir().unwrap();
        let bytes = fixture("hello");
        compile(engine(), &bytes, Some((dir.path(), "one"))).unwrap();
        let (_, source) = compile(engine(), &bytes, Some((dir.path(), "two"))).unwrap();
        assert_eq!(source, Source::Compiled);
    }

    #[test]
    fn invalid_bytes_are_an_error() {
        assert!(compile(engine(), b"not a component", None).is_err());
    }

    #[test]
    fn imports_need_their_grants() {
        let none = Grants::default();
        let all = Grants {
            sql: true,
            secrets: true,
            call: true,
            http: true,
            alarms: true,
            sockets: true,
            jobs: false,
        };
        let cases = [
            ("hello", none, true),
            ("cell", none, false),
            ("cell", Grants { sql: true, ..none }, true),
            ("secret", Grants { sql: true, ..none }, false),
            (
                "secret",
                Grants {
                    secrets: true,
                    ..none
                },
                true,
            ),
            ("caller", Grants { call: true, ..none }, true),
            ("outbound", none, false),
            ("outbound", Grants { http: true, ..none }, true),
            (
                "sneaky",
                Grants {
                    sql: true,
                    secrets: true,
                    ..none
                },
                false,
            ),
            ("sneaky", all, true),
            ("alarm", none, false),
            ("alarm", Grants { sql: true, ..none }, false),
            (
                "alarm",
                Grants {
                    sql: true,
                    alarms: true,
                    ..none
                },
                true,
            ),
            ("socket", Grants { sql: true, ..none }, false),
            (
                "socket",
                Grants {
                    sql: true,
                    sockets: true,
                    ..none
                },
                true,
            ),
            (
                "sneaky",
                Grants {
                    alarms: true,
                    ..all
                },
                true,
            ),
            ("job", none, false),
            ("job", Grants { sql: true, ..none }, false),
            (
                "job",
                Grants {
                    sql: true,
                    jobs: true,
                    ..none
                },
                true,
            ),
        ];
        for (guest, grants, ok) in cases {
            let (compiled, _) = compile(engine(), &fixture(guest), None).unwrap();
            let result = prepare(&compiled, grants);
            assert_eq!(
                result.is_ok(),
                ok,
                "{guest} with {grants:?}: {:?}",
                result.err()
            );
        }
    }

    #[test]
    fn the_refusal_names_the_import() {
        let (compiled, _) = compile(engine(), &fixture("cell"), None).unwrap();
        match prepare(&compiled, Grants::default()) {
            Err(PrepareError::NotGranted(name)) => assert_eq!(name, "atanor:cell/sql@0.1.0"),
            other => panic!("{:?}", other.err()),
        }
    }

    #[test]
    fn granted_jobs_need_their_handler() {
        let (compiled, _) = compile(engine(), &fixture("cell"), None).unwrap();
        let sql = Grants {
            sql: true,
            ..Grants::default()
        };
        match prepare(&compiled, Grants { jobs: true, ..sql }) {
            Err(PrepareError::MissingExport(name)) => {
                assert_eq!(name, "atanor:worker/job-handler@0.1.0")
            }
            other => panic!("{:?}", other.err()),
        }
    }

    #[test]
    fn granted_alarms_and_sockets_need_their_handlers() {
        let (compiled, _) = compile(engine(), &fixture("cell"), None).unwrap();
        let sql = Grants {
            sql: true,
            ..Grants::default()
        };
        match prepare(
            &compiled,
            Grants {
                alarms: true,
                ..sql
            },
        ) {
            Err(PrepareError::MissingExport(name)) => {
                assert_eq!(name, "atanor:worker/alarm-handler@0.1.0")
            }
            other => panic!("{:?}", other.err()),
        }
        match prepare(
            &compiled,
            Grants {
                sockets: true,
                ..sql
            },
        ) {
            Err(PrepareError::MissingExport(name)) => {
                assert_eq!(name, "atanor:worker/socket-handler@0.1.0")
            }
            other => panic!("{:?}", other.err()),
        }
    }

    #[test]
    fn exported_handlers_are_found() {
        let sql = Grants {
            sql: true,
            ..Grants::default()
        };
        let cases = [
            ("hello", Grants::default(), false, false, false),
            (
                "alarm",
                Grants {
                    alarms: true,
                    ..sql
                },
                true,
                false,
                false,
            ),
            (
                "socket",
                Grants {
                    sockets: true,
                    ..sql
                },
                false,
                true,
                false,
            ),
            (
                "channel",
                Grants {
                    sockets: true,
                    ..sql
                },
                false,
                true,
                true,
            ),
            ("job", Grants { jobs: true, ..sql }, false, false, false),
        ];
        for (guest, grants, alarm, socket, local) in cases {
            let (compiled, _) = compile(engine(), &fixture(guest), None).unwrap();
            let prepared = prepare(&compiled, grants).unwrap();
            let found = (
                prepared.alarm.is_some(),
                prepared.socket.is_some(),
                prepared.local.is_some(),
            );
            assert_eq!(found, (alarm, socket, local), "{guest}");
        }
    }

    #[test]
    fn a_component_without_the_handler_is_refused() {
        let empty = wat::parse_str("(component)").unwrap();
        let (compiled, _) = compile(engine(), &empty, None).unwrap();
        assert!(matches!(
            prepare(&compiled, Grants::default()),
            Err(PrepareError::Other(_))
        ));
    }
}
