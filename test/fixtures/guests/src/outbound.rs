//! GET of the URL in the `x-url` header through `wasi:http/outgoing-handler`.

use crate::bindings::wasi::http::outgoing_handler;
use crate::bindings::wasi::http::types::{Fields, Method, OutgoingRequest, Scheme};
use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    let url = request.header("x-url");
    let (scheme, rest) = url.split_once("://").unwrap_or(("http", url));
    let (authority, path) = rest
        .split_once('/')
        .map(|(a, p)| (a, format!("/{p}")))
        .unwrap_or((rest, "/".into()));

    let out = OutgoingRequest::new(Fields::new());
    out.set_method(&Method::Get).unwrap();
    out.set_scheme(Some(&if scheme == "https" {
        Scheme::Https
    } else {
        Scheme::Http
    }))
    .unwrap();
    out.set_authority(Some(authority)).unwrap();
    out.set_path_with_query(Some(&path)).unwrap();

    let future = match outgoing_handler::handle(out, None) {
        Ok(f) => f,
        Err(e) => return Response::text(502, format!("denied: {e:?}")),
    };
    future.subscribe().block();
    let response = match future.get() {
        Some(Ok(Ok(r))) => r,
        Some(Ok(Err(e))) => return Response::text(502, format!("failed: {e:?}")),
        _ => return Response::text(502, "no response"),
    };
    let status = response.status();
    let body = response.consume().unwrap();
    let stream = body.stream().unwrap();
    let mut bytes = Vec::new();
    while let Ok(chunk) = stream.blocking_read(65536) {
        bytes.extend_from_slice(&chunk);
    }
    Response::text(200, format!("{status} {}", String::from_utf8_lossy(&bytes)))
}
