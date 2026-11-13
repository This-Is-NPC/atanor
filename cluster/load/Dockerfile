# syntax=docker/dockerfile:1
# The image of the load tests: the harness image plus the native worker of load_worker.ex, which a
# native module needs loaded in the node. Built by scripts/load-env on top of the harness image
# (docker build --build-arg BASE=IMAGE cluster/load); it is the first derived image of docs/design.md 17.
ARG BASE=atanor-cluster-node:local
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-28.5.0.7-debian-trixie-20261005-slim

FROM ${BASE} AS atanor

FROM ${ELIXIR_IMAGE} AS compile
COPY --from=atanor /opt/atanor/lib /atanor/lib
COPY load_worker.ex /src/load_worker.ex
RUN elixirc -pa '/atanor/lib/atanor-*/ebin' -o /out /src/load_worker.ex

FROM ${BASE}
COPY --from=compile /out /opt/atanor/load
ENV ERL_FLAGS="-pa /opt/atanor/load"
