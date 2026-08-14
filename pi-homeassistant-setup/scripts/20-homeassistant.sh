#!/usr/bin/env bash
# 20-homeassistant.sh — despliega Home Assistant Container con docker compose.
#
# El compose sale de la documentación oficial de instalación Container de
# home-assistant.io (verificada el 2026-08-14): imagen
# ghcr.io/home-assistant/home-assistant:stable, network_mode: host,
# privileged, /config persistente y TZ. En modo host NO se mapean puertos:
# HA escucha directamente el 8123 del anfitrión (CUPS sigue en el 631).
#
# Idempotente: el compose solo se reescribe si cambió, y `docker compose up
# -d` no recrea el contenedor si nada cambió.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly COMPOSE_TEMPLATE="${PROJECT_DIR}/templates/docker-compose.yml.tmpl"
readonly COMPOSE_FILE="${HA_BASE_DIR}/docker-compose.yml"
readonly STARTUP_TIMEOUT_SECONDS=240

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Despliega el contenedor de Home Assistant:
  Contenedor: \${HA_CONTAINER_NAME}=${HA_CONTAINER_NAME}
  Imagen:     \${HA_IMAGE}=${HA_IMAGE}
  Config:     \${HA_CONFIG_DIR}=${HA_CONFIG_DIR}
  Zona:       \${HA_TZ}=${HA_TZ}
  Puerto:     \${HA_PORT}=${HA_PORT} (network_mode: host; no se mapea)
EOF
}

parse_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Opción no reconocida: ${arg} (usa --help)" ;;
    esac
  done
}

render_compose() {
  sed \
    -e "s|@HA_CONTAINER_NAME@|${HA_CONTAINER_NAME}|g" \
    -e "s|@HA_IMAGE@|${HA_IMAGE}|g" \
    -e "s|@HA_CONFIG_DIR@|${HA_CONFIG_DIR}|g" \
    -e "s|@HA_TZ@|${HA_TZ}|g" \
    "${COMPOSE_TEMPLATE}"
}

check_port_free() {
  # Si el puerto está ocupado por el propio contenedor (reejecución), no es
  # un conflicto; cualquier otro ocupante detiene el despliegue.
  if ! port_listening "${HA_PORT}"; then
    return 0
  fi
  if docker_ready && ha_container_running; then
    log_ok "El puerto ${HA_PORT} lo ocupa el propio ${HA_CONTAINER_NAME}: despliegue idempotente."
    return 0
  fi
  die "El puerto ${HA_PORT} está ocupado por otro proceso. Identifícalo (ss -tlnp | grep ${HA_PORT}) y libéralo, o usa HA_PORT=... solo si sabes reconfigurar HA."
}

main() {
  parse_flags "$@"
  require_root
  [[ -r "${COMPOSE_TEMPLATE}" ]] || die "No encuentro la plantilla ${COMPOSE_TEMPLATE}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    docker_ready || die "Docker no está operativo: ejecuta antes scripts/10-docker.sh."
  fi

  check_port_free

  run mkdir -p "${HA_CONFIG_DIR}"

  local rendered
  rendered="$(render_compose)"
  if [[ -f "${COMPOSE_FILE}" ]] && [[ "$(cat "${COMPOSE_FILE}")" == "${rendered}" ]]; then
    log_ok "Compose ya al día: ${COMPOSE_FILE}."
  elif [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${COMPOSE_FILE}:"
    printf '%s\n' "${rendered}" >&2
  else
    mkdir -p "${HA_BASE_DIR}"
    printf '%s\n' "${rendered}" >"${COMPOSE_FILE}"
    log_ok "Compose escrito en ${COMPOSE_FILE}."
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "docker compose -f ${COMPOSE_FILE} up -d"
    log_ok "Dry-run: no se desplegó nada."
    exit 0
  fi

  log_info "Desplegando ${HA_CONTAINER_NAME} (la primera descarga de imagen puede tardar varios minutos en WiFi)..."
  docker compose -f "${COMPOSE_FILE}" up -d

  log_info "Esperando a que la interfaz responda en el puerto ${HA_PORT} (el primer arranque de HA tarda)..."
  local waited=0
  while ! http_responds "${HA_PORT}"; do
    if [[ "${waited}" -ge "${STARTUP_TIMEOUT_SECONDS}" ]]; then
      log_error "HA no respondió en ${STARTUP_TIMEOUT_SECONDS}s. Diagnóstico: docker logs ${HA_CONTAINER_NAME} --tail 50"
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log_ok "Home Assistant responde en http://$(hostname).local:${HA_PORT}/"

  state_mark "homeassistant-deployed"
  log_ok "Contenedor desplegado. El asistente inicial de HA se completa desde el navegador."
}

main "$@"
