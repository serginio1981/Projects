#!/usr/bin/env bash
# 30-airprint.sh — publicación mDNS condicional para AirPrint.
#
# AirPrint exige DOS cosas en el anuncio mDNS, ambas obligatorias:
#   1. El subtipo _universal._sub._ipp._tcp
#   2. Un registro TXT URF presente y NO vacío (aquí: URF=DM3)
# Si falta cualquiera de las dos, iOS no lista la impresora y no muestra
# ningún error.
#
# Debian/Raspberry Pi OS trae CUPS parcheado para publicar ambos por sí solo
# cuando la cola está compartida. Por eso este script es CONDICIONAL:
# primero inspecciona con avahi-browse si el anuncio de CUPS ya es correcto y
# SOLO genera el archivo manual de Avahi si falta algo. Si el archivo se
# creara siempre, macOS mostraría la impresora duplicada.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly TEMPLATE_FILE="${PROJECT_DIR}/templates/airprint.service.tmpl"
readonly SERVICE_FILE="/etc/avahi/services/airprint-${QUEUE_NAME}.service"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Comprueba el anuncio mDNS de la cola \${QUEUE_NAME} y solo si CUPS no publica
un URF válido genera ${SERVICE_FILE} a partir de la plantilla.
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

# Comprueba con reintentos si CUPS ya publica un anuncio AirPrint completo
# (Avahi tarda unos segundos en propagar cambios tras compartir la cola).
cups_announcement_complete() {
  local attempt
  for attempt in 1 2 3; do
    if mdns_has_urf && mdns_has_universal_subtype; then
      return 0
    fi
    log_info "Anuncio aún incompleto (intento ${attempt}/3); espero 3 segundos..."
    sleep 3
  done
  return 1
}

render_template() {
  sed \
    -e "s|@QUEUE_NAME@|${QUEUE_NAME}|g" \
    -e "s|@QUEUE_LOCATION@|${QUEUE_LOCATION}|g" \
    -e "s|@URF_VALUE@|${URF_VALUE}|g" \
    "${TEMPLATE_FILE}"
}

install_service_file() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${SERVICE_FILE} con este contenido:"
    render_template >&2
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  render_template >"${tmp}"
  install -m 0644 "${tmp}" "${SERVICE_FILE}"
  rm -f "${tmp}"
  run systemctl reload-or-restart avahi-daemon
  log_ok "Archivo de servicio Avahi instalado: ${SERVICE_FILE}"
}

remove_stale_service_file() {
  if [[ -f "${SERVICE_FILE}" ]]; then
    log_warn "CUPS ya publica el anuncio completo pero existe ${SERVICE_FILE}:"
    log_warn "se elimina para evitar que macOS muestre la impresora duplicada."
    run rm -f "${SERVICE_FILE}"
    run systemctl reload-or-restart avahi-daemon
  fi
}

main() {
  parse_flags "$@"

  if [[ "${SKIP_AIRPRINT}" == "1" ]]; then
    log_warn "SKIP_AIRPRINT=1: se omite la publicación AirPrint."
    exit 0
  fi

  require_root
  require_cmd avahi-browse systemctl
  [[ -r "${TEMPLATE_FILE}" ]] || die "No encuentro la plantilla ${TEMPLATE_FILE}"

  log_info "Inspeccionando el anuncio mDNS de la cola ${QUEUE_NAME}..."

  if cups_announcement_complete; then
    log_ok "CUPS ya publica el subtipo _universal y un URF no vacío."
    log_ok "No hace falta archivo manual de Avahi."
    remove_stale_service_file
  else
    log_warn "El anuncio de CUPS está incompleto (falta URF y/o el subtipo _universal)."
    log_info "Generando el anuncio manual desde la plantilla..."
    install_service_file

    if [[ "${DRY_RUN}" != "1" ]]; then
      sleep 3
      if mdns_has_urf && mdns_has_universal_subtype; then
        log_ok "El anuncio manual ya se ve en la red con URF=${URF_VALUE}."
      else
        log_warn "El anuncio aún no se ve; puede tardar unos segundos más."
        log_warn "Verifícalo con: avahi-browse -rt _ipp._tcp"
      fi
    fi
  fi

  state_mark "airprint-configured"
  log_ok "Publicación AirPrint verificada/configurada."
}

main "$@"
