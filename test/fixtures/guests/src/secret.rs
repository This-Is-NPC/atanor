//! Reads the secret named by the `x-name` header.

use crate::bindings::atanor::config::secrets::{self, Error};
use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    match secrets::get(request.header("x-name")) {
        Ok(value) => Response::text(200, value),
        Err(Error::NotGranted(name)) => Response::text(403, format!("not granted: {name}")),
        Err(Error::Missing(name)) => Response::text(404, format!("missing: {name}")),
    }
}
