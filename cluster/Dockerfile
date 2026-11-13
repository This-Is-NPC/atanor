# syntax=docker/dockerfile:1
# An Atanor node as a release. Build context: the repository root; the named context
# `alambique` is a checkout of the Alambique release tag in alambique.ref (scripts/cluster-context, from
# $ALAMBIQUE_SOURCE or the public repository).

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-28.5.0.7-debian-trixie-20261005-slim
ARG RUNTIME_IMAGE=debian:trixie-20260824-slim

FROM ${ELIXIR_IMAGE} AS build
# The same Rust as mise.toml. Both NIFs (Alambique's and the WASM engine's) compile from source.
ARG RUST_VERSION=1.97.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git curl ca-certificates pkg-config \
 && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION}

# mix.exs of Atanor expects Alambique at ../alambique.
COPY --from=alambique / /src/alambique
COPY . /src/atanor
WORKDIR /src/atanor/cluster/node
ENV MIX_ENV=prod LANG=C.UTF-8
ARG CARGO_BUILD_JOBS=6
ENV CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}

# The node resolves the same versions as Atanor; only the Alambique path differs from the host's.
RUN git config --global --add safe.directory '*' \
 && sed -E 's|("alambique": \{:git, )"[^"]*"|\1"/src/alambique"|' /src/atanor/mix.lock > mix.lock \
 && mix local.hex --force && mix local.rebar --force \
 && mix deps.get
RUN --mount=type=cache,target=/opt/cargo/registry \
    --mount=type=cache,target=/src/atanor/native/atanor_wasm/target \
    --mount=type=cache,target=/src/atanor/cluster/node/deps/alambique/native/alambique_nif/target \
    mix release --overwrite

FROM ${RUNTIME_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3 libstdc++6 libncurses6 ca-certificates curl iproute2 iptables procps \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --home-dir /var/lib/atanor --create-home atanor
ENV LANG=C.UTF-8
COPY --from=build /src/atanor/cluster/node/_build/prod/rel/atanor_node /opt/atanor
COPY cluster/entrypoint /usr/local/bin/atanor-entrypoint
# The release identity (design 17.1); last, so a new id does not rebuild anything.
ARG RELEASE_ID=unknown
ENV ATANOR_RELEASE=${RELEASE_ID}
USER atanor
WORKDIR /var/lib/atanor
EXPOSE 4000 4001 4002
ENTRYPOINT ["/usr/local/bin/atanor-entrypoint"]
