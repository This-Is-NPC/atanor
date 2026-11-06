//! Allocates and touches memory until the host stops it. `?mib=N` limits it.

use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    let mib: usize = request.query.strip_prefix("mib=").and_then(|v| v.parse().ok()).unwrap_or(1024);
    let mut chunks: Vec<Vec<u8>> = Vec::new();
    for i in 0..mib {
        chunks.push(vec![i as u8; 1 << 20]);
    }
    Response::text(200, format!("allocated {} MiB", chunks.len()))
}
