//! Test guests of Atanor. The feature picks the world and the behavior; see
//! `scripts/build-wasm-fixtures`.

macro_rules! world {
    ($($feature:literal => $world:literal),* $(,)?) => {
        mod bindings {
            $(
                #[cfg(feature = $feature)]
                wit_bindgen::generate!({
                    world: $world,
                    path: "wit",
                    generate_all,
                    pub_export_macro: true,
                });
            )*
        }
    };
}

world! {
    "hello" => "plain",
    "echo" => "plain",
    "spin" => "plain",
    "sleep" => "plain",
    "hog" => "plain",
    "fieldhog" => "plain",
    "crash" => "plain",
    "outbound" => "plain",
    "cell" => "cell",
    "secret" => "secret",
    "caller" => "caller",
    "alarm" => "alarm",
    "job" => "job",
    "socket" => "socket",
    "channel" => "channel",
    "sneaky" => "sneaky",
}

use bindings::exports::wasi::http::incoming_handler::Guest;
use bindings::wasi::http::types::{
    Fields, IncomingBody, IncomingRequest, Method, OutgoingBody, OutgoingResponse, ResponseOutparam,
};

pub struct Request {
    pub method: String,
    pub authority: String,
    pub path: String,
    pub query: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> &str {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
            .unwrap_or("")
    }
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Response {
    pub fn text(status: u16, body: impl Into<String>) -> Response {
        Response {
            status,
            body: body.into().into_bytes(),
        }
    }
}

#[cfg(feature = "alarm")]
mod alarm;
#[cfg(feature = "caller")]
mod caller;
#[cfg(feature = "cell")]
mod cell;
#[cfg(feature = "channel")]
mod channel;
#[cfg(feature = "crash")]
mod crash;
#[cfg(feature = "echo")]
mod echo;
#[cfg(feature = "fieldhog")]
mod fieldhog;
#[cfg(feature = "hello")]
mod hello;
#[cfg(feature = "hog")]
mod hog;
#[cfg(feature = "job")]
mod job;
#[cfg(feature = "outbound")]
mod outbound;
#[cfg(feature = "secret")]
mod secret;
#[cfg(feature = "sleep")]
mod sleep;
#[cfg(feature = "sneaky")]
mod sneaky;
#[cfg(feature = "socket")]
mod socket;
#[cfg(feature = "spin")]
mod spin;

#[cfg(feature = "alarm")]
use alarm::handle;
#[cfg(feature = "caller")]
use caller::handle;
#[cfg(feature = "cell")]
use cell::handle;
#[cfg(feature = "channel")]
use channel::handle;
#[cfg(feature = "crash")]
use crash::handle;
#[cfg(feature = "echo")]
use echo::handle;
#[cfg(feature = "fieldhog")]
use fieldhog::handle;
#[cfg(feature = "hello")]
use hello::handle;
#[cfg(feature = "hog")]
use hog::handle;
#[cfg(feature = "job")]
use job::handle;
#[cfg(feature = "outbound")]
use outbound::handle;
#[cfg(feature = "secret")]
use secret::handle;
#[cfg(feature = "sleep")]
use sleep::handle;
#[cfg(feature = "sneaky")]
use sneaky::handle;
#[cfg(feature = "socket")]
use socket::handle;
#[cfg(feature = "spin")]
use spin::handle;

pub struct Handler;

bindings::export!(Handler with_types_in bindings);

impl Guest for Handler {
    fn handle(request: IncomingRequest, out: ResponseOutparam) {
        let response = handle(read(request));
        let response_head = OutgoingResponse::new(
            Fields::from_list(&[("content-type".to_string(), b"text/plain".to_vec())]).unwrap(),
        );
        response_head.set_status_code(response.status).unwrap();
        let body = response_head.body().unwrap();
        ResponseOutparam::set(out, Ok(response_head));
        let stream = body.write().unwrap();
        for chunk in response.body.chunks(4096) {
            stream.blocking_write_and_flush(chunk).unwrap();
        }
        drop(stream);
        OutgoingBody::finish(body, None).unwrap();
    }
}

fn read(request: IncomingRequest) -> Request {
    let method = match request.method() {
        Method::Get => "GET".to_string(),
        Method::Post => "POST".to_string(),
        Method::Put => "PUT".to_string(),
        Method::Delete => "DELETE".to_string(),
        Method::Patch => "PATCH".to_string(),
        Method::Head => "HEAD".to_string(),
        Method::Options => "OPTIONS".to_string(),
        Method::Connect => "CONNECT".to_string(),
        Method::Trace => "TRACE".to_string(),
        Method::Other(m) => m,
    };
    let target = request.path_with_query().unwrap_or_default();
    let (path, query) = target.split_once('?').unwrap_or((target.as_str(), ""));
    let headers = request
        .headers()
        .entries()
        .into_iter()
        .map(|(n, v)| (n, String::from_utf8_lossy(&v).into_owned()))
        .collect();
    let body = request.consume().map(read_body).unwrap_or_default();
    Request {
        method,
        authority: request.authority().unwrap_or_default(),
        path: path.to_string(),
        query: query.to_string(),
        headers,
        body,
    }
}

fn read_body(body: IncomingBody) -> Vec<u8> {
    let stream = body.stream().unwrap();
    let mut out = Vec::new();
    while let Ok(chunk) = stream.blocking_read(65536) {
        out.extend_from_slice(&chunk);
    }
    drop(stream);
    IncomingBody::finish(body);
    out
}
