# syntax=docker/dockerfile:1
# Written by `mix atanor.release`: the release of this app and Atanor in one VM, on the base of the
# product image. Build it from ../..:
#   docker build -f examples/live-counter/Dockerfile -t my-app ../..
# EXTRA_PACKAGES adds Debian packages to the image (for example curl, for a healthcheck).
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-28.5.0.7-debian-trixie-20261005-slim
ARG RUNTIME_IMAGE=debian:trixie-20260824-slim

FROM ${ELIXIR_IMAGE} AS build
ARG RUST_VERSION=1.97.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git curl ca-certificates pkg-config \
 && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION}
ENV MIX_ENV=prod LANG=C.UTF-8
RUN mix local.hex --force && mix local.rebar --force
ARG CARGO_BUILD_JOBS
WORKDIR /src
COPY . /src
WORKDIR /src/examples/live-counter
RUN mix deps.get --only prod
RUN --mount=type=cache,target=/opt/cargo/registry \
    --mount=type=cache,target=/src/native/atanor_wasm/target \
    --mount=type=cache,target=/src/examples/live-counter/deps/alambique/native/alambique_nif/target \
    mix release atanor --overwrite

FROM ${RUNTIME_IMAGE}
ARG EXTRA_PACKAGES=
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3 libstdc++6 libncurses6 ca-certificates ${EXTRA_PACKAGES} \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /var/lib/atanor --create-home atanor \
 && mkdir /var/lib/atanor/cells \
 && chown atanor /var/lib/atanor/cells
ENV LANG=C.UTF-8
COPY --from=build /src/examples/live-counter/_build/prod/rel/atanor /opt/atanor
ARG RELEASE_ID=
ENV ATANOR_RELEASE=${RELEASE_ID}
USER atanor
WORKDIR /var/lib/atanor
EXPOSE 4000 4001 4002
ENTRYPOINT ["/opt/atanor/bin/atanor-entrypoint"]
CMD ["start"]
