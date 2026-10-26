# Dockerfile — the collector: a local listener that prints each POST body it receives
# (`docker logs collector`). It publishes no port on your machine, makes no outbound
# connections, and never logs request headers. The base image is pinned by digest.
FROM python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258

WORKDIR /app
COPY listener.py /app/listener.py

# Run as a non-root user.
USER nobody

ENTRYPOINT ["python3", "-u", "/app/listener.py"]
