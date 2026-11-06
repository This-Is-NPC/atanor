//! SQL on a cell. Headers `x-op` (`query`, `query-bounded`, `execute` or `batch`), `x-ns`,
//! `x-key` and `x-params` (comma-separated text parameters); the body is the
//! statement, or one statement per line for `batch`. `query-bounded` reads the lag in `x-lag`.
//! `x-op: partition` answers
//! the physical `namespace.key` of the partition key in `x-partition`.

use crate::bindings::atanor::cell::sql::{self, Address, Error, Rows, Statement, Value};
use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    let cell = Address { namespace: request.header("x-ns").to_string(), key: request.header("x-key").to_string() };
    let params: Vec<Value> = match request.header("x-params") {
        "" => vec![],
        p => p.split(',').map(|s| Value::Text(s.to_string())).collect(),
    };
    let body = String::from_utf8_lossy(&request.body).into_owned();

    let result = match request.header("x-op") {
        "query" => sql::query(&cell, &body, &params).map(|r| show_rows(&r)),
        "query-bounded" => {
            let lag = request.header("x-lag").parse().unwrap_or(0);
            sql::query_bounded(&cell, &body, &params, lag).map(|r| show_rows(&r))
        }
        "execute" => sql::execute(&cell, &body, &params).map(|r| show_rows(&r)),
        "batch" => {
            let statements: Vec<Statement> =
                body.lines().map(|l| Statement { sql: l.to_string(), params: vec![] }).collect();
            sql::batch(&cell, &statements).map(|rs| rs.iter().map(show_rows).collect::<Vec<_>>().join(";"))
        }
        "partition" => sql::partition(&cell, request.header("x-partition")).map(|a| format!("{}.{}", a.namespace, a.key)),
        op => return Response::text(400, format!("unknown op {op}")),
    };
    match result {
        Ok(text) => Response::text(200, text),
        Err(Error::NotGranted(ns)) => Response::text(403, format!("not granted: {ns}")),
        Err(Error::Failed(message)) => Response::text(500, format!("failed: {message}")),
    }
}

fn show_rows(rows: &Rows) -> String {
    let body: Vec<String> = rows
        .rows
        .iter()
        .map(|row| row.iter().map(show).collect::<Vec<_>>().join(","))
        .collect();
    format!("[{}] {}", rows.columns.join(","), body.join("|"))
}

fn show(value: &Value) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Integer(i) => i.to_string(),
        Value::Real(f) => f.to_string(),
        Value::Text(s) => s.clone(),
        Value::Blob(b) => format!("blob{}", b.len()),
    }
}
