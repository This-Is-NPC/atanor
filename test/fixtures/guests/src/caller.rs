//! Calls the worker in `x-worker` at the path in `x-path`, with this
//! request's body, and returns its status and body.

use crate::bindings::atanor::worker::call::{self, Error};
use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    let outgoing = call::Request {
        method: "POST".into(),
        path: request.header("x-path").to_string(),
        query: String::new(),
        headers: vec![],
        body: request.body.clone(),
    };
    match call::call(request.header("x-worker"), &outgoing) {
        Ok(r) => Response::text(
            200,
            format!("{} {}", r.status, String::from_utf8_lossy(&r.body)),
        ),
        Err(Error::NotGranted(name)) => Response::text(403, format!("not granted: {name}")),
        Err(Error::Failed(message)) => Response::text(500, format!("failed: {message}")),
    }
}
