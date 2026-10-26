# goose-image/Dockerfile — the goose agent image. The base image is pinned by digest and
# goose by release and checksum. The model key is never in the image.

# --- Builder: download goose and check its checksum ---------------------------------------
FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1 AS builder
ARG GOOSE_VERSION=v1.54.0
# The sha256 checksum of the goose release archive for GOOSE_VERSION.
ARG GOOSE_SHA256=bf01cb6359f7a2b1acb54ca4827e1d059b18aabb3d2b75202e21066cfd3a3396
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl bzip2 \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/goose.tar.bz2 \
      "https://github.com/block/goose/releases/download/${GOOSE_VERSION}/goose-x86_64-unknown-linux-gnu.tar.bz2" \
 && echo "${GOOSE_SHA256}  /tmp/goose.tar.bz2" | sha256sum -c - \
 && tar -xjf /tmp/goose.tar.bz2 -C /tmp \
 && install -m 0755 /tmp/goose /usr/local/bin/goose \
 && /usr/local/bin/goose --version

# --- Runtime: minimal and non-root ------------------------------------------------------
FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1
# CA certificates for the HTTPS connection to the model API.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/bin/goose /usr/local/bin/goose

# The UID matches GOOSE_UID in demo.env.
RUN useradd -r -u 10001 -g nogroup -m -d /home/goose goose
ENV HOME=/home/goose
# No keyring, no telemetry, and auto mode, so the run never waits for approval.
ENV GOOSE_DISABLE_KEYRING=1 \
    GOOSE_TELEMETRY_ENABLED=false \
    GOOSE_MODE=auto \
    PYTHONDONTWRITEBYTECODE=1
USER 10001
WORKDIR /home/goose
ENTRYPOINT ["goose"]
