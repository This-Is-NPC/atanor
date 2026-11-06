//! Scoreboard: one cell per room (`rooms/ROOM`).
//!
//! POST /rooms/ROOM/scores?id=ID&player=NAME&points=N[&once=1]  record a score (201)
//! GET  /rooms/ROOM/writes?after=SEQ&limit=N                     what is stored, in order
//! GET  /rooms/ROOM                                              count and rankings
//! WebSocket /rooms/ROOM/live: send `join`, receive `score` and `rankings` events.
//!
//! A write and its `rank` job go in one transaction. The job recomputes the rankings.

mod bindings {
    wit_bindgen::generate!({
        world: "scoreboard",
        path: "wit",
        generate_all,
        pub_export_macro: true,
    });
}

use bindings::atanor::cell::jobs::{self, NewJob};
use bindings::atanor::cell::sockets;
use bindings::atanor::cell::sql::{self, Address, Statement, Value};
use bindings::exports::wasi::http::incoming_handler::Guest as Http;
use bindings::exports::atanor::worker::job_handler::Guest as JobHandler;
use bindings::exports::atanor::worker::socket_handler::{
    Frame, Guest as SocketHandler, Incoming, Reply, Request as SocketRequest, Upgrade,
};
use bindings::wasi::http::types::{
    Fields, IncomingBody, IncomingRequest, Method, OutgoingBody, OutgoingResponse, ResponseOutparam,
};

const NAMESPACE: &str = "rooms";
const PAGE_MAX: i64 = 1000;
/// Sent as `x-scoreboard-version` on every response: set `SCOREBOARD_VERSION` when building to tell
/// two deployments apart in the answers.
const VERSION: &str = match option_env!("SCOREBOARD_VERSION") {
    Some(version) => version,
    None => "1",
};

struct Handler;
bindings::export!(Handler with_types_in bindings);

struct Reply2 {
    status: u16,
    body: String,
}

fn json(status: u16, body: String) -> Reply2 {
    Reply2 { status, body }
}

fn error(status: u16, message: &str) -> Reply2 {
    json(status, format!("{{\"error\":{}}}", quote(message)))
}

fn quote(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn valid_name(s: &str) -> bool {
    !s.is_empty() && s.len() <= 100 && s.chars().all(|c| c.is_ascii_alphanumeric() || "._:-".contains(c))
}

fn decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if s.get(i + 1..i + 3).is_some_and(|h| u8::from_str_radix(h, 16).is_ok()) => {
                out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
                i += 2;
            }
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn param(query: &str, name: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        (k == name).then(|| decode(v))
    })
}

fn text(v: &Value) -> String {
    match v {
        Value::Text(s) => s.clone(),
        Value::Integer(i) => i.to_string(),
        _ => String::new(),
    }
}

fn int(v: &Value) -> i64 {
    match v {
        Value::Integer(i) => *i,
        _ => 0,
    }
}

// `overloaded`, `busy` and `store_unavailable` did not run the call: 503 tells the client to retry (the
// ingress adds `Retry-After`). `sync_failed` may have been applied, so it stays a 500.
fn status_of(message: &str) -> u16 {
    let retry = ["overloaded", "busy", "store_unavailable"].iter().any(|code| message.starts_with(code));
    if retry { 503 } else { 500 }
}

fn failure(e: sql::Error) -> Reply2 {
    let message = match e {
        sql::Error::NotGranted(what) => format!("not granted: {what}"),
        sql::Error::Failed(why) => why,
    };
    error(status_of(&message), &message)
}

fn cell(room: &str) -> Address {
    Address { namespace: NAMESPACE.into(), key: room.into() }
}

fn route(method: &str, path: &str, query: &str) -> Reply2 {
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    match (method, parts.as_slice()) {
        ("POST", ["rooms", room, "scores"]) if valid_name(room) => record(room, query),
        ("GET", ["rooms", room, "writes"]) if valid_name(room) => writes(room, query),
        ("GET", ["rooms", room]) if valid_name(room) => summary(room),
        _ => error(404, "not_found"),
    }
}

