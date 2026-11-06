use wasi::exports::http::incoming_handler::Guest;
use wasi::http::proxy::export;
use wasi::http::types::{
    Fields, IncomingRequest, OutgoingBody, OutgoingResponse, ResponseOutparam,
};

struct Hello;

impl Guest for Hello {
    fn handle(request: IncomingRequest, out: ResponseOutparam) {
        let path = request.path_with_query().unwrap_or_default();
        let headers =
            Fields::from_list(&[("content-type".to_string(), b"text/plain".to_vec())]).unwrap();
        let response = OutgoingResponse::new(headers);
        let body = response.body().unwrap();
        ResponseOutparam::set(out, Ok(response));

        let stream = body.write().unwrap();
        stream
            .blocking_write_and_flush(format!("hello from wasm, you asked for {path}\n").as_bytes())
            .unwrap();
        drop(stream);
        OutgoingBody::finish(body, None).unwrap();
    }
}

export!(Hello);
