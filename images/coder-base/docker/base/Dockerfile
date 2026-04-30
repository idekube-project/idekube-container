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
    APT_MIRROR="mirror.sjtu.edu.cn" \
    USE_APT_MIRROR="true" \
    TINI_VERSION=0.19.0 \
    WEBSOCAT_VERSION=1.13.0 \
    CODER_VERSION=4.7.0

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ}

# Change APT Source
RUN if [ ${USE_APT_MIRROR} != "false" ]; then \
        sed -i s@/archive.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list && \
        sed -i s@/security.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list && \
        sed -i s@/ports.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list; \
    fi;

# built-in packages (lite variant)
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-packages-lite.sh,target=/tmp/setup-packages-lite.sh \
    bash /tmp/setup-packages-lite.sh

# tini to fix subreap (lite)
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-tini-lite.sh,target=/tmp/setup-tini-lite.sh \
    export TINI_VERSION=${TINI_VERSION}; bash /tmp/setup-tini-lite.sh

# Setup the websocat and ssh
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-websocat-ssh.sh,target=/tmp/setup-websocat-ssh.sh \
    export WEBSOCAT_VERSION=${WEBSOCAT_VERSION}; bash /tmp/setup-websocat-ssh.sh

# Setup the code-server
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-code-server.sh,target=/tmp/setup-code-server.sh \
    export CODER_VERSION=${CODER_VERSION}; bash /tmp/setup-code-server.sh

# Create the IDEKube user with home and bash shell
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-user.sh,target=/tmp/setup-user.sh \
    bash /tmp/setup-user.sh
ENV SHELL=/bin/bash \
    USERNAME=idekube \
    USERID=1000

# Setup the root filesystem (common rootfs + flavor overrides)
COPY --from=artifacts rootfs/ /
COPY artifacts/docker/coder/rootfs /

# Frontend
COPY --from=frontend-builder /src/dist/ /usr/share/nginx/html/

# Health check server
COPY --from=healthcheck-builder /idekube-healthcheck /usr/local/bin/idekube-healthcheck

EXPOSE 80
ENTRYPOINT ["/startup.sh"]
