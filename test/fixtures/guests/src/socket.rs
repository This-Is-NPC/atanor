//! WebSockets. a path ending in `/reject` is refused when it opens. Text frames: `echo X`,
//! `join ROOM` (attach to the cell `rooms/ROOM`), `say ROOM X` (send X to that
//! cell), `id` (the socket id), `bye`, `fail` (an error) and `spin` (never
//! ends). Binary frames come back reversed, cell messages as `cell:X`. When a
//! socket closes the handler records its id in the cell `rooms/log`.

use crate::bindings::atanor::cell::sockets;
use crate::bindings::atanor::cell::sql::{self, Address, Value};
use crate::bindings::exports::atanor::worker::socket_handler::{
    Frame, Guest, Incoming, Reply, Request as SocketRequest, Response as Rejection, Upgrade,
};
use crate::{Handler, Request, Response};

pub fn handle(_: Request) -> Response {
    Response::text(200, "plain http")
}

fn say(text: String) -> Result<Reply, String> {
    Ok(Reply { frames: vec![Frame::Text(text)], close: false })
}

fn outcome(result: Result<(), sockets::Error>) -> String {
    match result {
        Ok(()) => "ok".into(),
        Err(sockets::Error::NotGranted(what)) => format!("not granted: {what}"),
        Err(sockets::Error::Failed(why)) => format!("failed: {why}"),
    }
}

impl Guest for Handler {
    fn on_open(_socket: String, request: SocketRequest) -> Result<Upgrade, String> {
        if request.path.ends_with("/reject") {
            let body = b"no sockets for you".to_vec();
            return Ok(Upgrade::Reject(Rejection { status: 403, headers: vec![], body }));
        }
        Ok(Upgrade::Accept)
    }

    fn on_message(socket: String, message: Incoming) -> Result<Reply, String> {
        match message {
            Incoming::Binary(mut data) => {
                data.reverse();
                Ok(Reply { frames: vec![Frame::Binary(data)], close: false })
            }
            Incoming::Cell(data) => say(format!("cell:{}", String::from_utf8_lossy(&data))),
            Incoming::Text(text) => match text.split_once(' ').unwrap_or((text.as_str(), "")) {
                ("echo", rest) => say(rest.to_string()),
                ("join", room) => say(outcome(sockets::attach("rooms", room))),
                ("say", rest) => {
                    let (room, body) = rest.split_once(' ').unwrap_or((rest, ""));
                    say(outcome(sockets::send_to_cell("rooms", room, body.as_bytes())))
                }
                ("id", _) => say(socket),
                ("bye", _) => Ok(Reply { frames: vec![Frame::Text("bye".into())], close: true }),
                ("fail", _) => Err("boom".into()),
                ("spin", _) => {
                    let mut x: u64 = 0;
                    loop {
                        x = std::hint::black_box(x.wrapping_add(1));
                    }
                }
                (other, _) => say(format!("?{other}")),
            },
        }
    }

    fn on_close(socket: String) {
        let cell = Address { namespace: "rooms".into(), key: "log".into() };
        let _ = sql::execute(&cell, "INSERT INTO log (socket) VALUES (?)", &[Value::Text(socket)]);
    }
}
