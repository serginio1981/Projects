#!/usr/bin/env bash
# 40-matter-server.sh — Matter Server como contenedor (PASO OPCIONAL).
#
# La integración Matter de Home Assistant no habla con los dispositivos
# directamente: necesita el Matter Server. En HA OS es un add-on; en modo
# Container (este proyecto) se despliega como OTRO contenedor y la
# integración de HA se conecta a él por WebSocket en ws://localhost:5580/ws.
# Sin esto, el diálogo Matter de HA falla con "Failed to connect".
#
# Contenedor tomado de la documentación oficial del proyecto
# (docs/docker.md de github.com/matter-js/python-matter-server, verificado
# el 2026-08-15): network_mode host (mDNS), apparmor unconfined y /run/dbus
# (Bluetooth para el commissioning local), /data persistente.
#
# Idempotente: el compose solo se reescribe si cambió; `up -d` no recrea si
# nada cambió.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly COMPOSE_TEMPLATE="${PROJECT_DIR}/templates/matter-server-compose.yml.tmpl"
readonly COMPOSE_FILE="${MATTER_BASE_DIR}/docker-compose.yml"
readonly STARTUP_TIMEOUT_SECONDS=120

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Despliega el Matter Server (requisito de la integración Matter de HA en
instalaciones Container):
  Contenedor: \${MATTER_CONTAINER_NAME}=${MATTER_CONTAINER_NAME}
  Imagen:     \${MATTER_IMAGE}=${MATTER_IMAGE}
  Datos:      \${MATTER_DATA_DIR}=${MATTER_DATA_DIR}
  WebSocket:  ws://localhost:\${MATTER_WS_PORT}=${MATTER_WS_PORT}/ws (el default del diálogo de HA)
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
    -e "s|@MATTER_CONTAINER_NAME@|${MATTER_CONTAINER_NAME}|g" \
    -e "s|@MATTER_IMAGE@|${MATTER_IMAGE}|g" \
    -e "s|@MATTER_DATA_DIR@|${MATTER_DATA_DIR}|g" \
    "${COMPOSE_TEMPLATE}"
}

main() {
  parse_flags "$@"
  require_root
  [[ -r "${COMPOSE_TEMPLATE}" ]] || die "No encuentro la plantilla ${COMPOSE_TEMPLATE}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    docker_ready || die "Docker no está operativo: ejecuta antes scripts/10-docker.sh."
  fi

  run mkdir -p "${MATTER_DATA_DIR}"

  local rendered
  rendered="$(render_compose)"
  if [[ -f "${COMPOSE_FILE}" ]] && [[ "$(cat "${COMPOSE_FILE}")" == "${rendered}" ]]; then
    log_ok "Compose del Matter Server ya al día: ${COMPOSE_FILE}."
  elif [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${COMPOSE_FILE}:"
    printf '%s\n' "${rendered}" >&2
  else
    mkdir -p "${MATTER_BASE_DIR}"
    printf '%s\n' "${rendered}" >"${COMPOSE_FILE}"
    log_ok "Compose escrito en ${COMPOSE_FILE}."
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "docker compose -f ${COMPOSE_FILE} up -d"
    log_ok "Dry-run: no se desplegó nada."
    exit 0
  fi

  log_info "Desplegando ${MATTER_CONTAINER_NAME}..."
  docker compose -f "${COMPOSE_FILE}" up -d

  log_info "Esperando el WebSocket en el puerto ${MATTER_WS_PORT}..."
  local waited=0
  while ! port_listening "${MATTER_WS_PORT}"; do
    if [[ "${waited}" -ge "${STARTUP_TIMEOUT_SECONDS}" ]]; then
      log_error "El Matter Server no abrió el puerto ${MATTER_WS_PORT} en ${STARTUP_TIMEOUT_SECONDS}s."
      log_error "Diagnóstico: docker logs ${MATTER_CONTAINER_NAME} --tail 50"
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log_ok "Matter Server escuchando en el puerto ${MATTER_WS_PORT}."

  state_mark "matter-server-deployed"
  log_ok "Listo. En HA: Ajustes → Dispositivos y servicios → Añadir integración → Matter,"
  log_ok "con la URL por defecto ws://localhost:${MATTER_WS_PORT}/ws (HA corre en red host: localhost sirve)."
  log_warn "El emparejamiento de dispositivos se hace desde la APP móvil oficial de Home Assistant"
  log_warn "(usa el Bluetooth del teléfono); desde Safari no se puede emparejar."
}

main "$@"
