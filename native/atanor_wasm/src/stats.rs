//! Native counters and gauges, read with one NIF call (`stats/0`), and the
//! global allocator that counts every allocation of the library.
//!
//! Counters only grow; gauges go up and down. All are relaxed atomics, so a
//! read is a consistent value per field, not a snapshot across fields.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering::Relaxed};

use rustler::{Encoder, Env, Term};

/// Allocation counters are on the hot path of every thread, so each thread
/// adds to its own cache line and a read sums them.
#[repr(align(64))]
struct Shard {
    alloc: AtomicU64,
    free: AtomicU64,
}

static SHARDS: [Shard; 64] = [const {
    Shard {
        alloc: AtomicU64::new(0),
        free: AtomicU64::new(0),
    }
}; 64];

thread_local! {
    static MINE: usize = {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        NEXT.fetch_add(1, Relaxed) as usize % SHARDS.len()
    };
}

fn shard() -> &'static Shard {
    &SHARDS[MINE.try_with(|i| *i).unwrap_or(0)]
}

fn sum(f: impl Fn(&Shard) -> &AtomicU64) -> u64 {
    SHARDS.iter().map(|s| f(s).load(Relaxed)).sum()
}

/// The system allocator with byte counters. Wasmtime's own memories and code
/// are mapped, not allocated, so these are the Rust heap bytes only; the
/// linear memory of guests is counted by the `memory_*` gauges.
pub struct Counted;

unsafe impl GlobalAlloc for Counted {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        shard().alloc.fetch_add(layout.size() as u64, Relaxed);
        System.alloc(layout)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        shard().free.fetch_add(layout.size() as u64, Relaxed);
        System.dealloc(ptr, layout)
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        shard().alloc.fetch_add(layout.size() as u64, Relaxed);
        System.alloc_zeroed(layout)
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let s = shard();
        s.free.fetch_add(layout.size() as u64, Relaxed);
        s.alloc.fetch_add(new_size as u64, Relaxed);
        System.realloc(ptr, layout, new_size)
    }
}

macro_rules! counters {
    ($($name:ident),* $(,)?) => {
        $(pub static $name: AtomicU64 = AtomicU64::new(0);)*
    };
}

counters!(
    COMPILED,
    DISK_HITS,
    DISK_MISSES,
    CALLS,
    CALLS_OK,
    TRAPS_TIMEOUT,
    TRAPS_MEMORY,
    TRAPS_CPU,
    TRAPS_OTHER,
    FUEL_INTERRUPTS,
    EPOCH_INTERRUPTS,
    REJECTED,
    HOST_CALLS,
    INSTANTIATE_NS,
    CALL_NS,
    MEMORY_PEAK_TOTAL,
);

pub static LIVE_INSTANCES: AtomicI64 = AtomicI64::new(0);
pub static LIVE_COMPONENTS: AtomicI64 = AtomicI64::new(0);
pub static QUEUED: AtomicI64 = AtomicI64::new(0);

pub fn bump(counter: &AtomicU64) {
    counter.fetch_add(1, Relaxed);
}

pub fn add(counter: &AtomicU64, n: u64) {
    counter.fetch_add(n, Relaxed);
}

/// Every counter and gauge as `%{atom => integer}`.
#[rustler::nif]
fn stats(env: Env) -> Term {
    let get = |c: &AtomicU64| c.load(Relaxed) as i64;
    let pairs: Vec<(&str, i64)> = vec![
        ("alloc_bytes", sum(|s| &s.alloc) as i64),
        ("free_bytes", sum(|s| &s.free) as i64),
        ("compiled_components", get(&COMPILED)),
        ("live_components", LIVE_COMPONENTS.load(Relaxed)),
        ("disk_cache_hits", get(&DISK_HITS)),
        ("disk_cache_misses", get(&DISK_MISSES)),
        ("live_instances", LIVE_INSTANCES.load(Relaxed)),
        ("queued_calls", QUEUED.load(Relaxed)),
        ("calls", get(&CALLS)),
        ("calls_ok", get(&CALLS_OK)),
        ("traps_timeout", get(&TRAPS_TIMEOUT)),
        ("traps_memory", get(&TRAPS_MEMORY)),
        ("traps_cpu", get(&TRAPS_CPU)),
        ("traps_other", get(&TRAPS_OTHER)),
        ("fuel_interrupts", get(&FUEL_INTERRUPTS)),
        ("epoch_interrupts", get(&EPOCH_INTERRUPTS)),
        ("rejected_calls", get(&REJECTED)),
        ("host_calls", get(&HOST_CALLS)),
        ("instantiate_ns_total", get(&INSTANTIATE_NS)),
        ("call_ns_total", get(&CALL_NS)),
        ("memory_peak_bytes_total", get(&MEMORY_PEAK_TOTAL)),
    ];
    pairs.into_iter().fold(Term::map_new(env), |map, (k, v)| {
        let key = rustler::Atom::from_str(env, k).unwrap();
        map.map_put(key.encode(env), v.encode(env)).unwrap()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocations_are_counted_across_threads() {
        let before = sum(|s| &s.alloc);
        std::thread::scope(|scope| {
            for _ in 0..4 {
                scope.spawn(|| drop(std::hint::black_box(vec![0u8; 100_000])));
            }
        });
        assert!(sum(|s| &s.alloc) - before >= 400_000);
    }
}
