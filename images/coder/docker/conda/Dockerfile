# syntax=docker/dockerfile:1
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS system

ARG MINICONDA_VERSION=latest

# Install Miniconda (the only addition over coder/base)
RUN --mount=type=bind,source=third_party/artifacts/install-scripts/setup-miniconda.sh,target=/tmp/setup-miniconda.sh \
    export MINICONDA_VERSION=${MINICONDA_VERSION}; bash /tmp/setup-miniconda.sh
ENV PATH=/opt/miniconda3/bin:$PATH
