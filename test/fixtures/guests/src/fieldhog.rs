//! Holds `?n=N&size=S`: N `wasi:http` field sets of one S-byte value each, until the host refuses one.

use crate::bindings::wasi::http::types::Fields;
use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    let arg = |name: &str| -> usize {
        request
            .query
            .split('&')
            .find_map(|p| p.strip_prefix(name)?.strip_prefix('=')?.parse().ok())
            .unwrap_or(1)
    };
    let (n, size) = (arg("n"), arg("size"));
    let value = vec![b'a'; size];
    let mut kept = Vec::new();
    for _ in 0..n {
        let fields = Fields::new();
        if let Err(e) = fields.append(&"x".to_string(), &value) {
            return Response::text(413, format!("refused after {}: {e:?}", kept.len()));
        }
        kept.push(fields);
    }
    Response::text(200, format!("held {}", kept.len()))
}
