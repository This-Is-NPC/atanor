//! Imports every binding and exports every handler. Run with fewer grants, it
//! must not instantiate.

use crate::bindings::atanor::cell::sql::{self, Address};
use crate::bindings::atanor::cell::{alarms, sockets};
use crate::bindings::atanor::config::secrets;
use crate::bindings::atanor::worker::call;
use crate::bindings::exports::atanor::worker::{alarm_handler, socket_handler};
use crate::{Handler, Request, Response};

pub fn handle(request: Request) -> Response {
    let cell = Address {
        namespace: "secret-ns".into(),
        key: "k".into(),
    };
    let rows = sql::query(&cell, "SELECT 1", &[]).is_ok();
    let secret = secrets::get("API_TOKEN").is_ok();
    let outgoing = call::Request {
        method: "GET".into(),
        path: "/".into(),
        query: String::new(),
        headers: vec![],
        body: vec![],
    };
    let called = call::call("other", &outgoing).is_ok();
    let alarm = alarms::set_alarm("secret-ns", "k", 0, &[]).is_ok();
    let socket = sockets::send_to_cell("secret-ns", "k", &[]).is_ok();
    Response::text(
        200,
        format!(
            "{} sql={rows} secret={secret} call={called} alarm={alarm} socket={socket}",
            request.path
        ),
    )
}

impl alarm_handler::Guest for Handler {
    fn handle_alarm(_namespace: String, _key: String, _payload: Vec<u8>) -> Result<(), String> {
        Ok(())
    }
}

impl socket_handler::Guest for Handler {
    fn on_open(
        _socket: String,
        _request: socket_handler::Request,
    ) -> Result<socket_handler::Upgrade, String> {
        Ok(socket_handler::Upgrade::Accept)
    }

    fn on_message(
        _socket: String,
        _message: socket_handler::Incoming,
    ) -> Result<socket_handler::Reply, String> {
        Ok(socket_handler::Reply {
            frames: vec![],
            close: false,
        })
    }

    fn on_close(_socket: String) {}
}
