# syntax=docker/dockerfile:1
# featured/kathara — Kathara network emulation on top of Docker-in-Docker
# Dependency chain: featured/base -> featured/dind -> featured/kathara
ARG BASE_IMAGE=base-image
FROM ${BASE_IMAGE} AS system

ARG NETCAP_VERSION=v0.6.11

# Install Kathara and network tools
RUN --mount=type=bind,source=docker/kathara/install-scripts/setup-kathara.sh,target=/tmp/setup-kathara.sh \
    export NETCAP_VERSION=${NETCAP_VERSION}; \
    bash /tmp/setup-kathara.sh
