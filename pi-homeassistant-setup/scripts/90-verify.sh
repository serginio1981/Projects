#!/usr/bin/env bash
# 90-verify.sh — verificación end-to-end y diagnóstico standalone.
#
# CRITERIO DE ÉXITO (doble, inseparable):
#   1. La interfaz de Home Assistant responde en el puerto 8123, Y
#   2. el servidor de impresión sigue operativo (cola aceptando trabajos y
#      anuncio mDNS de AirPrint visible).
# Ninguna de las dos por separado cuenta como éxito: este proyecto existe
# para añadir HA SIN degradar la impresión.
#
# Verifica además la coexistencia mDNS (riesgo declarado): el zeroconf de HA
# y el HomeKit Bridge publican sobre la misma interfaz donde avahi-daemon ya
# anuncia AirPrint; ambos anuncios deben seguir visibles en avahi-browse.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Diagnóstico end-to-end, ejecutable en cualquier momento:
  1. Docker activo y contenedor \${HA_CONTAINER_NAME} corriendo
  2. Interfaz de HA respondiendo en el puerto \${HA_PORT}
  3. CUPS activo, cola(s) habilitadas y aceptando trabajos
  4. Anuncio mDNS de AirPrint (_ipp._tcp) aún publicado
  5. Coexistencia mDNS: anuncio de HA (_home-assistant._tcp) sin desplazar al de AirPrint
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

HA_OK=0
PRINT_OK=0
WARNINGS=0

check_homeassistant() {
  local ok=1
  if ! docker_ready; then
    log_error "Docker no está operativo. Diagnóstico: systemctl status docker"
    ok=0
  elif ! ha_container_running; then
    log_error "El contenedor ${HA_CONTAINER_NAME} no está corriendo. Diagnóstico: docker ps -a; docker logs ${HA_CONTAINER_NAME} --tail 50"
    ok=0
  else
    log_ok "Contenedor ${HA_CONTAINER_NAME} corriendo."
  fi

  if http_responds "${HA_PORT}"; then
    log_ok "Interfaz de Home Assistant respondiendo en el puerto ${HA_PORT}."
  else
    log_error "El puerto ${HA_PORT} no responde. Diagnóstico: docker logs ${HA_CONTAINER_NAME} --tail 50"
    ok=0
  fi
  HA_OK="${ok}"
}

check_print_server() {
  if ! print_server_present; then
    log_warn "Esta máquina no tiene CUPS: no hay servidor de impresión que verificar."
    log_warn "En la Pi de producción esto sería un FALLO del criterio de éxito."
    PRINT_OK=0
    return 0
  fi

  local ok=1
  if systemctl is-active --quiet cups 2>/dev/null; then
    log_ok "Servicio cups activo."
  else
    log_error "El servicio cups NO está activo: el servidor de impresión está caído."
    ok=0
  fi

  local queues queue
  queues="$(lpstat -p 2>/dev/null | awk '/^printer|^impresora/ {print $2}')" || true
  if [[ -z "${queues}" ]]; then
    log_error "No hay colas de impresión definidas en CUPS."
    ok=0
  else
    while IFS= read -r queue; do
      if lpstat -a "${queue}" 2>/dev/null | grep -qi 'accepting\|aceptando'; then
        log_ok "Cola ${queue} aceptando trabajos."
      else
        log_error "La cola ${queue} NO acepta trabajos. Rehabilítala: sudo cupsaccept ${queue}; sudo cupsenable ${queue}"
        ok=0
      fi
    done <<<"${queues}"
  fi

  # Anuncio AirPrint por mDNS: sin él, los iPhone dejan de ver la impresora
  # en silencio.
  if ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    log_error "avahi-daemon NO está activo: AirPrint queda sin anunciar."
    ok=0
  elif command -v avahi-browse >/dev/null 2>&1; then
    local ipp_records
    ipp_records="$(avahi-browse --resolve --terminate --parsable _ipp._tcp 2>/dev/null | grep '^=' | grep -F 'rp=printers/' || true)"
    if [[ -n "${ipp_records}" ]]; then
      log_ok "Anuncio mDNS de AirPrint (_ipp._tcp con rp=printers/...) sigue publicado."
    else
      log_error "El anuncio mDNS de AirPrint ya NO se ve en avahi-browse."
      ok=0
    fi
  else
    log_warn "Sin avahi-browse (paquete avahi-utils): no puedo verificar el anuncio AirPrint."
    WARNINGS=$((WARNINGS + 1))
  fi
  PRINT_OK="${ok}"
}

