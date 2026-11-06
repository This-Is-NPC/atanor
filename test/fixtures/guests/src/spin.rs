//! Runs forever.

use crate::{Request, Response};

pub fn handle(_: Request) -> Response {
    let mut x: u64 = 0;
    loop {
        x = std::hint::black_box(x.wrapping_add(1));
    }
}
