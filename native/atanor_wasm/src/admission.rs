//! Which calls may run, and when (design 14.3): a counting gate for the calls
//! in flight, and a gate for the right to run guest code.
//!
//! A guest that waits (sleeps, polls, waits for a host call or an outbound
//! response) does not run, so it does not hold the right to run; it holds only
//! a call slot and an idle thread.

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};

use crate::engine::Queue;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, TryAcquireError};

/// At most `limit` slots are held at once.
pub struct Gate {
    limit: usize,
    count: AtomicUsize,
}

/// One call in flight; the gate gets it back when the slot is dropped. While the call waits
/// (see `Parker`) the slot is lent to the waiting bound.
pub struct Slot(Arc<Hold>);

struct Hold {
    gate: Arc<Gate>,
    /// Where the call may wait without its slot; `None` for a call that never does.
    parking: Option<Parking>,
    /// The call is counted in `parking.waiting`, not in `gate`.
    parked: AtomicBool,
    /// The slot is gone: the call is over.
    over: AtomicBool,
}

/// The bound on waiting guests and the pool whose thread a waiting guest frees.
pub struct Parking {
    pub waiting: Arc<Gate>,
    pub pool: Arc<Queue>,
}

/// What the guest's future uses to park the call's slot while the guest waits.
pub struct Parker(Arc<Hold>);

impl Gate {
    pub fn new(limit: usize) -> Arc<Gate> {
        Arc::new(Gate {
            limit,
            count: AtomicUsize::new(0),
        })
    }

    /// A slot, or `None` when `limit` slots are held.
    pub fn enter(self: &Arc<Self>) -> Option<Slot> {
        self.slot(None)
    }

    /// A slot whose call may wait without it (see `Parker`).
    pub fn enter_parkable(self: &Arc<Self>, parking: Parking) -> Option<Slot> {
        self.slot(Some(parking))
    }

    fn slot(self: &Arc<Self>, parking: Option<Parking>) -> Option<Slot> {
        self.take().then(|| {
            Slot(Arc::new(Hold {
                gate: self.clone(),
                parking,
                parked: AtomicBool::new(false),
                over: AtomicBool::new(false),
            }))
        })
    }

    /// Counts one more, unless `limit` are held.
    fn take(&self) -> bool {
        let mut held = self.count.load(Ordering::Relaxed);
        loop {
            if held >= self.limit {
                return false;
            }
            match self.count.compare_exchange_weak(
                held,
                held + 1,
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                Ok(_) => return true,
                Err(now) => held = now,
            }
        }
    }

    fn give(&self) {
        self.count.fetch_sub(1, Ordering::AcqRel);
    }

    #[cfg(test)]
    pub fn held(&self) -> usize {
        self.count.load(Ordering::Relaxed)
    }
}

impl Slot {
    /// The parker of a slot that can park; `None` for one that cannot.
    pub fn parker(&self) -> Option<Parker> {
        self.0.parking.as_ref().map(|_| Parker(self.0.clone()))
    }
}

impl Parker {
    /// The guest waits: its slot (and pool thread) are free for new calls while there is room
    /// among the waiting guests; otherwise it keeps them, as before.
    pub fn park(&self) {
        let hold = &self.0;
        let Some(parking) = &hold.parking else { return };
        if hold.over.load(Ordering::Acquire)
            || hold.parked.load(Ordering::Relaxed)
            || !parking.waiting.take()
        {
            return;
        }
        hold.parked.store(true, Ordering::Relaxed);
        hold.gate.give();
        parking.pool.leave();
    }

    /// The guest may run again. It is not refused: the call is already admitted, so the slot
    /// is taken back even above the limit (the waiting bound caps how far).
    pub fn unpark(&self) {
        let hold = &self.0;
        let Some(parking) = &hold.parking else { return };
        if !hold.parked.swap(false, Ordering::Relaxed) {
            return;
        }
        parking.waiting.give();
        hold.gate.count.fetch_add(1, Ordering::AcqRel);
        parking.pool.enter();
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        let hold = &self.0;
        hold.over.store(true, Ordering::Release);
        if hold.parked.swap(false, Ordering::Relaxed) {
            if let Some(parking) = &hold.parking {
                parking.waiting.give();
                parking.pool.enter();
            }
        } else {
            hold.gate.give();
        }
    }
}

type Acquire =
    Pin<Box<dyn Future<Output = Result<OwnedSemaphorePermit, tokio::sync::AcquireError>>>>;

