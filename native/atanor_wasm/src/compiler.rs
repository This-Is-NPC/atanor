//! The pool that compiles components, apart from the BEAM's dirty schedulers.
//!
//! A compile cannot be interrupted, so a caller that gave up would leave a
//! dirty scheduler busy until it ends. A NIF queues the compile here and
//! returns at once, and the result arrives as a message. A full queue refuses
//! the compile, so repeated deployments cannot pile up work.

use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, OnceLock};

use rustler::{Encoder, LocalPid, NifMap, OwnedEnv, ResourceArc};

use crate::component::{self, Compiled, Source};
use crate::engine;

#[derive(NifMap, Clone, PartialEq, Debug)]
pub struct Settings {
    pub threads: usize,
    pub queue: usize,
}

pub struct Request {
    pub bytes: Vec<u8>,
    pub dir: Option<String>,
    pub key: Option<String>,
    pub pid: LocalPid,
    pub tag: String,
}

/// A bounded queue served by `threads` workers that run `work` on each item.
pub struct Pool<T> {
    tx: SyncSender<T>,
}

impl<T: Send + 'static> Pool<T> {
    pub fn start(settings: &Settings, work: fn(T)) -> Result<Self, String> {
        let (tx, rx) = sync_channel::<T>(settings.queue);
        let rx: Arc<Mutex<Receiver<T>>> = Arc::new(Mutex::new(rx));
        for i in 0..settings.threads {
            let rx = rx.clone();
            std::thread::Builder::new()
                .name(format!("atanor-compile-{i}"))
                .spawn(move || loop {
                    let item = match rx.lock().map(|rx| rx.recv()) {
                        Ok(Ok(item)) => item,
                        _ => return,
                    };
                    // A panic must not shrink the pool.
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| work(item)));
                })
                .map_err(|e| e.to_string())?;
        }
        Ok(Pool { tx })
    }

    /// Queues `item`; a full queue gives it back.
    pub fn submit(&self, item: T) -> Result<(), T> {
        match self.tx.try_send(item) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(item)) | Err(TrySendError::Disconnected(item)) => Err(item),
        }
    }
}

static POOL: OnceLock<(Settings, Pool<Request>)> = OnceLock::new();

/// Starts the pool once per VM; configuring again with the same settings is a no-op.
pub fn configure(settings: Settings) -> Result<(), String> {
    if settings.threads == 0 || settings.queue == 0 {
        return Err("compile_threads and compile_queue must be positive".into());
    }
    if let Some((running, _)) = POOL.get() {
        return if *running == settings {
            Ok(())
        } else {
            Err("already configured differently".into())
        };
    }
    let pool = Pool::start(&settings, run)?;
    let _ = POOL.set((settings, pool));
    Ok(())
}

/// Queues a compile; a full queue refuses it.
pub fn submit(request: Request) -> Result<(), ()> {
    let (_, pool) = POOL.get().ok_or(())?;
    pool.submit(request).map_err(|_| ())
}

fn run(request: Request) {
    let Request {
        bytes,
        dir,
        key,
        pid,
        tag,
    } = request;
    let result = match engine::runtime() {
        None => Err("not configured".to_string()),
        Some(runtime) => {
            let cache = dir
                .as_deref()
                .zip(key.as_deref())
                .map(|(d, k)| (std::path::Path::new(d), k));
            component::compile(&runtime.engine, &bytes, cache)
        }
    };
    let result: Result<(ResourceArc<Compiled>, rustler::Atom), String> =
        result.map(|(compiled, source)| {
            let source = match source {
                Source::Compiled => crate::atoms::compiled(),
                Source::Disk => crate::atoms::disk(),
                Source::Recompiled => crate::atoms::recompiled(),
            };
            (ResourceArc::new(compiled), source)
        });
    let _ = OwnedEnv::new().send_and_clear(&pid, |env| {
        (crate::atoms::atanor_compile(), tag, result).encode(env)
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc::channel;

    static DONE: AtomicUsize = AtomicUsize::new(0);

    fn block((gate, started): (Arc<Mutex<Receiver<()>>>, std::sync::mpsc::Sender<()>)) {
        let _ = started.send(());
        let _ = gate.lock().unwrap().recv();
        DONE.fetch_add(1, Ordering::SeqCst);
    }

    /// With `threads` busy workers and `queue` waiting items the pool takes
    /// exactly `threads + queue` items and refuses the rest.
    #[test]
    fn admits_at_most_threads_plus_queue() {
        for (threads, queue) in [(1, 1), (2, 3), (3, 1)] {
            let pool = Pool::start(&Settings { threads, queue }, block).unwrap();
            let (open, gate) = channel::<()>();
            let gate = Arc::new(Mutex::new(gate));
            let (started_tx, started) = channel();
            let item = || (gate.clone(), started_tx.clone());
            // Occupy every worker, one at a time, so the queue is empty when counted.
            for _ in 0..threads {
                assert!(pool.submit(item()).is_ok());
                started.recv().unwrap();
            }
            let accepted = (0..threads + queue + 5)
                .filter(|_| pool.submit(item()).is_ok())
                .count();
            assert_eq!(accepted, queue, "threads={threads} queue={queue}");
            for _ in 0..threads + queue {
                open.send(()).unwrap();
            }
        }
    }
}
