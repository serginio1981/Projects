#!/usr/bin/env bash
# install.sh — orquestador de un toque: convierte una Raspberry Pi con una
# Brother DCP-1602 por USB en un servidor de impresión AirPrint.
#
# Ejecuta en orden los scripts de scripts/, todos idempotentes y también
# ejecutables por separado.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

VALIDATE_ONLY=0

usage() {
  cat <<EOF
Uso: ${0##*/} [OPCIONES]

Convierte la Brother DCP-1602 (solo USB) en impresora AirPrint usando esta
máquina como servidor de impresión.

Opciones:
  --dry-run         Muestra los comandos que modificarían el sistema sin
                    ejecutarlos.
  --validate-only   No instala nada: ejecuta solo las comprobaciones previas
                    (00-preflight) y la verificación end-to-end (90-verify).
  --skip-airprint   Omite la publicación mDNS (30-airprint): la cola queda
                    creada pero iOS no la verá.
  --yes, -y         Responde 'sí' a las confirmaciones de instalación.
                    NO afecta a la confirmación visual de la hoja impresa.
  --help, -h        Muestra esta ayuda.

Variables de entorno:
  QUEUE_NAME        Nombre de la cola CUPS (default: Brother_DCP1602)
  QUEUE_LOCATION    Ubicación mostrada en CUPS/AirPrint (default: Oficina)
  PPD_OVERRIDE      Fuerza un PPD concreto en lugar de detectarlo

Ejemplos:
  sudo ./install.sh
  sudo ./install.sh --dry-run
  sudo QUEUE_NAME=Impresora_Salon ./install.sh --yes
  ./install.sh --validate-only
EOF
}

parse_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --validate-only) VALIDATE_ONLY=1 ;;
      --skip-airprint) SKIP_AIRPRINT=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "Opción no reconocida: ${arg}"; usage; exit 64 ;;
    esac
  done
}

run_step() {
  local script="$1"
  shift
  log_info "──────────────────────────────────────────────"
  log_info "Paso: ${script}"
  log_info "──────────────────────────────────────────────"
  "${SCRIPTS_DIR}/${script}" "$@" \
    || die "El paso ${script} falló. Corrige el problema y vuelve a ejecutar install.sh (todos los pasos son idempotentes)."
}

main() {
  parse_flags "$@"

  log_info "pi-airprint-brother — Brother DCP-1602 vía AirPrint"
  log_info "Configuración:"
  log_info "  Cola CUPS:      ${QUEUE_NAME}"
  log_info "  Ubicación:      ${QUEUE_LOCATION}"
  log_info "  PPD forzado:    ${PPD_OVERRIDE:-(detección automática)}"
  log_info "  Dry-run:        ${DRY_RUN}"
  log_info "  Solo validar:   ${VALIDATE_ONLY}"
  log_info "  Omitir mDNS:    ${SKIP_AIRPRINT}"

  if [[ "${VALIDATE_ONLY}" == "1" ]]; then
    run_step "00-preflight.sh"
    run_step "90-verify.sh"
    exit 0
  fi

  if [[ "${DRY_RUN}" != "1" ]]; then
    confirm "Se instalarán paquetes y se configurará CUPS/Avahi. ¿Continuar?" \
      || die "Instalación cancelada por el usuario."
  fi

  run_step "00-preflight.sh"
  run_step "10-install-packages.sh"
  run_step "20-add-queue.sh"
  if [[ "${SKIP_AIRPRINT}" == "1" ]]; then
    log_warn "Se omite la publicación AirPrint (--skip-airprint)."
  else
    run_step "30-airprint.sh"
  fi
  run_step "90-verify.sh"

  log_ok "Instalación terminada."
  log_info "En el iPhone/iPad: abre un documento → Compartir → Imprimir → selecciona '${QUEUE_NAME}'."
  log_info "Panel de CUPS: http://$(hostname).local:631/printers/${QUEUE_NAME}"
}

main "$@"
