//! Ephemeral channels. Local frames (`on-frame`): `cur ROOM X` publishes
//! `<socket>:X` to the channel `rooms/ROOM` and ends there, `probe` publishes to
//! `rooms/probe` what a cell write from this call returned, any other frame
//! passes. Owner frames (`on-message`): `join ROOM [ID]`, `leave ROOM`, `pub ROOM X`,
//! `big ROOM N` (publishes N bytes), `members ROOM` (`COUNT:ID,ID`), `echo X`.

use crate::bindings::atanor::cell::sockets::{self, Message};
use crate::bindings::atanor::cell::sql::{self, Address, Value};
use crate::bindings::exports::atanor::worker::socket_handler::{
    Frame, Guest, Incoming, Reply, Request as SocketRequest, Upgrade,
};
use crate::bindings::exports::atanor::worker::socket_local::{self, Verdict};
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

impl socket_local::Guest for Handler {
    fn on_frame(socket: String, frame: Frame) -> Result<Verdict, String> {
        let Frame::Text(text) = frame else { return Ok(Verdict::Pass) };
        if text == "probe" {
            let cell = Address { namespace: "rooms".into(), key: "probe".into() };
            let write = match sql::execute(&cell, "INSERT INTO log (socket) VALUES ('x')", &[]) {
                Ok(_) => "wrote".to_string(),
                Err(sql::Error::NotGranted(what)) => format!("not granted: {what}"),
                Err(_) => "failed".to_string(),
            };
            let _ = sockets::publish("rooms", "probe", &Message::Text(write));
            return Ok(Verdict::Drop);
        }
        match text.strip_prefix("cur ").and_then(|rest| rest.split_once(' ')) {
            Some((room, body)) => {
                let _ = sockets::publish("rooms", room, &Message::Text(format!("{socket}:{body}")));
                Ok(Verdict::Drop)
            }
            None => Ok(Verdict::Pass),
        }
    }
}

impl Guest for Handler {
    fn on_open(_socket: String, _request: SocketRequest) -> Result<Upgrade, String> {
        Ok(Upgrade::Accept)
    }

    fn on_message(_socket: String, message: Incoming) -> Result<Reply, String> {
        let Incoming::Text(text) = message else { return say("?".into()) };
        let (word, rest) = text.split_once(' ').unwrap_or((text.as_str(), ""));
        let (room, tail) = rest.split_once(' ').map_or((rest, None), |(r, t)| (r, Some(t)));
        match word {
            "echo" => say(rest.to_string()),
            "join" => say(outcome(sockets::join_channel("rooms", room, tail))),
            "leave" => say(outcome(sockets::leave_channel("rooms", room))),
            "pub" => say(outcome(sockets::publish("rooms", room, &Message::Text(tail.unwrap_or("").into())))),
            "big" => {
                let n: usize = tail.and_then(|n| n.parse().ok()).unwrap_or(0);
                say(outcome(sockets::publish("rooms", room, &Message::Binary(vec![0; n]))))
            }
            "members" => match sockets::channel_members("rooms", room) {
                Ok(m) => say(format!("{}:{}", m.count, m.ids.join(","))),
                Err(sockets::Error::NotGranted(what)) => say(format!("not granted: {what}")),
                Err(sockets::Error::Failed(why)) => say(format!("failed: {why}")),
            },
            other => say(format!("?{other}")),
        }
    }

    fn on_close(_socket: String) {}
}
