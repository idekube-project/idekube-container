# syntax=docker/dockerfile:1
# Self-contained Dockerfile: only references paths inside this image repo,
# plus BuildKit named contexts (artifacts, healthcheck-src, frontend-src)
# supplied by docker-bake.hcl.

ARG BASE_IMAGE=ubuntu:24.04

FROM golang:1.25-alpine AS healthcheck-builder
WORKDIR /build
COPY --from=healthcheck-src . .
RUN go mod download && go build -o /idekube-healthcheck .

FROM node:22-alpine AS frontend-builder
WORKDIR /src
COPY --from=frontend-src . .
RUN npm ci && npm run build

FROM ${BASE_IMAGE} AS system

ARG TZ=Asia/Shanghai \
    WEBSOCAT_VERSION=1.13.0 \
    APT_MIRROR="mirror.sjtu.edu.cn" \
    USE_APT_MIRROR="false" \
    TINI_VERSION=0.19.0 \
    MINICONDA_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ}

# Change APT Source
RUN if [ ${USE_APT_MIRROR} != "false" ]; then \
        sed -i s@/archive.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list && \
        sed -i s@/security.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list && \
        sed -i s@/ports.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list; \
    fi;

# built-in packages
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-packages.sh,target=/tmp/setup-packages.sh \
    bash /tmp/setup-packages.sh

# tini to fix subreap
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-tini.sh,target=/tmp/setup-tini.sh \
    export TINI_VERSION=${TINI_VERSION}; bash /tmp/setup-tini.sh

# Setup the websocat and ssh
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-websocat-ssh.sh,target=/tmp/setup-websocat-ssh.sh \
    export WEBSOCAT_VERSION=${WEBSOCAT_VERSION}; bash /tmp/setup-websocat-ssh.sh

# Install Miniconda
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-miniconda.sh,target=/tmp/setup-miniconda.sh \
    export MINICONDA_VERSION=${MINICONDA_VERSION}; bash /tmp/setup-miniconda.sh
ENV PATH=/opt/miniconda3/bin:$PATH

# Install JupyterLab
RUN python3 -m pip install --no-cache-dir jupyterlab \
    jupyterlab-git jupyterlab-drawio jupyterlab-language-pack-zh-CN

RUN mkdir -p /usr/local/share/jupyter/lab/settings && \
    echo '{"@jupyterlab/apputils-extension:notification":{"fetchNews":"false"},"@jupyterlab/apputils-extension:announcements":{"checkForUpdates":false}}' > /usr/local/share/jupyter/lab/settings/overrides.json

# Create the IDEKube user with home and bash shell
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-user.sh,target=/tmp/setup-user.sh \
    bash /tmp/setup-user.sh
ENV SHELL=/bin/bash \
    USERNAME=idekube \
    USERID=1000

# Setup the root filesystem (common rootfs + flavor overrides)
COPY --from=artifacts rootfs/ /
COPY artifacts/docker/jupyter/rootfs /

# Frontend
COPY --from=frontend-builder /src/dist/ /usr/share/nginx/html/

# Health check server
COPY --from=healthcheck-builder /idekube-healthcheck /usr/local/bin/idekube-healthcheck

EXPOSE 80
ENTRYPOINT ["/startup.sh"]