fn record(room: &str, query: &str) -> Reply2 {
    let id = param(query, "id").unwrap_or_default();
    let player = param(query, "player").unwrap_or_default();
    let points = param(query, "points").and_then(|p| p.parse::<i64>().ok());
    let (true, true, Some(points)) = (valid_name(&id), valid_name(&player), points) else {
        return error(400, "id and player (1-100 of A-Za-z0-9._:-) and integer points are required");
    };
    // `once=1` makes a retry of the same id a no-op; without it every request appends a row, so a
    // duplicate is visible to a checker.
    let sql = if param(query, "once").as_deref() == Some("1") {
        "INSERT INTO writes (id, player, points) SELECT ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM writes WHERE id = ?)"
    } else {
        "INSERT INTO writes (id, player, points) VALUES (?, ?, ?)"
    };
    let mut params = vec![Value::Text(id.clone()), Value::Text(player.clone()), Value::Integer(points)];
    if sql.contains("NOT EXISTS") {
        params.push(Value::Text(id.clone()));
    }
    let job = NewJob {
        kind: "rank".into(),
        payload: vec![],
        scheduled_at_ms: None,
        max_attempts: None,
        unique_key: None,
        unique_period: None,
        idempotency_key: None,
    };
    // The row and the job commit together or not at all.
    match jobs::enqueue_batch(&cell(room), &[Statement { sql: sql.into(), params }], &job) {
        Ok(_) => {
            let event = format!(
                "{{\"type\":\"score\",\"id\":{},\"player\":{},\"points\":{points}}}",
                quote(&id),
                quote(&player)
            );
            let _ = sockets::send_to_cell(NAMESPACE, room, event.as_bytes());
            json(201, format!("{{\"id\":{},\"room\":{}}}", quote(&id), quote(room)))
        }
        Err(jobs::Error::NotGranted(what)) => error(403, &format!("not granted: {what}")),
        Err(jobs::Error::Failed(why)) => {
            error(status_of(&why), &why)
        }
    }
}

fn writes(room: &str, query: &str) -> Reply2 {
    let after = param(query, "after").and_then(|v| v.parse::<i64>().ok()).unwrap_or(0);
    let limit = param(query, "limit").and_then(|v| v.parse::<i64>().ok()).unwrap_or(PAGE_MAX).clamp(1, PAGE_MAX);
    let rows = sql::query(
        &cell(room),
        "SELECT seq, id, player, points FROM writes WHERE seq > ? ORDER BY seq LIMIT ?",
        &[Value::Integer(after), Value::Integer(limit)],
    );
    match rows {
        Ok(rows) => {
            let items: Vec<String> = rows
                .rows
                .iter()
                .map(|r| {
                    format!(
                        "{{\"seq\":{},\"id\":{},\"player\":{},\"points\":{}}}",
                        int(&r[0]),
                        quote(&text(&r[1])),
                        quote(&text(&r[2])),
                        int(&r[3])
                    )
                })
                .collect();
            json(200, format!("{{\"room\":{},\"writes\":[{}]}}", quote(room), items.join(",")))
        }
        Err(e) => failure(e),
    }
}

fn summary(room: &str) -> Reply2 {
    let cell = cell(room);
    let statements = [
        Statement { sql: "SELECT COUNT(*), COALESCE(MAX(seq), 0) FROM writes".into(), params: vec![] },
        Statement { sql: "SELECT COALESCE((SELECT value FROM meta WHERE key = 'ranked_through'), 0)".into(), params: vec![] },
        Statement { sql: "SELECT rank, player, total FROM rankings ORDER BY rank, player LIMIT 100".into(), params: vec![] },
    ];
    match sql::batch(&cell, &statements) {
        Ok(sets) => {
            let (count, last) = (int(&sets[0].rows[0][0]), int(&sets[0].rows[0][1]));
            let ranked = int(&sets[1].rows[0][0]);
            json(
                200,
                format!(
                    "{{\"room\":{},\"writes\":{count},\"last_seq\":{last},\"ranked_through\":{ranked},\"rankings\":{}}}",
                    quote(room),
                    rankings_json(&sets[2])
                ),
            )
        }
        Err(e) => failure(e),
    }
}

