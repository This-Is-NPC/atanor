//! Echoes the request. `/ambient` reports what the sandbox lets through,
//! `/work?n=N` does N million loop iterations and returns.

use crate::{Request, Response};

pub fn handle(request: Request) -> Response {
    if request.path.ends_with("/ambient") {
        return ambient();
    }
    if request.path.ends_with("/work") {
        return work(&request);
    }
    let body = String::from_utf8_lossy(&request.body);
    Response::text(
        200,
        format!(
            "hello {} {}?{} authority={} body={}",
            request.method, request.path, request.query, request.authority, body
        ),
    )
}

fn ambient() -> Response {
    let env = std::env::vars().count();
    let args = std::env::args().count();
    let dir = std::fs::read_dir("/")
        .map(|d| d.count())
        .map_err(|e| e.to_string());
    let file = std::fs::read_to_string("/etc/passwd").map_err(|e| e.to_string());
    let tcp = std::net::TcpStream::connect("1.1.1.1:80").map_err(|e| e.to_string());
    let lookup = std::net::ToSocketAddrs::to_socket_addrs(&("example.com", 80))
        .map(|a| a.count())
        .map_err(|e| e.to_string());
    Response::text(
        200,
        format!(
            "env={env}\nargs={args}\nread_dir={}\npasswd={}\ntcp={}\nlookup={}",
            show(&dir),
            show(&file.map(|_| ())),
            show(&tcp.map(|_| ())),
            show(&lookup)
        ),
    )
}

fn show<T>(r: &Result<T, String>) -> &'static str {
    if r.is_ok() {
        "allowed"
    } else {
        "denied"
    }
}

fn work(request: &Request) -> Response {
    let millions: u64 = request
        .query
        .strip_prefix("n=")
        .and_then(|v| v.parse().ok())
        .unwrap_or(1);
    let mut x: u64 = 0;
    for i in 0..millions * 1_000_000 {
        x = std::hint::black_box(x.wrapping_mul(31).wrapping_add(i));
    }
    Response::text(200, format!("work {x}"))
}
