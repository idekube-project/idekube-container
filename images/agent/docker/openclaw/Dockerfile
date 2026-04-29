# syntax=docker/dockerfile:1
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS system

ARG OPENCLAW_VERSION=latest

# Install openclaw gateway
RUN --mount=type=bind,source=docker/openclaw/install-scripts/setup-openclaw.sh,target=/tmp/setup-openclaw.sh \
    export OPENCLAW_VERSION=${OPENCLAW_VERSION}; bash /tmp/setup-openclaw.sh

# Add openclaw supervisor program
COPY docker/openclaw/resources/openclaw.conf /etc/supervisor/conf.d/openclaw.conf

# Add openclaw bootstrap startup hook
COPY docker/openclaw/resources/00-openclaw-bootstrap.sh /etc/idekube/startup.bash/00-openclaw-bootstrap.sh
RUN chmod +x /etc/idekube/startup.bash/00-openclaw-bootstrap.sh

# Override nginx config to add /agent location block
COPY docker/openclaw/resources/default /etc/nginx/sites-enabled/default

# Override health config for openclaw variant
COPY docker/openclaw/resources/health.json /etc/idekube/health.json
