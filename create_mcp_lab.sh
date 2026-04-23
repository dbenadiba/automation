#!/usr/bin/env bash
set -euo pipefail

# Use Lab on Demand 9.19.1.
# Once Grafana and all containers run, download VSCode and configure GitHub Copilot.
# Once configured add both MCP servers to Copilot:
# ONTAP MCP Server = http://<HOST_IP>:8083
# Harvest-mcp      = http://<HOST_IP>:8082

# --------------------------------------------
# Configuration (you can override via env vars)
# --------------------------------------------
CLUSTER_ADDR="${CLUSTER_ADDR:-192.168.0.101}"
CLUSTER_USER="${CLUSTER_USER:-admin}"
CLUSTER_PASS="${CLUSTER_PASS:-Netapp1!}"          # ideally: export CLUSTER_PASS=... before running
USE_INSECURE_TLS="${USE_INSECURE_TLS:-true}"

# MCP servers
ONTAP_MCP_PORT="${ONTAP_MCP_PORT:-8083}"
HARVEST_MCP_PORT="${HARVEST_MCP_PORT:-8082}"

# Files
MCP_YAML_PATH="${MCP_YAML_PATH:-/root/mcp.yaml}"
HARVEST_YML_PATH="${HARVEST_YML_PATH:-$(pwd)/harvest.yml}"
HARVEST_COMPOSE_OUT="${HARVEST_COMPOSE_OUT:-$(pwd)/harvest-compose.yml}"

# Compose stack file (prom-stack.yml must exist in current directory)
PROM_STACK_FILE="${PROM_STACK_FILE:-$(pwd)/prom-stack.yml}"

# Docker login (optional)
DO_DOCKER_LOGIN="${DO_DOCKER_LOGIN:-true}"   # true/false
DOCKER_USER="${DOCKER_USER:-dbenadib}"
DOCKER_PASS="${DOCKER_PASS:-}"               # ideally: export DOCKER_PASS=... (otherwise prompt)

