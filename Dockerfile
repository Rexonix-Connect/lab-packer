ARG PACKER_VERSION=light-1.10.1
ARG PACKER_IMAGE_DIGEST=sha256:f4d956671d79a2173a62ccfac261b611ea7cde8e8da30971b9dfb294fd960b16
FROM hashicorp/packer:${PACKER_VERSION}@${PACKER_IMAGE_DIGEST}

ARG GITHUB_REPOSITORY
ARG IMAGE_CREATED
ARG IMAGE_VERSION=v0.0.2
ARG PACKER_VERSION
ARG PACKER_IMAGE_DIGEST

RUN apk add --no-cache ansible=8.6.1-r0 py-pip=23.3.1-r0 openssh=9.6_p1-r2
COPY requirements.txt /tmp/requirements.txt
RUN pip install --require-hashes --only-binary=:all: --no-cache-dir --break-system-packages -r /tmp/requirements.txt

LABEL org.opencontainers.image.title="lab-packer" \
	org.opencontainers.image.description="Hashicorp Packer image for VM template creation in vCenter using self-hosted runners" \
	org.opencontainers.image.url="https://github.com/${GITHUB_REPOSITORY}" \
	org.opencontainers.image.source="https://github.com/${GITHUB_REPOSITORY}" \
	org.opencontainers.image.version="${IMAGE_VERSION}" \
	org.opencontainers.image.created="${IMAGE_CREATED}" \
	org.opencontainers.image.base.name="docker.io/hashicorp/packer:${PACKER_VERSION}" \
	org.opencontainers.image.base.digest="${PACKER_IMAGE_DIGEST}"

ENTRYPOINT ["/bin/packer"]
