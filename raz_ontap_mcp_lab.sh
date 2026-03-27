#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------
# Paramètres (override via env)
# ----------------------------------
PURGE_DOCKER_DATA="${PURGE_DOCKER_DATA:-false}"   # true => supprime /var/lib/docker et /var/lib/containerd
PROM_STACK_FILE="${PROM_STACK_FILE:-$(pwd)/prom-stack.yml}"
HARVEST_COMPOSE_FILE="${HARVEST_COMPOSE_FILE:-$(pwd)/harvest-compose.yml}"

log()  { echo -e "\n\e[1;32m[+] $*\e[0m"; }
warn() { echo -e "\n\e[1;33m[!] $*\e[0m"; }
die()  { echo -e "\n\e[1;31m[X] $*\e[0m"; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Ce script doit être exécuté en root (ou via sudo)."
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

need_root

# ----------------------------------
# 1) Arrêt / suppression conteneurs
# ----------------------------------
log "1) Arrêt/suppression des conteneurs spécifiques"
if cmd_exists docker; then
  docker rm -f ontap-mcp-server >/dev/null 2>&1 || true
  docker rm -f harvest-mcp-server >/dev/null 2>&1 || true
else
  warn "docker CLI non présent — je saute la suppression des conteneurs."
fi

# ----------------------------------
# 2) docker compose down si possible
# ----------------------------------
log "2) Down docker compose (si fichiers présents)"
if cmd_exists docker; then
  if [[ -f "${PROM_STACK_FILE}" && -f "${HARVEST_COMPOSE_FILE}" ]]; then
    docker compose -f "${PROM_STACK_FILE}" -f "${HARVEST_COMPOSE_FILE}" down --remove-orphans || true
  elif [[ -f "${HARVEST_COMPOSE_FILE}" ]]; then
    docker compose -f "${HARVEST_COMPOSE_FILE}" down --remove-orphans || true
  else
    warn "Aucun fichier compose détecté (${HARVEST_COMPOSE_FILE} / ${PROM_STACK_FILE})."
  fi
else
  warn "docker CLI non présent — je saute docker compose down."
fi

# ----------------------------------
# 3) Stop/disable service docker
# ----------------------------------
log "3) Stop/disable du service Docker"
if cmd_exists systemctl; then
  systemctl stop docker >/dev/null 2>&1 || true
  systemctl disable docker >/dev/null 2>&1 || true
fi

# ----------------------------------
# 4) Désinstallation docker via dnf
# ----------------------------------
log "4) Désinstallation Docker (dnf remove)"
dnf remove -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras \
  >/dev/null 2>&1 || true

# Paquets docker historiques / alternatifs (au cas où)
dnf remove -y \
  docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine \
  >/dev/null 2>&1 || true

# ----------------------------------
# 5) Suppression repo Docker si présent
# ----------------------------------
log "5) Suppression du repo Docker (si présent)"
if [[ -f /etc/yum.repos.d/docker-ce.repo ]]; then
  rm -f /etc/yum.repos.d/docker-ce.repo
  log "Repo supprimé: /etc/yum.repos.d/docker-ce.repo"
else
  warn "Repo docker-ce.repo non trouvé (rien à supprimer)."
fi

# ----------------------------------
# 6) Suppression fichiers de conf (si présents)
# ----------------------------------
log "6) Nettoyage fichiers de configuration"
for f in /root/mcp.yaml "$(pwd)/harvest.yml" "${HARVEST_COMPOSE_FILE}"; do
  if [[ -e "$f" ]]; then
    rm -f "$f"
    log "Supprimé: $f"
  fi
done

# ----------------------------------
# 7) Purge data docker (optionnelle)
# ----------------------------------
log "7) Purge des données Docker (optionnel)"
if [[ "${PURGE_DOCKER_DATA}" == "true" ]]; then
  warn "PURGE_DOCKER_DATA=true => suppression DESTRUCTIVE de /var/lib/docker et /var/lib/containerd"
  rm -rf /var/lib/docker /var/lib/containerd || true
  log "Données Docker purgées."
else
  warn "PURGE_DOCKER_DATA=false => je conserve /var/lib/docker et /var/lib/containerd."
  warn "Pour tout effacer: sudo PURGE_DOCKER_DATA=true $0"
fi

# ----------------------------------
# 8) Nettoyage final
# ----------------------------------
log "8) Nettoyage final dnf"
dnf autoremove -y >/dev/null 2>&1 || true
dnf clean all >/dev/null 2>&1 || true

log "✅ Reset terminé."
``
