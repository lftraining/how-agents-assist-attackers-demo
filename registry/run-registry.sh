#!/usr/bin/env bash
# run-registry.sh — start the local registry that holds the signed skill. `make setup` runs
# it, and it is safe to re-run. The registry listens on 127.0.0.1 only, on its own network.
set -euo pipefail
# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"

require_set REGISTRY_IMAGE
CONF_DIR="${REPO_ROOT}/${REGISTRY_RUNTIME_DIR}"
# The TLS private key lives outside the repo, like every other key.
TLS_DIR="${DEMO_SECRETS_DIR}/registry-tls"
CA_CRT="${CONF_DIR}/ca.crt"
BUNDLE="${REPO_ROOT}/${REGISTRY_CA_BUNDLE}"
mkdir -p "$CONF_DIR" "$TLS_DIR"
chmod 0700 "$TLS_DIR"

# --- TLS: a certificate signed by a throwaway CA, whose private key is then deleted --------
need_cert=0
if [ ! -s "${TLS_DIR}/server.crt" ] || [ ! -s "${TLS_DIR}/server.key" ] || [ ! -s "$CA_CRT" ]; then
  need_cert=1
elif ! openssl x509 -checkend $((30*24*3600)) -noout -in "${TLS_DIR}/server.crt" >/dev/null; then
  need_cert=1   # expires within 30 days: renew now, not mid-run
fi
if [ "$need_cert" = 1 ]; then
  echo ">> generating loopback TLS cert for the registry (localhost, 127.0.0.1)"
  work="$(mktemp -d)"
  ( umask 077
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
      -subj "/CN=agents-assist-attackers local registry CA (throwaway)" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" \
      -keyout "${work}/ca.key" -out "${work}/ca.crt" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -subj "/CN=localhost" -keyout "${work}/server.key" -out "${work}/server.csr" 2>/dev/null
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' > "${work}/ext"
    openssl x509 -req -in "${work}/server.csr" -CA "${work}/ca.crt" -CAkey "${work}/ca.key" \
      -CAcreateserial -days 825 -extfile "${work}/ext" -out "${work}/server.crt" 2>/dev/null )
  install -m 0600 "${work}/server.key" "${TLS_DIR}/server.key"
  install -m 0644 "${work}/server.crt" "${TLS_DIR}/server.crt"
  install -m 0644 "${work}/ca.crt" "$CA_CRT"
  rm -rf "$work"   # takes the CA private key with it
  CERT_CHANGED=1
else
  CERT_CHANGED=0
fi
# Combine the system CA roots with the throwaway CA.
sys_roots=""
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem; do
  if [ -s "$f" ]; then sys_roots="$f"; break; fi
done
[ -n "$sys_roots" ] || { echo "FATAL no system CA bundle found (looked in the Debian, Fedora and openSUSE locations)" >&2; exit 1; }
cat "$sys_roots" "$CA_CRT" > "${BUNDLE}.tmp" && mv "${BUNDLE}.tmp" "$BUNDLE"

# --- network -------------------------------------------------------------------------
if ! docker network inspect "$REGISTRY_NETWORK" >/dev/null 2>&1; then
  echo ">> creating Docker network ${REGISTRY_NETWORK} (registry only; no IP masquerade = no egress)"
  docker network create -o com.docker.network.bridge.enable_ip_masquerade=false "$REGISTRY_NETWORK" >/dev/null
fi
masq="$(docker network inspect -f '{{index .Options "com.docker.network.bridge.enable_ip_masquerade"}}' "$REGISTRY_NETWORK")"
[ "$masq" = "false" ] || { echo "FATAL network ${REGISTRY_NETWORK} exists without masquerade=false — not ours; pick another REGISTRY_NETWORK" >&2; exit 1; }

