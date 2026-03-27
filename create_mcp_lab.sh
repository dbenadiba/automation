#!/usr/bin/env bash
set -euo pipefail
# Use Lab on Demand 9.18.1 . 
# Once grafana and all container run, download vscode and configure Github Copilot
# Once configured add both mcp servers to Copilot : 
# ONTAP MCP Server = http://192.168.0.61:8083
# Harvest-mcp = http://192.168.0.61:8082
# --------------------------------------------
# Configuration (tu peux surcharger via variables d'env)
# --------------------------------------------
CLUSTER_ADDR="${CLUSTER_ADDR:-192.168.0.101}"
CLUSTER_USER="${CLUSTER_USER:-admin}"
CLUSTER_PASS="${CLUSTER_PASS:-Netapp1!}"          # idéalement: export CLUSTER_PASS=... avant d'exécuter
USE_INSECURE_TLS="${USE_INSECURE_TLS:-true}"

# MCP servers
ONTAP_MCP_PORT="${ONTAP_MCP_PORT:-8083}"
HARVEST_MCP_PORT="${HARVEST_MCP_PORT:-8082}"

# Harvest/Prometheus TSDB URL (utilisé par harvest-mcp)
HARVEST_TSDB_URL="${HARVEST_TSDB_URL:-http://192.168.0.61:9090}"

# Files
MCP_YAML_PATH="${MCP_YAML_PATH:-/root/mcp.yaml}"
HARVEST_YML_PATH="${HARVEST_YML_PATH:-$(pwd)/harvest.yml}"
HARVEST_COMPOSE_OUT="${HARVEST_COMPOSE_OUT:-$(pwd)/harvest-compose.yml}"

# Compose stack file (prom-stack.yml doit exister dans le répertoire courant)
PROM_STACK_FILE="${PROM_STACK_FILE:-$(pwd)/prom-stack.yml}"

# Docker login (optionnel)
DO_DOCKER_LOGIN="${DO_DOCKER_LOGIN:-false}"   # true/false
DOCKER_USER="${DOCKER_USER:-dbenadib}"
DOCKER_PASS="${DOCKER_PASS:-}"               # idéalement: export DOCKER_PASS=... (sinon prompt)

# --------------------------------------------
# Helpers
# --------------------------------------------
log() { echo -e "\n\e[1;32m[+] $*\e[0m"; }
warn() { echo -e "\n\e[1;33m[!] $*\e[0m"; }
die() { echo -e "\n\e[1;31m[X] $*\e[0m"; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Ce script doit être exécuté en root (ou via sudo)."
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------
# Start
# --------------------------------------------
need_root

log "1) Suppression Podman/runc (si présents)"
dnf remove -y podman || true
dnf remove -y runc || true

log "2) Installation des prérequis DNF + ajout repo Docker + installation Docker"
dnf -y install dnf-plugins-core || true
# Sur RHEL, la doc Docker recommande le repo rhel (tu utilisais centos; je garde rhel par défaut)
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "3) Démarrage Docker"
systemctl enable --now docker

log "4) (Optionnel) Docker login (sans mot de passe en clair)"
if [[ "${DO_DOCKER_LOGIN}" == "true" ]]; then
  if [[ -z "${DOCKER_PASS}" ]]; then
    # prompt silencieux
    read -r -s -p "Docker password for ${DOCKER_USER}: " DOCKER_PASS
    echo
  fi
  echo "${DOCKER_PASS}" | docker login -u "${DOCKER_USER}" --password-stdin
else
  warn "Docker login désactivé (DO_DOCKER_LOGIN=false)."
fi

log "5) Génération du fichier de config ONTAP MCP: ${MCP_YAML_PATH}"
cat > "${MCP_YAML_PATH}" <<EOF
Pollers:
  cluster1:
    addr: ${CLUSTER_ADDR}
    username: ${CLUSTER_USER}
    password: ${CLUSTER_PASS}
    use_insecure_tls: ${USE_INSECURE_TLS}
EOF
chmod 600 "${MCP_YAML_PATH}"

log "6) Lancement (ou redémarrage) du conteneur ONTAP MCP Server"
# Commande conforme à la doc ONTAP-MCP (mount vers /opt/mcp/ontap.yaml) [1](https://netapp.github.io/ontap-mcp/nightly/install/)
docker rm -f ontap-mcp-server >/dev/null 2>&1 || true
docker run -d \
  --name ontap-mcp-server \
  -p "${ONTAP_MCP_PORT}:8083" \
  -v "${MCP_YAML_PATH}:/opt/mcp/ontap.yaml:ro" \
  ghcr.io/netapp/ontap-mcp:nightly \
  start --port 8083 --host 0.0.0.0

log "7) Génération du fichier de config Harvest: ${HARVEST_YML_PATH}"
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

log "8) Génération de harvest-compose.yml via le conteneur Harvest"
# Commande conforme à la doc Harvest (docker run --entrypoint bin/harvest ... generate docker full) [2](https://netapp.github.io/harvest/23.05/install/containers/)
docker run --rm \
  --env UID="$(id -u)" --env GID="$(id -g)" \
  --entrypoint "bin/harvest" \
  --volume "$(pwd):/opt/temp" \
  --volume "${HARVEST_YML_PATH}:/opt/harvest/harvest.yml" \
  ghcr.io/netapp/harvest \
  generate docker full \
  --output "$(basename "${HARVEST_COMPOSE_OUT}")"

# Le generate écrit dans /opt/temp => donc dans $(pwd)
if [[ ! -f "${HARVEST_COMPOSE_OUT}" ]]; then
  die "harvest-compose.yml non trouvé à l'emplacement attendu: ${HARVEST_COMPOSE_OUT}"
fi

log "9) Lancement de la stack Prometheus/Grafana + Harvest pollers via docker compose"
if [[ ! -f "${PROM_STACK_FILE}" ]]; then
  warn "Le fichier prom-stack.yml est introuvable: ${PROM_STACK_FILE}"
  warn "➡️ Place prom-stack.yml dans $(pwd) ou export PROM_STACK_FILE=/chemin/prom-stack.yml"
  warn "Je saute l'étape docker compose up."
else
  docker compose -f "${PROM_STACK_FILE}" -f "${HARVEST_COMPOSE_OUT}" up -d --remove-orphans
fi

log "10) Déploiement Harvest MCP Server (pointe vers la TSDB Prometheus/VictoriaMetrics)"
docker rm -f harvest-mcp-server >/dev/null 2>&1 || true
docker run -d \
  --name harvest-mcp-server \
  -p "${HARVEST_MCP_PORT}:8082" \
  --env "HARVEST_TSDB_URL=${HARVEST_TSDB_URL}" \
  ghcr.io/netapp/harvest-mcp:nightly \
  start --http --port 8082 --host 0.0.0.0

log "✅ Terminé."
echo "ONTAP MCP:   http://<host>:${ONTAP_MCP_PORT}"
echo "Harvest MCP: http://<host>:${HARVEST_MCP_PORT}"
echo "Config MCP:  ${MCP_YAML_PATH}"
echo "Config Harv: ${HARVEST_YML_PATH}"
