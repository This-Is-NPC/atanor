//! Which calls may run, and when (design 14.3): a counting gate for the calls
//! in flight, and a gate for the right to run guest code.
//!
//! A guest that waits (sleeps, polls, waits for a host call or an outbound
//! response) does not run, so it does not hold the right to run; it holds only
//! a call slot and an idle thread.

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};

use tokio::sync::{OwnedSemaphorePermit, Semaphore, TryAcquireError};

/// At most `limit` slots are held at once.
pub struct Gate {
    limit: usize,
    count: AtomicUsize,
}

/// One call in flight; the gate gets it back when the slot is dropped.
pub struct Slot(Arc<Gate>);

impl Gate {
    pub fn new(limit: usize) -> Arc<Gate> {
        Arc::new(Gate {
            limit,
            count: AtomicUsize::new(0),
        })
    }

    /// A slot, or `None` when `limit` slots are held.
    pub fn enter(self: &Arc<Self>) -> Option<Slot> {
        let mut held = self.count.load(Ordering::Relaxed);
        loop {
            if held >= self.limit {
                return None;
            }
            match self.count.compare_exchange_weak(
                held,
                held + 1,
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Some(Slot(self.clone())),
                Err(now) => held = now,
            }
        }
    }

    #[cfg(test)]
    pub fn held(&self) -> usize {
        self.count.load(Ordering::Relaxed)
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.count.fetch_sub(1, Ordering::AcqRel);
    }
}

type Acquire =
    Pin<Box<dyn Future<Output = Result<OwnedSemaphorePermit, tokio::sync::AcquireError>>>>;

/// Polls `inner` only while holding one of the permits, and gives the permit
/// back whenever `inner` returns `Pending`: a pending guest is waiting, not
/// running. Waiters are served in order.
pub struct Running<F> {
    permits: Arc<Semaphore>,
    acquiring: Option<Acquire>,
    inner: Pin<Box<F>>,
}

impl<F: Future> Running<F> {
    pub fn new(permits: Arc<Semaphore>, inner: F) -> Self {
        Running {
            permits,
            acquiring: None,
            inner: Box::pin(inner),
        }
    }
}

impl<F: Future> Future for Running<F> {
    type Output = F::Output;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<F::Output> {
        let this = self.get_mut();
        // The semaphore is private to the engine and never closed, so acquiring cannot fail.
        let permit = match this.acquiring.as_mut() {
            Some(acquiring) => match acquiring.as_mut().poll(cx) {
                Poll::Ready(permit) => {
                    this.acquiring = None;
                    permit.expect("the permits are never closed")
                }
                Poll::Pending => return Poll::Pending,
            },
            None => match this.permits.clone().try_acquire_owned() {
                Ok(permit) => permit,
                Err(TryAcquireError::Closed) => unreachable!("the permits are never closed"),
                Err(TryAcquireError::NoPermits) => {
                    let mut acquiring: Acquire = Box::pin(this.permits.clone().acquire_owned());
                    match acquiring.as_mut().poll(cx) {
                        Poll::Ready(permit) => permit.expect("the permits are never closed"),
                        Poll::Pending => {
                            this.acquiring = Some(acquiring);
                            return Poll::Pending;
                        }
                    }
                }
            },
        };
        let out = this.inner.as_mut().poll(cx);
        drop(permit);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::time::Duration;

    #[derive(Debug, Clone)]
    enum Op {
        Enter,
        Leave(usize),
    }

    fn ops() -> impl Strategy<Value = (usize, Vec<Op>)> {
        (
            1usize..8,
            prop::collection::vec(
                prop_oneof![Just(Op::Enter), (0usize..16).prop_map(Op::Leave)],
                0..200,
            ),
        )
    }

    proptest! {
        /// Admission: never more than `limit` slots held; a refusal only at the limit; a
        /// release always makes room.
        #[test]
        fn a_gate_admits_exactly_up_to_its_limit((limit, ops) in ops()) {
            let gate = Gate::new(limit);
            let mut held: Vec<Slot> = Vec::new();
            for op in ops {
                match op {
                    Op::Enter => match gate.enter() {
                        Some(slot) => {
                            held.push(slot);
                            prop_assert!(held.len() <= limit);
                        }
                        None => prop_assert_eq!(held.len(), limit),
                    },
                    Op::Leave(i) if !held.is_empty() => {
                        held.swap_remove(i % held.len());
                    }
                    Op::Leave(_) => {}
                }
                prop_assert_eq!(gate.held(), held.len());
            }
            drop(held);
            prop_assert_eq!(gate.held(), 0);
        }
    }

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    }

    #[test]
    fn a_waiting_future_does_not_hold_a_permit() {
        let permits = Arc::new(Semaphore::new(1));
        runtime().block_on(async {
            let sleeper = tokio::task::spawn_local;
            let local = tokio::task::LocalSet::new();
            local
                .run_until(async {
                    let sleeping = sleeper(Running::new(permits.clone(), async {
                        tokio::time::sleep(Duration::from_millis(300)).await;
                    }));
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    // The sleeper is waiting: the only permit is free for another call.
                    let started = std::time::Instant::now();
                    Running::new(permits.clone(), async {}).await;
                    assert!(started.elapsed() < Duration::from_millis(200));
                    sleeping.await.unwrap();
                })
                .await;
        });
    }

    #[test]
    fn a_running_future_keeps_its_permit_until_it_waits() {
        let permits = Arc::new(Semaphore::new(1));
        runtime().block_on(async {
            let running = Running::new(permits.clone(), async {
                // Never pending: holds the permit for its whole poll.
                assert_eq!(permits.available_permits(), 0);
            });
            running.await;
            assert_eq!(permits.available_permits(), 1);
        });
    }
}
