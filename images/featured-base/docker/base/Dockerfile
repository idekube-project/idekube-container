# syntax=docker/dockerfile:1
# Self-contained Dockerfile: only references paths inside this image repo,
# plus BuildKit named contexts (artifacts, healthcheck-src, frontend-src)
# supplied by docker-bake.hcl.

ARG BASE_IMAGE=ubuntu:24.04

# ---------------------------------------------------------------------------
# Stage: healthcheck binary (compiled from healthcheck-src named context)
# ---------------------------------------------------------------------------
FROM golang:1.25-alpine AS healthcheck-builder
WORKDIR /build
COPY --from=healthcheck-src . .
RUN go mod download && go build -o /idekube-healthcheck .

# ---------------------------------------------------------------------------
# Stage: frontend dist (built from frontend-src named context)
# ---------------------------------------------------------------------------
FROM node:22-alpine AS frontend-builder
WORKDIR /src
COPY --from=frontend-src . .
RUN npm ci && npm run build

# ---------------------------------------------------------------------------
# Stage: system image
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS system

ARG TZ=Asia/Shanghai \
    APT_MIRROR="mirror.sjtu.edu.cn" \
    USE_APT_MIRROR="true" \
    TINI_VERSION=0.19.0 \
    WEBSOCAT_VERSION=1.13.0 \
    MINICONDA_VERSION=latest \
    CODER_VERSION=4.7.0 \
    VIRTUALGL_VERSION=3.1 \
    TURBOVNC_VERSION=3.1

# Avoid prompts for time zone
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ}

# Change APT Source
RUN if [ ${USE_APT_MIRROR} != "false" ]; then \
        sed -i s@/archive.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list && \
        sed -i s@/security.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list && \
        sed -i s@/ports.ubuntu.com/@/${APT_MIRROR}/@g /etc/apt/sources.list; \
    fi;

# built-in packages (shared script from artifacts repo)
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-packages.sh,target=/tmp/setup-packages.sh \
    bash /tmp/setup-packages.sh

# tini to fix subreap
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-tini.sh,target=/tmp/setup-tini.sh \
    export TINI_VERSION=${TINI_VERSION}; bash /tmp/setup-tini.sh

# Setup the websocat and ssh
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-websocat-ssh.sh,target=/tmp/setup-websocat-ssh.sh \
    export WEBSOCAT_VERSION=${WEBSOCAT_VERSION}; bash /tmp/setup-websocat-ssh.sh

# Setup the code-server
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-code-server.sh,target=/tmp/setup-code-server.sh \
    export CODER_VERSION=${CODER_VERSION}; bash /tmp/setup-code-server.sh

# Install Miniconda
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-miniconda.sh,target=/tmp/setup-miniconda.sh \
    export MINICONDA_VERSION=${MINICONDA_VERSION}; bash /tmp/setup-miniconda.sh
ENV PATH=/opt/miniconda3/bin:$PATH

# Setup VGL (local script)
RUN --mount=type=bind,source=docker/base/install-scripts/setup-vgl.sh,target=/tmp/setup-vgl.sh \
    bash /tmp/setup-vgl.sh
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all

# Desktop (local script)
RUN --mount=type=bind,source=docker/base/install-scripts/setup-desktop.sh,target=/tmp/setup-desktop.sh \
    bash /tmp/setup-desktop.sh

# Install the Chromium (local script)
RUN --mount=type=bind,source=docker/base/install-scripts/setup-chromium.sh,target=/tmp/setup-chromium.sh \
    bash /tmp/setup-chromium.sh

# Install TurboVNC and VirtualGL (local script)
RUN --mount=type=bind,source=docker/base/install-scripts/setup-vnc.sh,target=/tmp/setup-vnc.sh \
    bash /tmp/setup-vnc.sh
ENV PATH=$PATH:/opt/VirtualGL/bin:/opt/TurboVNC/bin \
    VGL_DISPLAY=egl \
    VNC_THREADS=2 \
    LD_PRELOAD=/usr/lib/libdlfaker.so:/usr/lib/libvglfaker.so

# noVNC
RUN git clone --depth 1 --branch v1.5.0 https://github.com/novnc/noVNC.git /var/lib/novnc && \
    git clone --depth 1 --branch v0.12.0 https://github.com/novnc/websockify.git /var/lib/novnc/utils/websockify

# Create the IDEKube user with home and bash shell
RUN --mount=type=bind,from=artifacts,source=install-scripts/setup-user.sh,target=/tmp/setup-user.sh \
    bash /tmp/setup-user.sh
ENV SHELL=/bin/bash \
    USERNAME=idekube \
    USERID=1000

# Setup the root filesystem (common rootfs from artifacts repo + flavor overrides in this repo)
COPY --from=artifacts rootfs/ /
COPY artifacts/docker/featured/rootfs /

# Frontend (Vue dist built from frontend-src named context)
COPY --from=frontend-builder /src/dist/ /usr/share/nginx/html/

# Health check server
COPY --from=healthcheck-builder /idekube-healthcheck /usr/local/bin/idekube-healthcheck

EXPOSE 80
ENTRYPOINT ["/startup.sh"]
