//! The shared Wasmtime engine, the thread pool that runs guests and the
//! epoch ticker.
//!
//! Guests run on threads this crate owns, never on BEAM schedulers. A thread
//! runs one guest at a time, so a runaway guest costs one pool slot until its
//! limit stops it. The ticker is its own thread, so no guest can delay it.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::Semaphore;

use rustler::NifMap;
use wasmtime::{Config, Engine, InstanceAllocationStrategy, OptLevel, PoolingAllocationConfig};

use crate::admission::{Gate, Parking, Running, Slot};
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
    /// Calls in flight that are not waiting: the pool threads that serve them.
    pub max_calls: usize,
    /// Guests that wait without holding a call slot or a pool thread. Each has its own
    /// thread and instance slot, so this adds to `max_calls` in the pool.
    pub max_waiting: usize,
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
    queue: Arc<Queue>,
    permits: Arc<Semaphore>,
    nested: Arc<Gate>,
    waiting: Arc<Gate>,
}

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> Option<&'static Runtime> {
    RUNTIME.get()
}

/// The calls that hold a store at once: running or queued ones, waiting ones and nested ones.
fn instances(settings: &Settings) -> usize {
    settings.max_calls + settings.max_waiting + settings.max_nested_calls
}

/// A call holds one store from its start to its end, waiting or not, so the pool has a slot
/// for each call that may be in flight.
fn pool(settings: &Settings) -> PoolingAllocationConfig {
    let threads = instances(settings) as u32;
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
                "{e}; the pooling allocator reserves address space for {} calls: lower max_calls, max_waiting and max_nested_calls, or set pooling: false",
                instances(settings)
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
        || settings.max_waiting == 0
        || settings.worker_calls == 0
        || settings.queue == 0
        || settings.tick_ms == 0
        || settings.max_memory_bytes == 0
        || settings.table_elements == 0
    {
        return Err(
            "threads, max_nested_calls, max_waiting, worker_calls, queue, tick_ms, max_memory_bytes and table_elements must be positive, and max_calls at least threads".into(),
        );
    }
    if let Some(running) = RUNTIME.get() {
        let s = &running.settings;
        let same = s.threads == settings.threads
            && s.max_calls == settings.max_calls
            && s.max_nested_calls == settings.max_nested_calls
            && s.max_waiting == settings.max_waiting
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
    let queue = Arc::new(Queue::new(settings.max_calls));
    let tick = Duration::from_millis(settings.tick_ms);

    let runtime = Runtime {
        engine: engine.clone(),
        cpu,
        settings: settings.clone(),
        queue: queue.clone(),
        permits: Arc::new(Semaphore::new(settings.threads)),
        nested: Gate::new(settings.max_nested_calls),
        waiting: Gate::new(settings.max_waiting),
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

    for i in 0..settings.max_calls + settings.max_waiting {
        let queue = queue.clone();
        std::thread::Builder::new()
            .name(format!("atanor-wasm-{i}"))
            .spawn(move || worker(queue))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Jobs waiting for a pool thread. An idle thread sleeps on the condition and a new job wakes
/// exactly one, so a pool far larger than its load costs no wake-up chain per job.
///
/// The pool has `max_waiting` threads more than `max_calls`: a job is taken only while fewer than
/// `max_calls` calls are busy, and a call that waits is not busy, so its thread is not
/// counted and another call may use the pool in the meantime.
pub struct Queue {
    jobs: Mutex<VecDeque<Job>>,
    ready: Condvar,
    /// Calls on a pool thread that are not waiting.
    busy: AtomicUsize,
    /// Jobs in `jobs`, readable without the lock.
    queued: AtomicUsize,
    capacity: usize,
}

impl Queue {
    pub fn new(capacity: usize) -> Self {
        Queue {
            jobs: Mutex::default(),
            ready: Condvar::new(),
            busy: AtomicUsize::new(0),
            queued: AtomicUsize::new(0),
            capacity,
        }
    }

    /// Adds a job unless `limit` are already waiting.
    fn push(&self, job: Job, limit: usize) -> bool {
        let mut jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        if jobs.len() >= limit {
            return false;
        }
        jobs.push_back(job);
        self.queued.fetch_add(1, SeqCst);
        drop(jobs);
        self.ready.notify_one();
        true
    }

    /// The next job, once fewer than `capacity` calls are busy. The call is busy from here.
    fn pop(&self) -> Job {
        let mut jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if self.busy.load(SeqCst) < self.capacity {
                if let Some(job) = jobs.pop_front() {
                    self.queued.fetch_sub(1, SeqCst);
                    self.busy.fetch_add(1, SeqCst);
                    return job;
                }
            }
            jobs = self.ready.wait(jobs).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// A busy call waits or ends: a queued job may take its place.
    pub fn leave(&self) {
        self.busy.fetch_sub(1, SeqCst);
        if self.queued.load(SeqCst) > 0 {
            // Taking the lock orders this wake-up after a thread that is about to sleep.
            drop(self.jobs.lock().unwrap_or_else(|e| e.into_inner()));
            self.ready.notify_one();
        }
    }

    /// A waiting call runs again; it was admitted, so it is not refused.
    pub fn enter(&self) {
        self.busy.fetch_add(1, SeqCst);
    }

    #[cfg(test)]
    pub fn busy(&self) -> usize {
        self.busy.load(SeqCst)
    }
}

fn worker(queue: Arc<Queue>) {
    let rt = current_thread();
    loop {
        let job = queue.pop();
        stats::QUEUED.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
        serve(&rt, job);
        queue.leave();
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
    let parker = job.slot.as_ref().and_then(Slot::parker);
    if !survives(|| rt.block_on(Running::new(permits, parker, guest::run(job)))) {
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
    let slot = if nested {
        runtime.nested.enter()
    } else {
        job.pre.calls.enter_parkable(Parking {
            waiting: runtime.waiting.clone(),
            pool: runtime.queue.clone(),
        })
    };
    let Some(slot) = slot else {
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
    if runtime.queue.push(job, runtime.settings.queue) {
        Ok(())
    } else {
        stats::QUEUED.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
        stats::bump(&stats::REJECTED);
        Err(())
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
        max_waiting: 1,
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
