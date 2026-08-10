#!/usr/bin/env bash
# 00-preflight.sh — comprueba el hardware y el sistema. NO modifica nada.
#
# Verifica que estamos en un sistema Debian/Raspberry Pi OS, que la Brother
# DCP-1602 está conectada por USB y que hay recursos suficientes. Se puede
# ejecutar tantas veces como se quiera, antes o después de la instalación.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Comprobaciones previas (solo lectura, no cambia nada):
  - Sistema operativo basado en Debian
  - Arquitectura ARM / modelo de Raspberry Pi
  - Impresora Brother visible en el bus USB
  - Espacio en disco disponible
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

main() {
  parse_flags "$@"
  local failures=0

  log_info "Comprobaciones previas (ningún cambio se aplicará al sistema)."

  # --- Sistema operativo -------------------------------------------------
  if [[ -r /etc/os-release ]]; then
    local os_id os_like
    os_id="$(. /etc/os-release && echo "${ID:-desconocido}")"
    os_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
    if [[ "${os_id}" =~ ^(debian|raspbian)$ ]] || [[ "${os_like}" == *debian* ]]; then
      log_ok "Sistema operativo compatible: ${os_id}."
    else
      log_warn "Sistema '${os_id}' no basado en Debian: el paquete printer-driver-brlaser puede llamarse distinto."
    fi
  else
    log_warn "No pude leer /etc/os-release; no puedo confirmar la distribución."
  fi

  # --- Arquitectura / modelo de Pi ---------------------------------------
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    arm*|aarch64)
      log_ok "Arquitectura ARM detectada: ${arch}."
      ;;
    *)
      log_warn "Arquitectura ${arch}: no parece una Raspberry Pi. El proyecto funciona igual en cualquier Debian."
      ;;
  esac
  if [[ -r /proc/device-tree/model ]]; then
    local pi_model
    pi_model="$(tr -d '\0' </proc/device-tree/model)"
    log_ok "Modelo detectado: ${pi_model}."
  fi

  # --- Impresora en el bus USB --------------------------------------------
  # La DCP-1602 es solo USB 2.0 (sin red); tiene que aparecer en lsusb.
  # 04f9 es el identificador de fabricante (vendor ID) de Brother.
  if command -v lsusb >/dev/null 2>&1; then
    local usb_line
    if usb_line="$(lsusb | grep -iE '04f9|Brother' | head -n 1)"; then
      log_ok "Impresora Brother detectada en USB: ${usb_line}"
    else
      log_error "No se detecta ninguna impresora Brother en el bus USB."
      log_error "Comprueba que la DCP-1602 está encendida y el cable USB conectado a la Pi."
      failures=$((failures + 1))
    fi
  else
    log_warn "Falta el comando lsusb (paquete usbutils); no puedo comprobar el bus USB."
  fi

  # --- Espacio en disco ----------------------------------------------------
  local avail_kb
  avail_kb="$(df --output=avail -k / | tail -n 1 | tr -d ' ')"
  if [[ "${avail_kb}" -lt 512000 ]]; then
    log_warn "Quedan menos de 500 MB libres en /: la instalación de paquetes podría fallar."
  else
    log_ok "Espacio en disco suficiente: $((avail_kb / 1024)) MB libres en /."
  fi

  # --- Estado de instalación previo (informativo) --------------------------
  if command -v dpkg >/dev/null 2>&1 && dpkg -s printer-driver-brlaser >/dev/null 2>&1; then
    log_info "El driver brlaser ya está instalado (una ejecución previa o manual)."
  fi

  if [[ "${failures}" -gt 0 ]]; then
    die "Comprobaciones previas fallidas: ${failures}. Corrige lo anterior antes de instalar."
  fi
  log_ok "Comprobaciones previas superadas."
}

main "$@"
