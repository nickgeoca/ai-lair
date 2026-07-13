#!/usr/bin/env bash
# Run Hermes with staged datasets and no general Internet route. HERMES_REPO
# may name one disposable clone to mount writable at /workspace/repo.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
NETWORK=hermes-analysis
GATEWAY=hermes-llm-gateway
GATEWAY_IMAGE='docker.io/library/nginx@sha256:0d3b80406a13a767339fbe2f41406d6c7da727ab89cf8fae399e81f780f814d1'
HERMES_IMAGE=hermes-agent:v2026.7.1
ENV_FILE="$HERE/data/.env"
TEMPLATE="$HERE/gateway/openrouter.conf.template"

if ! grep -q '^OPENROUTER_API_KEY=' "$ENV_FILE" 2>/dev/null; then
  echo "OPENROUTER_API_KEY is missing from $ENV_FILE" >&2
  exit 1
fi

if ! podman network exists "$NETWORK"; then
  podman network create --internal "$NETWORK" >/dev/null
fi
if [ "$(podman network inspect -f '{{.Internal}}' "$NETWORK")" != "true" ]; then
  echo "refusing non-internal Podman network: $NETWORK" >&2
  exit 1
fi
if podman container exists "$GATEWAY"; then
  echo "container already exists: $GATEWAY" >&2
  exit 1
fi

cleanup() {
  podman stop --time 2 "$GATEWAY" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

podman run --detach --rm --pull=never \
  --name "$GATEWAY" \
  --network podman \
  --network "$NETWORK" \
  --dns 1.1.1.1 \
  --env-file "$ENV_FILE" \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  --cap-add=CHOWN \
  --cap-add=SETGID \
  --cap-add=SETUID \
  --pids-limit=128 \
  --memory=128m \
  --cpus=1 \
  --read-only \
  --tmpfs /etc/nginx/conf.d:rw,noexec,nosuid,nodev,size=1m \
  --tmpfs /var/cache/nginx:rw,noexec,nosuid,nodev,size=16m \
  --tmpfs /var/run:rw,noexec,nosuid,nodev,size=1m \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1m \
  -v "$TEMPLATE:/etc/nginx/templates/default.conf.template:ro" \
  "$GATEWAY_IMAGE" >/dev/null

for _ in $(seq 1 30); do
  if podman exec "$GATEWAY" wget -q --spider http://127.0.0.1:8080/health; then
    break
  fi
  sleep 0.2
done
if ! podman exec "$GATEWAY" wget -q --spider http://127.0.0.1:8080/health; then
  podman logs "$GATEWAY" >&2
  exit 1
fi

if [ "${1:-}" = "--check" ]; then
  podman run --rm --pull=never \
    --network "$NETWORK" \
    --user 1000:100 \
    --cap-drop=ALL \
    --entrypoint /opt/hermes/.venv/bin/python \
    "$HERMES_IMAGE" -c '
import socket
import urllib.error
import urllib.request

assert urllib.request.urlopen("http://hermes-llm-gateway:8080/health").status == 204

request = urllib.request.Request(
    "http://hermes-llm-gateway:8080/api/v1/models",
    headers={"Authorization": "Bearer gateway-injects-the-real-key"},
)
with urllib.request.urlopen(request) as response:
    assert response.status == 200

try:
    urllib.request.urlopen("http://hermes-llm-gateway:8080/forbidden")
except urllib.error.HTTPError as exc:
    assert exc.code == 403
else:
    raise SystemExit("gateway accepted a forbidden path")

try:
    socket.getaddrinfo("example.com", 443)
except socket.gaierror:
    pass
else:
    raise SystemExit("unexpected external DNS resolution")

for host in ("1.1.1.1", "93.184.216.34"):
    sock = socket.socket()
    sock.settimeout(1)
    try:
        sock.connect((host, 443))
    except OSError:
        pass
    else:
        raise SystemExit(f"unexpected external route to {host}")
    finally:
        sock.close()

print("approved LLM route works; external DNS/IP and forbidden paths are blocked")
'
  exit 0
fi

HERMES_ANALYSIS=1 "$HERE/run.sh" "$@"
