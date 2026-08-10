#!/usr/bin/env bash
# 90-verify.sh — verificación end-to-end y diagnóstico standalone.
#
# Comprueba toda la cadena: USB → backend SANE → udev → avahi/mDNS → puertos
# web. Recuerda en todo momento que el ÚNICO criterio de éxito es un archivo
# escaneado legible (20-verify-sane.sh); que scanimage -L liste el
# dispositivo no se reporta como éxito.
#
# Se puede ejecutar en cualquier momento como herramienta de diagnóstico.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly DLL_CONF="/etc/sane.d/dll.conf"
readonly UDEV_RULE_FILE="/etc/udev/rules.d/60-brother-scanner.rules"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Diagnóstico end-to-end:
  1. Dispositivo Brother en el bus USB
  2. Backend 'brother' registrado en ${DLL_CONF}
  3. Regla udev instalada y coherente con el product ID actual
  4. scanimage -L lista el dispositivo (comprobación, NO éxito)
  5. avahi-daemon activo y anuncio mDNS eSCL (_uscan._tcp) visible
  6. Puertos web de AirSane (\${AIRSANE_PORT}) y scanservjs (\${SCANSERVJS_PORT})
  7. Estado de la validación real (escaneo legible) y oferta de ejecutarla

Respeta SKIP_AIRSANE / SKIP_SCANSERVJS para no exigir lo que no se instaló.
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

FAILURES=0
fail() {
  log_error "$*"
  FAILURES=$((FAILURES + 1))
}

check_usb() {
  local product_id
  if ! command -v lsusb >/dev/null 2>&1; then
    fail "Falta lsusb (paquete usbutils)."
    return 0
  fi
  if product_id="$(detect_brother_product_id)" && [[ -n "${product_id}" ]]; then
    log_ok "Dispositivo Brother en USB: ${BROTHER_VENDOR_ID}:${product_id}."
  else
    fail "Sin dispositivo Brother en el bus USB. ¿Encendida? ¿Cable conectado?"
  fi
}

check_backend() {
  if [[ -f "${DLL_CONF}" ]] && grep -qxE '[[:space:]]*brother[[:space:]]*' "${DLL_CONF}"; then
    log_ok "Backend 'brother' registrado en ${DLL_CONF}."
  else
    fail "El backend 'brother' no está en ${DLL_CONF}. Ejecuta scripts/10-driver.sh."
  fi
}

check_udev() {
  local product_id
  if [[ ! -f "${UDEV_RULE_FILE}" ]]; then
    fail "No existe la regla udev ${UDEV_RULE_FILE}. Ejecuta scripts/10-driver.sh."
    return 0
  fi
  log_ok "Regla udev presente: ${UDEV_RULE_FILE}."
  if product_id="$(detect_brother_product_id)" && [[ -n "${product_id}" ]]; then
    if grep -qF "ATTRS{idProduct}==\"${product_id}\"" "${UDEV_RULE_FILE}"; then
      log_ok "La regla udev coincide con el product ID actual (${product_id})."
    else
      fail "La regla udev NO coincide con el product ID actual (${product_id}): regenera con scripts/10-driver.sh."
    fi
  fi
}

check_scanimage() {
  if ! command -v scanimage >/dev/null 2>&1; then
    fail "Falta scanimage (paquete sane-utils)."
    return 0
  fi
  local listing
  listing="$(scanimage -L 2>/dev/null)" || true
  if [[ -n "${listing}" ]] && grep -qi 'brother' <<<"${listing}"; then
    log_ok "scanimage -L lista el dispositivo (comprobación superada)."
    log_warn "Recuerda: esto NO es el criterio de éxito; el éxito es un escaneo legible."
  else
    fail "scanimage -L no lista el escáner. ¿Reconectaste el USB tras la regla udev?"
  fi
}

check_mdns() {
  if [[ "${SKIP_AIRSANE}" == "1" ]]; then
    log_info "SKIP_AIRSANE=1: omito las comprobaciones de avahi/eSCL."
    return 0
  fi
  if ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    fail "avahi-daemon no está activo: AirSane no puede anunciarse (falla con 'Bad State (-2)')."
    return 0
  fi
  log_ok "avahi-daemon activo."
  if ! command -v avahi-browse >/dev/null 2>&1; then
    fail "Falta avahi-browse (paquete avahi-utils)."
    return 0
  fi
  local records
  records="$(avahi-browse --resolve --terminate --parsable _uscan._tcp 2>/dev/null | grep '^=' || true)"
  if [[ -n "${records}" ]]; then
    log_ok "Servicio eSCL (_uscan._tcp) anunciado por mDNS."
  else
    fail "No se ve ningún servicio eSCL (_uscan._tcp) en mDNS. Diagnóstico: journalctl -u airsaned."
  fi
  if ! systemctl is-active --quiet airsaned 2>/dev/null; then
    fail "La unidad airsaned no está activa. Arráncala: sudo systemctl start airsaned"
  fi
}

check_ports() {
  if [[ "${SKIP_AIRSANE}" != "1" ]]; then
    if http_responds "${AIRSANE_PORT}"; then
      log_ok "AirSane responde en el puerto ${AIRSANE_PORT}."
    else
      fail "El puerto ${AIRSANE_PORT} (AirSane) no responde. Diagnóstico: journalctl -u airsaned -n 50"
    fi
  fi
  if [[ "${SKIP_SCANSERVJS}" != "1" ]]; then
    if http_responds "${SCANSERVJS_PORT}"; then
      log_ok "scanservjs responde en el puerto ${SCANSERVJS_PORT}."
    else
      fail "El puerto ${SCANSERVJS_PORT} (scanservjs) no responde. Diagnóstico: journalctl -u scanservjs -n 50"
    fi
  fi
}

main() {
  parse_flags "$@"

  check_usb
  check_backend
  check_udev
  check_scanimage
  check_mdns
  check_ports

  if [[ "${FAILURES}" -gt 0 ]]; then
    die "Diagnóstico con ${FAILURES} fallos. Consulta docs/RUNBOOK-validacion.md."
  fi

  log_ok "Toda la infraestructura está en orden."

  # --- El criterio de éxito real ---------------------------------------------
  if state_done "sane-scan-verified"; then
    log_ok "La validación real (escaneo legible confirmado visualmente) ya consta como superada."
  else
    log_warn "AÚN NO consta un escaneo real validado visualmente: la instalación no está probada."
    if [[ -t 0 && "${DRY_RUN}" != "1" ]]; then
      if confirm "¿Hacer ahora el escaneo real de validación (20-verify-sane.sh)?"; then
        "${SCRIPT_DIR}/20-verify-sane.sh"
      else
        log_warn "Pendiente: ejecuta scripts/20-verify-sane.sh cuando puedas mirar el resultado."
      fi
    else
      log_warn "Ejecuta scripts/20-verify-sane.sh en una terminal interactiva para completarla."
    fi
  fi
}

main "$@"
