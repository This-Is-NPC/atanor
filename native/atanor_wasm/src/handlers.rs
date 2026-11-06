//! The exports the host calls besides `wasi:http`: the alarm, socket, local
//! socket and job handlers. A component has any of them.

pub mod alarm {
    wasmtime::component::bindgen!({
        path: ["../../wit/cell", "../../wit/config", "../../wit/worker", "wit"],
        world: "atanor:host/alarm-guest",
        exports: { default: async },
    });
}

pub mod socket {
    wasmtime::component::bindgen!({
        path: ["../../wit/cell", "../../wit/config", "../../wit/worker", "wit"],
        world: "atanor:host/socket-guest",
        exports: { default: async },
    });
}

pub mod job {
    wasmtime::component::bindgen!({
        path: ["../../wit/cell", "../../wit/config", "../../wit/worker", "wit"],
        world: "atanor:host/job-guest",
        exports: { default: async },
    });
}

pub mod local {
    wasmtime::component::bindgen!({
        path: ["../../wit/cell", "../../wit/config", "../../wit/worker", "wit"],
        world: "atanor:host/local-guest",
        exports: { default: async },
    });
}