# --------------------------------------------
# Helpers
# --------------------------------------------
log()  { echo -e "\n\e[1;32m[+] $*\e[0m"; }
warn() { echo -e "\n\e[1;33m[!] $*\e[0m"; }
die()  { echo -e "\n\e[1;31m[X] $*\e[0m"; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (or via sudo)."
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

detect_host_ip() {
  # Prefer the IPv4 used for the default route (most reliable on multi-NIC hosts)
  if cmd_exists ip; then
    local ipaddr
    ipaddr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    if [[ -n "${ipaddr:-}" ]]; then
      echo "${ipaddr}"
      return 0
    fi
  fi

  # Fallback
  if cmd_exists hostname; then
    local ipaddr2
    ipaddr2="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -n "${ipaddr2:-}" ]]; then
      echo "${ipaddr2}"
      return 0
    fi
  fi

  return 1
}

# Auto-detected host IP (can be overridden: export HOST_IP=...)
HOST_IP="${HOST_IP:-$(detect_host_ip || true)}"
if [[ -z "${HOST_IP}" ]]; then
  die "Unable to detect the host IP. Set it manually: export HOST_IP=x.x.x.x"
fi

# Harvest/Prometheus TSDB URL (used by harvest-mcp)
HARVEST_TSDB_URL="${HARVEST_TSDB_URL:-http://${HOST_IP}:9090}"

# --------------------------------------------
# Start
# --------------------------------------------
need_root

log "Detected host IP: ${HOST_IP} 🖥️"

log "1) Removing Podman/runc (if present)"
dnf remove -y podman || true
dnf remove -y runc || true

log "2) Installing DNF prerequisites + adding Docker repo + installing Docker"
dnf -y install dnf-plugins-core || true
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "3) Starting Docker"
systemctl enable --now docker

log "4) (Optional) Docker login (no cleartext password)"
if [[ "${DO_DOCKER_LOGIN}" == "false" ]]; then
  if [[ -z "${DOCKER_PASS}" ]]; then
    read -r -s -p "Docker password for ${DOCKER_USER}: " DOCKER_PASS
    echo
  fi
  echo "${DOCKER_PASS}" | docker login -u "${DOCKER_USER}" --password-stdin
else
  warn "Docker login disabled (DO_DOCKER_LOGIN=false)."
fi

log "5) Generating ONTAP MCP config file: ${MCP_YAML_PATH}"
cat > "${MCP_YAML_PATH}" <<EOF
Pollers:
  cluster1:
    addr: ${CLUSTER_ADDR}
    username: ${CLUSTER_USER}
    password: ${CLUSTER_PASS}
    use_insecure_tls: ${USE_INSECURE_TLS}
EOF
chmod 600 "${MCP_YAML_PATH}"

log "6) Starting (or restarting) the ONTAP MCP Server container"
docker rm -f ontap-mcp-server >/dev/null 2>&1 || true
docker run -d \
  --name ontap-mcp-server \
  -p "${ONTAP_MCP_PORT}:8083" \
  -v "${MCP_YAML_PATH}:/opt/mcp/ontap.yaml:ro" \
  ghcr.io/netapp/ontap-mcp:nightly \
  start --port 8083 --host 0.0.0.0

log "7) Generating Harvest config file: ${HARVEST_YML_PATH}"
cat > "${HARVEST_YML_PATH}" <<EOF
Exporters:
  prometheus1:
    exporter: Prometheus
    addr: 0.0.0.0
    port_range: 2000-2030

Defaults:
  collectors:
    - Zapi
    - ZapiPerf
    - EMS
  use_insecure_tls: ${USE_INSECURE_TLS}
  exporters:
    - prometheus1

Pollers:
  infinity:
    datacenter: DC-01
    addr: ${CLUSTER_ADDR}
    auth_style: basic_auth
    username: ${CLUSTER_USER}
    password: ${CLUSTER_PASS}
EOF
chmod 600 "${HARVEST_YML_PATH}"

log "8) Generating harvest-compose.yml via the Harvest container"
docker run --rm \
  --env UID="$(id -u)" --env GID="$(id -g)" \
  --entrypoint "bin/harvest" \
  --volume "$(pwd):/opt/temp" \
  --volume "${HARVEST_YML_PATH}:/opt/harvest/harvest.yml" \
  ghcr.io/netapp/harvest \
  generate docker full \
  --output "$(basename "${HARVEST_COMPOSE_OUT}")"

if [[ ! -f "${HARVEST_COMPOSE_OUT}" ]]; then
  die "harvest-compose.yml not found at expected location: ${HARVEST_COMPOSE_OUT}"
fi

log "9) Starting Prometheus/Grafana stack + Harvest pollers via docker compose"
if [[ ! -f "${PROM_STACK_FILE}" ]]; then
  warn "prom-stack.yml not found: ${PROM_STACK_FILE}"
  warn "➡️ Put prom-stack.yml in $(pwd) or export PROM_STACK_FILE=/path/to/prom-stack.yml"
  warn "Skipping docker compose up."
else
  docker compose -f "${PROM_STACK_FILE}" -f "${HARVEST_COMPOSE_OUT}" up -d --remove-orphans
fi

log "10) Deploying Harvest MCP Server (points to Prometheus/VictoriaMetrics TSDB)"
docker rm -f harvest-mcp-server >/dev/null 2>&1 || true
docker run -d \
  --name harvest-mcp-server \
  -p "${HARVEST_MCP_PORT}:8082" \
  --env "HARVEST_TSDB_URL=${HARVEST_TSDB_URL}" \
  ghcr.io/netapp/harvest-mcp:nightly \
  start --http --port 8082 --host 0.0.0.0

log "✅ Done."
echo "ONTAP MCP:   http://${HOST_IP}:${ONTAP_MCP_PORT}"
echo "Harvest MCP: http://${HOST_IP}:${HARVEST_MCP_PORT}"
echo "TSDB URL:    ${HARVEST_TSDB_URL}"
echo "MCP config:  ${MCP_YAML_PATH}"
echo "Harv config: ${HARVEST_YML_PATH}"
