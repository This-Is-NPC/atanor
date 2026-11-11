//! The shared Wasmtime engine, the thread pool that runs guests and the
//! epoch ticker.
//!
//! Guests run on threads this crate owns, never on BEAM schedulers. A thread
//! runs one guest at a time, so a runaway guest costs one pool slot until its
//! limit stops it. The ticker is its own thread, so no guest can delay it.

use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::Semaphore;

use rustler::NifMap;
use wasmtime::{Config, Engine, InstanceAllocationStrategy, OptLevel, PoolingAllocationConfig};

use crate::admission::{Gate, Running};
use crate::guest::{self, Job};
use crate::stats;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Cpu {
    /// CPU time of the pool thread, checked at every epoch tick.
    Epoch,
    /// Wasmtime fuel, consumed by every instruction.
    Fuel,
}

#[derive(NifMap, Clone)]
pub struct Settings {
    /// Guests that run at once; a waiting guest does not count.
    pub threads: usize,
    /// Pool threads: calls in flight, running or waiting.
    pub max_calls: usize,
    /// Calls a worker's guests make to other workers, in flight at once.
    pub max_nested_calls: usize,
    /// Calls of one worker in flight at once, queued included.
    pub worker_calls: usize,
    pub queue: usize,
    pub tick_ms: u64,
    pub cpu: String,
    /// Reuse pre-mapped slots for instances instead of mapping memory for every call.
    pub pooling: bool,
    /// Largest linear memory a guest may have, the ceiling of `memory_bytes`.
    pub max_memory_bytes: u64,
    pub table_elements: u64,
}

/// What one store may hold at most; `guest::Limiter` enforces the same numbers.
pub const INSTANCES: u32 = 8;
pub const TABLES: u32 = 16;
pub const MEMORIES: u32 = 8;

pub struct Runtime {
    pub engine: Engine,
    pub cpu: Cpu,
    settings: Settings,
    tx: SyncSender<Job>,
    permits: Arc<Semaphore>,
    nested: Arc<Gate>,
}

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> Option<&'static Runtime> {
    RUNTIME.get()
}

/// A call holds one store from its start to its end, waiting or not, so the pool has a slot
/// for each call that may be in flight: the pool threads and the nested calls.
fn pool(settings: &Settings) -> PoolingAllocationConfig {
    let threads = (settings.max_calls + settings.max_nested_calls) as u32;
    let mut pool = PoolingAllocationConfig::new();
    pool.total_component_instances(threads)
        .total_core_instances(threads * INSTANCES)
        .total_memories(threads * MEMORIES)
        .total_tables(threads * TABLES)
        .total_stacks(threads)
        .max_core_instances_per_component(INSTANCES)
        .max_memories_per_component(MEMORIES)
        .max_tables_per_component(TABLES)
        .max_memory_size(settings.max_memory_bytes.min(1 << 32) as usize)
        .table_elements(settings.table_elements as usize);
    pool
}

fn engine(cpu: Cpu, settings: &Settings) -> Result<Engine, String> {
    let mut config = Config::new();
    config
        .wasm_component_model(true)
        .epoch_interruption(true)
        .consume_fuel(cpu == Cpu::Fuel)
        .wasm_backtrace_max_frames(None)
        .cranelift_opt_level(OptLevel::Speed);
    if settings.pooling {
        config.allocation_strategy(InstanceAllocationStrategy::Pooling(pool(settings)));
    }
    Engine::new(&config).map_err(|e| {
        if settings.pooling {
            format!(
                "{e}; the pooling allocator reserves address space for {} calls: lower max_calls and max_nested_calls, or set pooling: false",
                settings.max_calls + settings.max_nested_calls
            )
        } else {
            e.to_string()
        }
    })
}

