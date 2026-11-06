//! Answers with the value of the header named by `x-name`.

use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    Response::text(200, request.header(request.header("x-name")).to_string())
}