# --- container -----------------------------------------------------------------------
state="$(docker inspect -f '{{.State.Status}}' "$REGISTRY_NAME" 2>/dev/null || true)"
if [ -n "$state" ]; then
  # An existing container must match this script's image, mounts, and network.
  have="$(docker inspect -f '{{.Config.Image}}' "$REGISTRY_NAME")"
  mnt="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/tls"}}{{.Source}}{{end}}{{end}}' "$REGISTRY_NAME")"
  vol="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Name}}{{end}}{{end}}' "$REGISTRY_NAME")"
  nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$REGISTRY_NAME")"
  if [ "${have##*@}" != "${REGISTRY_IMAGE##*@}" ] || [ "$mnt" != "$TLS_DIR" ] || [ "$vol" != "$REGISTRY_VOLUME" ] \
     || [ "${nets% }" != "$REGISTRY_NETWORK" ]; then
    echo "FATAL container '${REGISTRY_NAME}' exists but does not match this script" >&2
    echo "      (image ${have##*@}, tls mount '${mnt:-none}', volume '${vol:-none}', networks '${nets% }';" >&2
    echo "       want ${REGISTRY_IMAGE##*@}, ${TLS_DIR}, ${REGISTRY_VOLUME}, ${REGISTRY_NETWORK})." >&2
    echo "      Not replacing it automatically. Removing the container keeps its volume:" >&2
    echo "      docker rm -f ${REGISTRY_NAME} && re-run this script." >&2
    exit 1
  fi
  if [ "$state" != "running" ]; then
    echo ">> starting existing registry container ${REGISTRY_NAME}"
    docker start "$REGISTRY_NAME" >/dev/null
  elif [ "$CERT_CHANGED" = 1 ]; then
    echo ">> registry cert renewed — restarting ${REGISTRY_NAME} to load it"
    docker restart "$REGISTRY_NAME" >/dev/null
  else
    echo ">> registry ${REGISTRY_NAME} already running (${REGISTRY_IMAGE##*@})"
  fi
else
  echo ">> starting registry ${REGISTRY_NAME} on https://localhost:${REGISTRY_PORT} (${REGISTRY_IMAGE})"
  # Pull the pinned image first.
  docker image inspect "$REGISTRY_IMAGE" >/dev/null 2>&1 || docker pull "$REGISTRY_IMAGE"
  # Never on the kind network. Deletes stay disabled.
  docker run -d --name "$REGISTRY_NAME" \
    --restart unless-stopped \
    --network "$REGISTRY_NETWORK" \
    -p "127.0.0.1:${REGISTRY_PORT}:${REGISTRY_CONTAINER_PORT}" \
    -v "${REGISTRY_VOLUME}:/var/lib/registry" \
    -v "${TLS_DIR}:/tls:ro" \
    -e "REGISTRY_HTTP_ADDR=0.0.0.0:${REGISTRY_CONTAINER_PORT}" \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/tls/server.crt \
    -e REGISTRY_HTTP_TLS_KEY=/tls/server.key \
    -e REGISTRY_LOG_LEVEL=warn \
    -e OTEL_TRACES_EXPORTER=none \
    "$REGISTRY_IMAGE" >/dev/null
fi

# --- Wait until the registry answers over HTTPS ---------------------------------------
base="https://localhost:${REGISTRY_PORT}"
ok=0
for _ in $(seq 1 60); do
  if curl --cacert "$CA_CRT" -fsS -o /dev/null "${base}/v2/" 2>/dev/null; then ok=1; break; fi
  sleep 0.5   # poll interval, at most 30 seconds in total
done
if [ "$ok" != 1 ]; then
  echo "FATAL registry did not answer ${base}/v2/ within 30 s" >&2
  docker logs --tail 20 "$REGISTRY_NAME" >&2
  exit 1
fi
echo "PASS  registry up at https://${REGISTRY} (TLS, published on 127.0.0.1 only, network ${REGISTRY_NETWORK}, ${REGISTRY_IMAGE##*@})"
