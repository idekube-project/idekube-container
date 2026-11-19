# syntax=docker/dockerfile:1
ARG BASE_IMAGE=base-image
FROM ${BASE_IMAGE} AS system

ARG HERMES_VERSION=v0.23.2 \
    UV_VERSION=0.13.9

# Install Hermes Agent (+ ripgrep, uv); see setup-hermes.sh for the layout
RUN --mount=type=bind,source=docker/hermes/install-scripts/setup-hermes.sh,target=/tmp/setup-hermes.sh \
    export HERMES_VERSION=${HERMES_VERSION} UV_VERSION=${UV_VERSION}; bash /tmp/setup-hermes.sh

# Supervisor program (hermes gateway with embedded API server)
COPY docker/hermes/resources/hermes-gateway.conf /etc/supervisor/conf.d/hermes-gateway.conf

# Startup bootstrap hook
COPY docker/hermes/resources/00-hermes-bootstrap.sh /etc/idekube/startup.bash/00-hermes-bootstrap.sh
RUN chmod +x /etc/idekube/startup.bash/00-hermes-bootstrap.sh