/// Polls `inner` only while holding one of the permits, and gives the permit
/// back whenever `inner` returns `Pending`: a pending guest is waiting, not
/// running. Waiters are served in order.
pub struct Running<F> {
    permits: Arc<Semaphore>,
    parker: Option<Parker>,
    acquiring: Option<Acquire>,
    inner: Pin<Box<F>>,
}

impl<F: Future> Running<F> {
    pub fn new(permits: Arc<Semaphore>, parker: Option<Parker>, inner: F) -> Self {
        Running {
            permits,
            parker,
            acquiring: None,
            inner: Box::pin(inner),
        }
    }
}

impl<F: Future> Future for Running<F> {
    type Output = F::Output;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<F::Output> {
        let this = self.get_mut();
        // Woken: the call is runnable again, even if it still has to wait for a permit.
        if let Some(parker) = &this.parker {
            parker.unpark();
        }
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
        if let (Poll::Pending, Some(parker)) = (&out, &this.parker) {
            parker.park();
        }
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

    #[derive(Debug, Clone)]
    enum Step {
        Enter,
        Park(usize),
        Unpark(usize),
        End(usize),
    }

    fn steps() -> impl Strategy<Value = (usize, usize, Vec<Step>)> {
        (
            1usize..6,
            1usize..6,
            prop::collection::vec(
                prop_oneof![
                    Just(Step::Enter),
                    (0usize..16).prop_map(Step::Park),
                    (0usize..16).prop_map(Step::Unpark),
                    (0usize..16).prop_map(Step::End),
                ],
                0..300,
            ),
        )
    }

    proptest! {
        /// A call that waits gives its slot and its pool thread back, at most `waiting` calls
        /// do so, and a call that runs again takes them back. Every way a call ends (while it
        /// runs or after it parked) returns what it holds, so everything is free at the end.
        #[test]
        fn slots_follow_the_calls_that_wait((limit, waiting, steps) in steps()) {
            let (gate, waits) = (Gate::new(limit), Gate::new(waiting));
            let pool = Arc::new(Queue::new(limit, waits.clone()));
            let mut calls: Vec<(Slot, Parker, bool)> = Vec::new();
            for step in steps {
                let parked = |calls: &[(Slot, Parker, bool)]| calls.iter().filter(|c| c.2).count();
                match step {
                    Step::Enter => {
                        let running = calls.len() - parked(&calls);
                        let slot = gate.enter_parkable(Parking { waiting: waits.clone(), pool: pool.clone() });
                        prop_assert_eq!(slot.is_some(), running < limit);
                        if let Some(slot) = slot {
                            pool.enter();
                            let parker = slot.parker().unwrap();
                            calls.push((slot, parker, false));
                        }
                    }
                    Step::Park(i) if !calls.is_empty() => {
                        let room = parked(&calls) < waiting;
                        let n = i % calls.len();
                        let call = &mut calls[n];
                        call.1.park();
                        call.2 = call.2 || room;
                    }
                    Step::Unpark(i) if !calls.is_empty() => {
                        let n = i % calls.len();
                        calls[n].1.unpark();
                        calls[n].2 = false;
                    }
                    Step::End(i) if !calls.is_empty() => {
                        let n = i % calls.len();
                        drop(calls.swap_remove(n));
                        pool.leave();
                    }
                    _ => {}
                }
                let parked = parked(&calls);
                prop_assert!(parked <= waiting);
                prop_assert_eq!(waits.held(), parked);
                prop_assert_eq!(gate.held(), calls.len() - parked);
                prop_assert_eq!(pool.busy(), calls.len() - parked);
            }
            for _ in calls.drain(..) {
                pool.leave();
            }
            prop_assert_eq!((gate.held(), waits.held(), pool.busy()), (0, 0, 0));
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
                    let sleeping = sleeper(Running::new(permits.clone(), None, async {
                        tokio::time::sleep(Duration::from_millis(300)).await;
                    }));
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    // The sleeper is waiting: the only permit is free for another call.
                    let started = std::time::Instant::now();
                    Running::new(permits.clone(), None, async {}).await;
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
            let running = Running::new(permits.clone(), None, async {
                // Never pending: holds the permit for its whole poll.
                assert_eq!(permits.available_permits(), 0);
            });
            running.await;
            assert_eq!(permits.available_permits(), 1);
        });
    }
}
