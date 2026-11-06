//! Panics: the guest traps and the host sees a trap, not a limit.

use crate::{Request, Response};

pub fn handle(_request: Request) -> Response {
    panic!("the guest panics on purpose")
}
