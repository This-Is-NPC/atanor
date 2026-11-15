//! The plain WASM worker of the load tests: the twin of `AtanorLoad.Worker` (cluster/load).
//!
//! POST /plain/CELL  appends one row, the body of the request (201)
//! GET  /plain/CELL  counts the rows of the cell (200)
//!
//! One SQL statement per request and no jobs: it does the same work as the native worker.

mod bindings {
    wit_bindgen::generate!({
        world: "load-plain",
        path: "wit",
        generate_all,
        pub_export_macro: true,
    });
}

use bindings::atanor::cell::sql::{self, Address, Value};
use bindings::exports::wasi::http::incoming_handler::Guest;
use bindings::wasi::http::types::{
    Fields, IncomingBody, IncomingRequest, Method, OutgoingBody, OutgoingResponse, ResponseOutparam,
};

struct Handler;
bindings::export!(Handler with_types_in bindings);

fn cell(key: &str) -> Address {
    Address {
        namespace: "plain".into(),
        key: key.into(),
    }
}

fn read_body(request: IncomingRequest) -> Vec<u8> {
    let mut data = Vec::new();
    if let Ok(body) = request.consume() {
        let stream = body.stream().unwrap();
        while let Ok(chunk) = stream.blocking_read(65536) {
            data.extend_from_slice(&chunk);
        }
        drop(stream);
        IncomingBody::finish(body);
    }
    data
}

fn route(method: &Method, key: &str, body: Vec<u8>) -> (u16, String) {
    let ok = |status, text: String| (status, text);
    match method {
        Method::Get => match sql::query(&cell(key), "SELECT count(*) FROM log", &[]) {
            Ok(rows) => match rows.rows.first().and_then(|r| r.first()) {
                Some(Value::Integer(n)) => ok(200, format!("{{\"rows\":{n}}}")),
                _ => ok(500, r#"{"error":"read"}"#.into()),
            },
            Err(_) => ok(500, r#"{"error":"read"}"#.into()),
        },
        Method::Post => {
            let text = String::from_utf8_lossy(&body).into_owned();
            match sql::execute(
                &cell(key),
                "INSERT INTO log (v) VALUES (?)",
                &[Value::Text(text)],
            ) {
                Ok(_) => ok(201, r#"{"ok":true}"#.into()),
                Err(_) => ok(500, r#"{"error":"write"}"#.into()),
            }
        }
        _ => ok(404, r#"{"error":"not found"}"#.into()),
    }
}

impl Guest for Handler {
    fn handle(request: IncomingRequest, out: ResponseOutparam) {
        let method = request.method();
        let target = request.path_with_query().unwrap_or_default();
        let path = target.split('?').next().unwrap_or("");
        let body = read_body(request);
        let (status, text) = match path.strip_prefix("/plain/") {
            Some(key) if !key.is_empty() => route(&method, key, body),
            _ => (404, r#"{"error":"not found"}"#.into()),
        };

        let headers =
            Fields::from_list(&[("content-type".to_string(), b"application/json".to_vec())])
                .unwrap();
        let response = OutgoingResponse::new(headers);
        response.set_status_code(status).unwrap();
        let body = response.body().unwrap();
        ResponseOutparam::set(out, Ok(response));
        let stream = body.write().unwrap();
        stream.blocking_write_and_flush(text.as_bytes()).unwrap();
        drop(stream);
        OutgoingBody::finish(body, None).unwrap();
    }
}
