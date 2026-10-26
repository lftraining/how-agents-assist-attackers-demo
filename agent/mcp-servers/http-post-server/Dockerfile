# MCP server image. The base image is pinned by digest and the packages by version.
FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1

# The MCP Python SDK and an HTTP client.
RUN pip install --no-cache-dir "mcp==2.3.0" "httpx==0.28.1"

# Skip .pyc files.
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080

# Run as a non-root user.
RUN useradd -r -u 10002 -g nogroup mcp
USER 10002

WORKDIR /app
COPY server.py /app/server.py
EXPOSE 8080
ENTRYPOINT ["python", "/app/server.py"]