/// Starts the engine, the pool and the ticker once per VM. Configuring again
/// with the same settings is a no-op.
pub fn configure(settings: Settings) -> Result<(), String> {
    let cpu = match settings.cpu.as_str() {
        "epoch" => Cpu::Epoch,
        "fuel" => Cpu::Fuel,
        other => return Err(format!("unknown cpu mode {other:?}")),
    };
    if settings.threads == 0
        || settings.max_calls < settings.threads
        || settings.max_nested_calls == 0
        || settings.worker_calls == 0
        || settings.queue == 0
        || settings.tick_ms == 0
        || settings.max_memory_bytes == 0
        || settings.table_elements == 0
    {
        return Err(
            "threads, max_nested_calls, worker_calls, queue, tick_ms, max_memory_bytes and table_elements must be positive, and max_calls at least threads".into(),
        );
    }
    if let Some(running) = RUNTIME.get() {
        let s = &running.settings;
        let same = s.threads == settings.threads
            && s.max_calls == settings.max_calls
            && s.max_nested_calls == settings.max_nested_calls
            && s.worker_calls == settings.worker_calls
            && s.queue == settings.queue
            && s.tick_ms == settings.tick_ms
            && s.cpu == settings.cpu
            && s.pooling == settings.pooling
            && s.max_memory_bytes == settings.max_memory_bytes
            && s.table_elements == settings.table_elements;
        return if same {
            Ok(())
        } else {
            Err("already configured differently".into())
        };
    }

    let engine = engine(cpu, &settings)?;
    let (tx, rx) = sync_channel::<Job>(settings.queue);
    let rx = Arc::new(Mutex::new(rx));
    let tick = Duration::from_millis(settings.tick_ms);

    let runtime = Runtime {
        engine: engine.clone(),
        cpu,
        settings: settings.clone(),
        tx,
        permits: Arc::new(Semaphore::new(settings.threads)),
        nested: Gate::new(settings.max_nested_calls),
    };
    if RUNTIME.set(runtime).is_err() {
        return Ok(());
    }

    let ticking = engine.clone();
    std::thread::Builder::new()
        .name("atanor-wasm-ticker".into())
        .spawn(move || loop {
            std::thread::sleep(tick);
            ticking.increment_epoch();
        })
        .map_err(|e| e.to_string())?;

    for i in 0..settings.max_calls {
        let rx = rx.clone();
        std::thread::Builder::new()
            .name(format!("atanor-wasm-{i}"))
            .spawn(move || worker(rx))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn worker(rx: Arc<Mutex<Receiver<Job>>>) {
    let rt = current_thread();
    loop {
        let job = match rx.lock().map(|rx| rx.recv()) {
            Ok(Ok(job)) => job,
            _ => return,
        };
        stats::QUEUED.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
        serve(&rt, job);
    }
}

fn current_thread() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
}

/// Runs one call to its end. The guest runs only while it holds one of the `threads` permits.
fn serve(rt: &tokio::runtime::Runtime, job: Job) {
    let permits = runtime().expect("configured").permits.clone();
    let (pid, tag) = (job.pid, job.tag);
    if !survives(|| rt.block_on(Running::new(permits, guest::run(job)))) {
        guest::report_panic(&pid, tag);
    }
}

/// Runs `f`; false when it panicked. A pool thread must outlive a panic, or the pool shrinks for good.
fn survives(f: impl FnOnce()) -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).is_ok()
}

/// Admits a call and queues it, or refuses it so overload is visible to callers. A call that
/// a guest made to another worker gets a thread of its own, up to `max_nested_calls`: its caller
/// is waiting for it, so it cannot wait for a pool thread behind its caller.
pub fn submit(mut job: Job) -> Result<(), ()> {
    let runtime = runtime().ok_or(())?;
    let nested = job.limits.nested;
    let gate = if nested {
        &runtime.nested
    } else {
        &job.pre.calls
    };
    let Some(slot) = gate.enter() else {
        stats::bump(&stats::REJECTED);
        return Err(());
    };
    job.slot = Some(slot);
    if nested {
        let spawned = std::thread::Builder::new()
            .name("atanor-wasm-nested".into())
            .spawn(move || serve(&current_thread(), job));
        return spawned
            .map(|_| ())
            .map_err(|_| stats::bump(&stats::REJECTED));
    }
    stats::QUEUED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    match runtime.tx.try_send(job) {
        Ok(()) => Ok(()),
        Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
            stats::QUEUED.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            stats::bump(&stats::REJECTED);
            Err(())
        }
    }
}

/// The calls of one worker's prepared component, in flight at once.
pub fn worker_gate() -> Arc<Gate> {
    Gate::new(runtime().expect("configured").settings.worker_calls)
}

/// The settings the unit tests share, so that the first test to configure decides for all.
#[cfg(test)]
pub fn test_settings() -> Settings {
    Settings {
        threads: 1,
        max_calls: 1,
        max_nested_calls: 1,
        worker_calls: 1,
        queue: 1,
        tick_ms: 10,
        cpu: "epoch".into(),
        pooling: true,
        max_memory_bytes: 64 << 20,
        table_elements: 100_000,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configuring_again_needs_the_same_settings() {
        let settings = test_settings();
        configure(settings.clone()).unwrap();
        assert!(configure(settings.clone()).is_ok());
        assert!(configure(Settings {
            threads: 2,
            ..settings
        })
        .is_err());
    }

    #[test]
    fn a_panic_is_contained() {
        assert!(survives(|| ()));
        assert!(!survives(|| panic!("on purpose")));
    }

    #[test]
    fn bad_settings_are_refused() {
        let ok = test_settings();
        assert!(configure(Settings {
            cpu: "magic".into(),
            ..ok.clone()
        })
        .is_err());
        assert!(configure(Settings { threads: 0, ..ok }).is_err());
    }
}
