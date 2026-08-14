#!/usr/bin/env bash
# lib/common.sh — utilidades propias de pi-homeassistant-setup: logging,
# dry-run, guards y estado. Librería autocontenida de ESTE proyecto: se carga
# con `source`, nunca se ejecuta, y no depende de ningún otro repositorio.

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: lib/common.sh es una librería; cárgala con 'source', no la ejecutes." >&2
  exit 64
fi

# ---------------------------------------------------------------------------
# Configuración (todo sobreescribible por variable de entorno)
# ---------------------------------------------------------------------------
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${SKIP_HARDENING:=0}"
# Contenedor de Home Assistant:
: "${HA_CONTAINER_NAME:=homeassistant}"
: "${HA_IMAGE:=ghcr.io/home-assistant/home-assistant:stable}"
: "${HA_TZ:=America/Santiago}"
: "${HA_PORT:=8123}"
: "${HA_BASE_DIR:=/opt/homeassistant}"
: "${HA_CONFIG_DIR:=${HA_BASE_DIR}/config}"
# Rotación de logs de Docker (30-hardening-sd.sh):
: "${DOCKER_LOG_MAX_SIZE:=10m}"
: "${DOCKER_LOG_MAX_FILE:=3}"
# Recorder de ejemplo (30-hardening-sd.sh):
: "${RECORDER_PURGE_KEEP_DAYS:=7}"
: "${STATE_FILE:=/var/lib/pi-homeassistant-setup/state}"

export DRY_RUN ASSUME_YES SKIP_HARDENING
export HA_CONTAINER_NAME HA_IMAGE HA_TZ HA_PORT HA_BASE_DIR HA_CONFIG_DIR
export DOCKER_LOG_MAX_SIZE DOCKER_LOG_MAX_FILE RECORDER_PURGE_KEEP_DAYS
export STATE_FILE

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  _c_red=$'\e[31m'; _c_green=$'\e[32m'; _c_yellow=$'\e[33m'
  _c_blue=$'\e[34m'; _c_dim=$'\e[2m'; _c_reset=$'\e[0m'
else
  _c_red=""; _c_green=""; _c_yellow=""; _c_blue=""; _c_dim=""; _c_reset=""
fi

log_info() { printf '%s[INFO]%s  %s\n' "${_c_blue}" "${_c_reset}" "$*" >&2; }
log_ok()   { printf '%s[OK]%s    %s\n' "${_c_green}" "${_c_reset}" "$*" >&2; }
log_warn() { printf '%s[AVISO]%s %s\n' "${_c_yellow}" "${_c_reset}" "$*" >&2; }
log_error(){ printf '%s[ERROR]%s %s\n' "${_c_red}" "${_c_reset}" "$*" >&2; }
log_dry()  { printf '%s[DRY]%s   %s\n' "${_c_dim}" "${_c_reset}" "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# Dry-run
# ---------------------------------------------------------------------------
# run CMD ARGS... — ejecuta, o solo muestra con DRY_RUN=1. Úsalo únicamente
# con comandos que MODIFICAN el sistema; la detección se ejecuta siempre.
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "$(printf '%q ' "$@")"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      die "Falta el comando requerido: ${cmd}."
    fi
  done
}

require_root() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Este script necesita privilegios de root. Vuelve a ejecutarlo con sudo."
  fi
}

confirm() {
  local prompt="${1:-¿Continuar?}"
  local reply
  if [[ "${ASSUME_YES}" == "1" ]]; then
    log_info "${prompt} — respondido automáticamente con 'sí' (--yes)."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log_error "Sesión no interactiva y sin --yes: no puedo pedir confirmación."
    return 1
  fi
  read -r -p "${prompt} [s/N] " reply
  [[ "${reply}" =~ ^[sSyY]$ ]]
}

# ---------------------------------------------------------------------------
# Estado (pasos completados entre ejecuciones)
# ---------------------------------------------------------------------------
state_mark() {
  local step="${1:?falta el nombre del paso}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  if ! mkdir -p "$(dirname "${STATE_FILE}")" 2>/dev/null; then
    log_warn "No pude escribir el estado en ${STATE_FILE}; continúo sin registrarlo."
    return 0
  fi
  touch "${STATE_FILE}"
  if ! grep -qxF "${step}" "${STATE_FILE}"; then
    echo "${step}" >>"${STATE_FILE}"
  fi
}

state_done() {
  local step="${1:?falta el nombre del paso}"
  [[ -f "${STATE_FILE}" ]] && grep -qxF "${step}" "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Red y detecciones compartidas
# ---------------------------------------------------------------------------
# port_listening PUERTO — 0 si algo escucha en TCP en ese puerto.
port_listening() {
  local port="${1:?falta el puerto}"
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
}

# http_responds PUERTO — 0 si un servidor HTTP local responde (cualquier
# código HTTP cuenta; un 302 de HA es un servidor vivo).
http_responds() {
  local port="${1:?falta el puerto}"
  local code
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/" || true)"
  [[ -n "${code}" && "${code}" != "000" ]]
}

# docker_ready — 0 si docker está instalado y el daemon responde.
docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# ha_container_exists / ha_container_running — estado del contenedor de HA.
ha_container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "${HA_CONTAINER_NAME}"
}

ha_container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "${HA_CONTAINER_NAME}"
}

# print_server_present — 0 si esta máquina tiene CUPS instalado (el servidor
# de impresión que este proyecto tiene PROHIBIDO degradar).
print_server_present() {
  command -v lpstat >/dev/null 2>&1 && systemctl list-unit-files cups.service >/dev/null 2>&1
}
