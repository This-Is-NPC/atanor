//! Jobs. Headers `x-op` (`enqueue` or `cron`), `x-ns`, `x-key`, `x-kind` and
//! `x-at`; the body is the payload. When the handler runs it appends the
//! payload to the cell's table `fires`.

use crate::bindings::atanor::cell::jobs::{self, Error, NewJob, UniquePeriod};
use crate::bindings::atanor::cell::sql::{self, Address, Statement, Value};
use crate::bindings::exports::atanor::worker::job_handler::Guest;
use crate::{Handler, Request, Response};

pub fn handle(request: Request) -> Response {
    let ns = request.header("x-ns");
    let key = request.header("x-key");
    let cell = Address {
        namespace: ns.to_string(),
        key: key.to_string(),
    };
    let at = request.header("x-at").parse().ok();
    let job = NewJob {
        kind: request.header("x-kind").to_string(),
        payload: request.body.clone(),
        scheduled_at_ms: at,
        max_attempts: None,
        unique_key: None,
        unique_period: Some(UniquePeriod::UntilDone),
        idempotency_key: None,
    };
    let result = match request.header("x-op") {
        "enqueue" => jobs::enqueue(&cell, &job),
        "batch" => {
            let statements = vec![Statement {
                sql: "INSERT INTO fires (payload) VALUES (?)".to_string(),
                params: vec![Value::Text(
                    String::from_utf8_lossy(&request.body).into_owned(),
                )],
            }];
            jobs::enqueue_batch(&cell, &statements, &job)
        }
        op => return Response::text(400, format!("unknown op {op}")),
    };
    match result {
        Ok(id) => Response::text(200, id),
        Err(Error::NotGranted(what)) => Response::text(403, format!("not granted: {what}")),
        Err(Error::Failed(message)) => Response::text(500, format!("failed: {message}")),
    }
}

impl Guest for Handler {
    fn handle_job(
        namespace: String,
        key: String,
        _id: String,
        _idempotency_key: String,
        _kind: String,
        payload: Vec<u8>,
        _attempt: u32,
    ) -> Result<(), String> {
        let cell = Address { namespace, key };
        let payload = String::from_utf8_lossy(&payload).into_owned();
        match payload.as_str() {
            "fail" => Err("boom".into()),
            _ => sql::execute(
                &cell,
                "INSERT INTO fires (payload) VALUES (?)",
                &[Value::Text(payload)],
            )
            .map(|_| ())
            .map_err(|_| "cannot write the cell".to_string()),
        }
    }
}