check_mdns_coexistence() {
  # Riesgo declarado en el proyecto: verificar, no asumir. HA (zeroconf y,
  # si se configura, HomeKit Bridge) publica mDNS en modo host sobre la misma
  # interfaz que avahi. Normalmente coexisten; se comprueba que el anuncio de
  # HA exista SIN que el de AirPrint desaparezca (eso ya lo validó
  # check_print_server).
  if ! command -v avahi-browse >/dev/null 2>&1; then
    return 0
  fi
  local ha_records
  ha_records="$(avahi-browse --resolve --terminate --parsable _home-assistant._tcp 2>/dev/null | grep '^=' || true)"
  if [[ -n "${ha_records}" ]]; then
    log_ok "Coexistencia mDNS verificada: HA se anuncia (_home-assistant._tcp) y AirPrint sigue visible."
  else
    log_warn "HA aún no publica _home-assistant._tcp (normal si el asistente inicial no se completó)."
    log_warn "Reejecuta este diagnóstico tras terminar el onboarding de HA."
    WARNINGS=$((WARNINGS + 1))
  fi
  local homekit_records
  homekit_records="$(avahi-browse --resolve --terminate --parsable _hap._tcp 2>/dev/null | grep '^=' || true)"
  if [[ -n "${homekit_records}" ]]; then
    log_ok "HomeKit Bridge anunciado (_hap._tcp) y conviviendo con AirPrint."
  fi
}

# Solo si el Matter Server opcional (40-matter-server.sh) está desplegado.
check_matter_server() {
  if ! docker_ready; then
    return 0
  fi
  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "${MATTER_CONTAINER_NAME}"; then
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "${MATTER_CONTAINER_NAME}" \
    && port_listening "${MATTER_WS_PORT}"; then
    log_ok "Matter Server corriendo y escuchando en el puerto ${MATTER_WS_PORT}."
  else
    log_warn "El Matter Server existe pero no está sano. Diagnóstico: docker logs ${MATTER_CONTAINER_NAME} --tail 50"
    WARNINGS=$((WARNINGS + 1))
  fi
}

main() {
  parse_flags "$@"
  require_cmd systemctl curl

  check_homeassistant
  check_print_server
  check_mdns_coexistence
  check_matter_server

  echo >&2
  if [[ "${HA_OK}" == "1" && "${PRINT_OK}" == "1" ]]; then
    state_mark "verified-end-to-end"
    log_ok "ÉXITO: Home Assistant responde en el ${HA_PORT} Y el servidor de impresión sigue operativo."
    [[ "${WARNINGS}" -gt 0 ]] && log_warn "Con ${WARNINGS} avisos no bloqueantes (ver arriba)."
    exit 0
  fi
  if [[ "${HA_OK}" == "1" ]]; then
    log_error "FALLO del criterio doble: HA funciona pero el servidor de impresión NO. Prioridad: restaurar la impresión (docs/ROLLBACK.md si hace falta)."
  elif [[ "${PRINT_OK}" == "1" ]]; then
    log_error "FALLO del criterio doble: la impresión está bien pero HA NO responde. Diagnóstico: docker logs ${HA_CONTAINER_NAME} --tail 50"
  else
    log_error "FALLO doble: ni HA ni el servidor de impresión están operativos. Empieza por docs/RUNBOOK-validacion.md."
  fi
  exit 1
}

main "$@"
