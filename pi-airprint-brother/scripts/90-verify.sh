#!/usr/bin/env bash
# 90-verify.sh — verificación end-to-end de la instalación.
#
# El criterio de éxito es UNA HOJA FÍSICA LEGIBLE, no un job marcado como
# "completed" en CUPS: con un driver equivocado CUPS da el trabajo por
# terminado aunque la impresora no imprima nada o imprima basura. Por eso
# este script termina pidiendo confirmación visual explícita, que nunca se
# responde sola (ni siquiera con --yes).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly TESTPAGE_PDF="/usr/share/cups/data/default-testpage.pdf"
readonly JOB_TIMEOUT_SECONDS=180

usage() {
  cat <<EOF
Uso: ${0##*/} [--checks-only] [--dry-run] [--yes] [--help]

Verifica de extremo a extremo:
  1. Servicios cups y avahi-daemon activos
  2. Cola \${QUEUE_NAME} existente, habilitada y aceptando trabajos
  3. Impresora presente en el bus USB
  4. Anuncio mDNS con subtipo _universal y TXT URF no vacío
  5. Impresión real de una página de prueba + confirmación visual

Con --checks-only se ejecutan solo los pasos 1-4 (sin imprimir).
La confirmación visual del paso 5 requiere una persona delante: --yes NO la
responde automáticamente.
EOF
}

CHECKS_ONLY=0

parse_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --checks-only) CHECKS_ONLY=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Opción no reconocida: ${arg} (usa --help)" ;;
    esac
  done
}

check_services() {
  local svc failures=0
  for svc in cups avahi-daemon; do
    if systemctl is-active --quiet "${svc}"; then
      log_ok "Servicio activo: ${svc}."
    else
      log_error "El servicio ${svc} no está activo. Arráncalo: sudo systemctl start ${svc}"
      failures=$((failures + 1))
    fi
  done
  return "${failures}"
}

check_queue() {
  if ! lpstat -p "${QUEUE_NAME}" >/dev/null 2>&1; then
    log_error "La cola ${QUEUE_NAME} no existe. Créala con scripts/20-add-queue.sh."
    return 1
  fi
  log_ok "La cola ${QUEUE_NAME} existe."

  if lpstat -p "${QUEUE_NAME}" 2>/dev/null | grep -qi 'disabled\|deshabilitada'; then
    log_error "La cola está deshabilitada. Habilítala: sudo cupsenable ${QUEUE_NAME}"
    return 1
  fi
  if ! lpstat -a "${QUEUE_NAME}" 2>/dev/null | grep -qi 'accepting\|aceptando'; then
    log_error "La cola no acepta trabajos. Actívala: sudo cupsaccept ${QUEUE_NAME}"
    return 1
  fi
  log_ok "La cola está habilitada y acepta trabajos."
}

check_usb() {
  if ! command -v lsusb >/dev/null 2>&1; then
    log_warn "Sin lsusb; omito la comprobación del bus USB."
    return 0
  fi
  if lsusb | grep -qiE '04f9|Brother'; then
    log_ok "Impresora Brother presente en el bus USB."
  else
    log_error "La impresora no aparece en el bus USB. ¿Encendida? ¿Cable conectado?"
    return 1
  fi
}

check_mdns() {
  local failures=0
  if ! command -v avahi-browse >/dev/null 2>&1; then
    log_error "Falta avahi-browse (paquete avahi-utils)."
    return 1
  fi
  if mdns_has_universal_subtype; then
    log_ok "Subtipo _universal._sub._ipp._tcp anunciado."
  else
    log_error "Falta el subtipo _universal._sub._ipp._tcp: iOS NO listará la impresora."
    log_error "Ejecuta scripts/30-airprint.sh y revisa el runbook (docs/)."
    failures=$((failures + 1))
  fi
  if mdns_has_urf; then
    log_ok "Registro TXT URF presente y no vacío."
  else
    log_error "Falta un TXT URF no vacío: iOS NO listará la impresora (sin error visible)."
    log_error "Ejecuta scripts/30-airprint.sh y revisa el runbook (docs/)."
    failures=$((failures + 1))
  fi

  # Un anuncio duplicado (CUPS + archivo manual) hace que macOS muestre la
  # impresora dos veces.
  local count
  count="$(mdns_records_for_queue "_ipp._tcp" | awk -F';' '{print $4}' | sort -u | grep -c . || true)"
  if [[ "${count}" -gt 1 ]]; then
    log_warn "Se anuncian ${count} servicios _ipp._tcp para la misma cola: impresora duplicada en macOS."
    log_warn "Elimina el archivo manual: sudo rm /etc/avahi/services/airprint-${QUEUE_NAME}.service"
  fi
  return "${failures}"
}

print_test_page() {
  local job_output job_id testfile
  if [[ -r "${TESTPAGE_PDF}" ]]; then
    testfile="${TESTPAGE_PDF}"
  else
    testfile="$(mktemp --suffix=.txt)"
    printf 'Página de prueba — pi-airprint-brother\nCola: %s\n' "${QUEUE_NAME}" >"${testfile}"
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "lp -d ${QUEUE_NAME} ${testfile}"
    return 0
  fi

  log_info "Enviando página de prueba a ${QUEUE_NAME}..."
  job_output="$(lp -d "${QUEUE_NAME}" "${testfile}")"
  job_id="$(sed -n 's/request id is \([^ ]*\).*/\1/p' <<<"${job_output}")"
  log_info "Trabajo encolado: ${job_id:-desconocido}"

  local waited=0
  while [[ -n "${job_id}" ]] && lpstat -W not-completed 2>/dev/null | grep -qF "${job_id}"; do
    if [[ "${waited}" -ge "${JOB_TIMEOUT_SECONDS}" ]]; then
      log_error "El trabajo ${job_id} sigue en cola tras ${JOB_TIMEOUT_SECONDS} s."
      log_error "Revisa: lpstat -l -o  y  journalctl -u cups --since '-10 min'"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done

  log_ok "CUPS dio el trabajo por terminado."
  log_warn "OJO: que CUPS lo marque como completado NO significa que haya salido papel."
}

main() {
  parse_flags "$@"
  require_cmd lpstat systemctl

  local failures=0
  check_services || failures=$((failures + $?))
  check_queue || failures=$((failures + 1))
  check_usb || failures=$((failures + 1))
  check_mdns || failures=$((failures + $?))

  if [[ "${failures}" -gt 0 ]]; then
    die "Verificación fallida: ${failures} comprobaciones no superadas. Consulta docs/RUNBOOK-validacion-driver.md."
  fi

  if [[ "${CHECKS_ONLY}" == "1" ]]; then
    log_ok "Comprobaciones superadas (modo --checks-only: no se imprimió nada)."
    log_warn "La instalación NO queda validada hasta imprimir y ver una hoja física legible."
    exit 0
  fi

  print_test_page || die "La página de prueba no llegó a completarse."

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "Modo --dry-run: no se imprimió nada, la verificación queda pendiente."
    exit 0
  fi

  # Criterio de éxito real: papel legible. Nunca se auto-responde.
  if confirm_visual "¿Salió una hoja física y su contenido es legible?"; then
    state_mark "verified-physical-print"
    log_ok "Verificación end-to-end SUPERADA: la impresora está lista para AirPrint."
  else
    log_error "Verificación FALLIDA: no hay hoja legible aunque CUPS completó el trabajo."
    log_error "Causa típica: PPD/driver incorrecto. Sigue docs/RUNBOOK-validacion-driver.md."
    exit 1
  fi
}

main "$@"
