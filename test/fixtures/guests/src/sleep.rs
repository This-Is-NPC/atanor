//! Sleeps for the milliseconds in the last path segment (`/sleeper/300`) through `wasi:clocks`, then answers.

use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    let ms: u64 = request
        .path
        .rsplit('/')
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    std::thread::sleep(std::time::Duration::from_millis(ms));
    Response::text(200, format!("slept {ms}"))
}
