# Reuse idekube-qemu-engine as the base: it already ships the pinned QEMU
# build, cloud-localds, UEFI blobs, cloud-init templates, and /run.sh +
# /startup.sh from artifacts/startup-scripts/. This image only layers
# the provisioned root disk on top and flips the entrypoint from the engine's
# debug shell to /startup.sh.
ARG ENGINE_IMAGE=idekube-qemu-engine:latest
FROM ${ENGINE_IMAGE} AS runtime

WORKDIR /var/lib/idekube/
COPY root.img ./images/root.img

WORKDIR /var/lib/data
ENTRYPOINT [ "/startup.sh" ]
