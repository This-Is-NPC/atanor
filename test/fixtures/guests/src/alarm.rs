//! Alarms. Headers `x-op` (`set` or `cancel`), `x-ns`, `x-key` and, for `set`,
//! `x-at` (ms since the epoch); the body is the payload. When an alarm fires
//! the handler appends the payload to the cell's table `fires`. Payloads:
//! `fail` always fails, `flaky` fails on its first delivery, `spin` never ends.

use crate::bindings::atanor::cell::alarms::{self, Error};
use crate::bindings::atanor::cell::sql::{self, Address, Value};
use crate::bindings::exports::atanor::worker::alarm_handler::Guest;
use crate::{Handler, Request, Response};

pub fn handle(request: Request) -> Response {
    let (ns, key) = (request.header("x-ns"), request.header("x-key"));
    let result = match request.header("x-op") {
        "set" => {
            let at = request.header("x-at").parse().unwrap_or(0);
            alarms::set_alarm(ns, key, at, &request.body)
        }
        "cancel" => alarms::cancel_alarm(ns, key),
        op => return Response::text(400, format!("unknown op {op}")),
    };
    match result {
        Ok(()) => Response::text(200, "ok"),
        Err(Error::NotGranted(ns)) => Response::text(403, format!("not granted: {ns}")),
        Err(Error::Failed(message)) => Response::text(500, format!("failed: {message}")),
    }
}

impl Guest for Handler {
    fn handle_alarm(namespace: String, key: String, payload: Vec<u8>) -> Result<(), String> {
        let cell = Address { namespace, key };
        let payload = String::from_utf8_lossy(&payload).into_owned();
        let record = |text: &str| {
            sql::execute(
                &cell,
                "INSERT INTO fires (payload) VALUES (?)",
                &[Value::Text(text.to_string())],
            )
            .map(|_| ())
            .map_err(|_| "cannot write the cell".to_string())
        };
        match payload.as_str() {
            "fail" => Err("boom".into()),
            "spin" => {
                let mut x: u64 = 0;
                loop {
                    x = std::hint::black_box(x.wrapping_add(1));
                }
            }
            "flaky" => {
                record("flaky-attempt")?;
                let rows = sql::query(
                    &cell,
                    "SELECT count(*) FROM fires WHERE payload = 'flaky-attempt'",
                    &[],
                )
                .map_err(|_| "cannot read the cell".to_string())?;
                match rows.rows[0][0] {
                    Value::Integer(1) => Err("flaky".into()),
                    _ => record("flaky"),
                }
            }
            _ => record(&payload),
        }
    }
}
