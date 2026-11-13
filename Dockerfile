# syntax=docker/dockerfile:1
# The Atanor daemon: a release of daemon/ with the Erlang runtime and both NIFs (Alambique's and the
# WASM engine's). Everything comes from public sources: the Alambique tag in alambique.ref is a git
# dependency that `mix deps.get` clones. Build context: the repository root.
#
#   docker build --target runtime .   the product image (the default target)
#   docker build --target harness .   the same plus the tools of cluster/ (chaos, tc, healthchecks)
#   docker build --target artifact --output type=local,dest=out .   the release directory only
# The entry point runs the `atanor` CLI for its commands (docker run IMAGE deploy /w --bucket ...) and
# starts the node with no arguments.
# How to build and what the tarball needs: docs/how-to-build-the-release.md.

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-28.5.0.7-debian-trixie-20261005-slim
ARG RUNTIME_IMAGE=debian:trixie-20260824-slim

FROM ${ELIXIR_IMAGE} AS build
# The same Rust as mise.toml.
ARG RUST_VERSION=1.97.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git curl ca-certificates pkg-config \
 && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION}

WORKDIR /src
COPY mix.exs mix.lock alambique.ref ./
COPY daemon/mix.exs daemon/mix.exs
ENV MIX_ENV=prod LANG=C.UTF-8
RUN mix local.hex --force && mix local.rebar --force
# Cargo's job count is left to Cargo unless the build passes one.
ARG CARGO_BUILD_JOBS
WORKDIR /src/daemon
RUN mix deps.get --only prod
COPY lib /src/lib
COPY native /src/native
COPY wit /src/wit
COPY daemon /src/daemon
RUN --mount=type=cache,target=/opt/cargo/registry \
    --mount=type=cache,target=/src/native/atanor_wasm/target \
    --mount=type=cache,target=/src/daemon/deps/alambique/native/alambique_nif/target \
    mix release --overwrite

FROM scratch AS artifact
COPY --from=build /src/daemon/_build/prod/rel/atanor /atanor

# The libraries the release links against.
FROM ${RUNTIME_IMAGE} AS base
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3 libstdc++6 libncurses6 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /var/lib/atanor --create-home atanor \
 && mkdir /var/lib/atanor/cells \
 && chown atanor /var/lib/atanor/cells
ENV LANG=C.UTF-8

# What cluster/ uses: `tc` and `iptables` for faults, `ps`, and `curl` for healthchecks.
FROM base AS harness
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl iproute2 iptables procps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=artifact /atanor /opt/atanor
ARG RELEASE_ID=
ENV ATANOR_RELEASE=${RELEASE_ID}
USER atanor
WORKDIR /var/lib/atanor
EXPOSE 4000 4001 4002
ENTRYPOINT ["/opt/atanor/bin/atanor-entrypoint"]
CMD ["start"]

FROM base AS runtime
COPY --from=artifact /atanor /opt/atanor
# The release identity (design 17.1), empty for the default; last, so a new id rebuilds nothing.
ARG RELEASE_ID=
ENV ATANOR_RELEASE=${RELEASE_ID}
USER atanor
WORKDIR /var/lib/atanor
EXPOSE 4000 4001 4002
ENTRYPOINT ["/opt/atanor/bin/atanor-entrypoint"]
CMD ["start"]