fn rankings_json(rows: &sql::Rows) -> String {
    let items: Vec<String> = rows
        .rows
        .iter()
        .map(|r| format!("{{\"rank\":{},\"player\":{},\"total\":{}}}", int(&r[0]), quote(&text(&r[1])), int(&r[2])))
        .collect();
    format!("[{}]", items.join(","))
}

impl Http for Handler {
    fn handle(request: IncomingRequest, out: ResponseOutparam) {
        let method = match request.method() {
            Method::Get => "GET".to_string(),
            Method::Post => "POST".to_string(),
            Method::Other(m) => m,
            other => format!("{other:?}"),
        };
        let target = request.path_with_query().unwrap_or_default();
        let (path, query) = target.split_once('?').unwrap_or((target.as_str(), ""));
        // The body is not used; read it so the request is consumed.
        if let Ok(body) = request.consume() {
            let stream = body.stream().unwrap();
            while stream.blocking_read(65536).is_ok() {}
            drop(stream);
            IncomingBody::finish(body);
        }
        let reply = route(&method, path, query);

        let headers = Fields::from_list(&[
            ("content-type".to_string(), b"application/json".to_vec()),
            ("x-scoreboard-version".to_string(), VERSION.as_bytes().to_vec()),
        ])
        .unwrap();
        let response = OutgoingResponse::new(headers);
        response.set_status_code(reply.status).unwrap();
        let body = response.body().unwrap();
        ResponseOutparam::set(out, Ok(response));
        let stream = body.write().unwrap();
        for chunk in reply.body.as_bytes().chunks(4096) {
            stream.blocking_write_and_flush(chunk).unwrap();
        }
        drop(stream);
        OutgoingBody::finish(body, None).unwrap();
    }
}

impl JobHandler for Handler {
    fn handle_job(
        _namespace: String,
        key: String,
        _id: String,
        _idempotency_key: String,
        _kind: String,
        _payload: Vec<u8>,
        _attempt: u32,
    ) -> Result<(), String> {
        let cell = cell(&key);
        let statements = [
            "DELETE FROM rankings",
            "INSERT INTO rankings (player, total, rank) SELECT player, total, RANK() OVER (ORDER BY total DESC) FROM (SELECT player, SUM(points) AS total FROM writes GROUP BY player)",
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('ranked_through', (SELECT COALESCE(MAX(seq), 0) FROM writes))",
            "SELECT value FROM meta WHERE key = 'ranked_through'",
            "SELECT rank, player, total FROM rankings ORDER BY rank, player LIMIT 10",
        ]
        .map(|sql| Statement { sql: sql.into(), params: vec![] });
        let sets = sql::batch(&cell, &statements).map_err(|e| format!("{e:?}"))?;
        let event = format!(
            "{{\"type\":\"rankings\",\"ranked_through\":{},\"top\":{}}}",
            int(&sets[3].rows[0][0]),
            rankings_json(&sets[4])
        );
        let _ = sockets::send_to_cell(NAMESPACE, &key, event.as_bytes());
        Ok(())
    }
}

impl SocketHandler for Handler {
    fn on_open(_socket: String, _request: SocketRequest) -> Result<Upgrade, String> {
        Ok(Upgrade::Accept)
    }

    fn on_message(_socket: String, message: Incoming) -> Result<Reply, String> {
        let say = |t: String| Ok(Reply { frames: vec![Frame::Text(t)], close: false });
        match message {
            // `join ROOM`: attach, then the room's events arrive as cell messages.
            Incoming::Text(t) => match t.split_once(' ') {
                Some(("join", room)) if valid_name(room) => match sockets::attach(NAMESPACE, room) {
                    Ok(()) => say(format!("{{\"type\":\"joined\",\"room\":{}}}", quote(room))),
                    Err(_) => Err("cannot attach".into()),
                },
                _ => say("{\"error\":\"send: join ROOM\"}".into()),
            },
            Incoming::Cell(bytes) => say(String::from_utf8_lossy(&bytes).into_owned()),
            Incoming::Binary(_) => say("{\"error\":\"text frames only\"}".into()),
        }
    }

    fn on_close(_socket: String) {}
}
