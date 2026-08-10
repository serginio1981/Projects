#!/usr/bin/env bash
# 00-preflight.sh — detecta el escáner USB y el entorno. NO modifica nada.
#
# Comprobaciones de solo lectura: dispositivo Brother en el bus USB (con su
# product ID, que varía por modelo), sistema operativo, arquitectura,
# convivencia con CUPS y disponibilidad de los puertos web.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Comprobaciones previas (solo lectura, no cambia nada):
  - Escáner Brother visible en el bus USB (vendor ${BROTHER_VENDOR_ID})
  - Sistema operativo basado en Debian y arquitectura soportada
  - Convivencia con CUPS (impresión) si está presente
  - Puertos ${SCANSERVJS_PORT} (scanservjs) y ${AIRSANE_PORT} (AirSane) libres
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

  log_info "Comprobaciones previas de pi-scan-brother (nada se modifica)."

  # --- Sistema operativo ----------------------------------------------------
  if [[ -r /etc/os-release ]]; then
    local os_id os_like
    os_id="$(. /etc/os-release && echo "${ID:-desconocido}")"
    os_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
    if [[ "${os_id}" =~ ^(debian|raspbian)$ ]] || [[ "${os_like}" == *debian* ]]; then
      log_ok "Sistema operativo compatible: ${os_id}."
    else
      log_warn "Sistema '${os_id}' no basado en Debian: los nombres de paquetes pueden variar."
    fi
  else
    log_warn "No pude leer /etc/os-release; no puedo confirmar la distribución."
  fi

  # --- Arquitectura -----------------------------------------------------------
  local arch
  if arch="$(arch_label)"; then
    log_ok "Arquitectura soportada por los binarios de brscan: ${arch} ($(uname -m))."
  else
    log_warn "Arquitectura $(uname -m) sin binario precompilado de brscan: se usará la compilación como alternativa."
  fi
  if [[ -r /proc/device-tree/model ]]; then
    local pi_model
    pi_model="$(tr -d '\0' </proc/device-tree/model)"
    log_ok "Modelo detectado: ${pi_model}."
  fi

  # --- Escáner en el bus USB ---------------------------------------------------
  if command -v lsusb >/dev/null 2>&1; then
    local product_id
    if product_id="$(detect_brother_product_id)" && [[ -n "${product_id}" ]]; then
      log_ok "Dispositivo Brother detectado: USB ID ${BROTHER_VENDOR_ID}:${product_id}."
      log_info "El product ID (${product_id}) se usará para la regla udev; no va hardcodeado."
    else
      log_error "No hay ningún dispositivo Brother (vendor ${BROTHER_VENDOR_ID}) en el bus USB."
      log_error "Comprueba que la DCP-1602 está encendida y conectada por USB a la Pi."
      failures=$((failures + 1))
    fi
  else
    log_warn "Falta lsusb (paquete usbutils); no puedo comprobar el bus USB."
  fi

  # --- Convivencia con CUPS (impresión) ---------------------------------------
  # La DCP-1602 es UN solo dispositivo USB multifunción. El escáner usa SANE
  # (no CUPS), pero si en esta Pi corre CUPS para imprimir, ambas pilas hablan
  # al mismo dispositivo. Normalmente coexisten (interfaces USB separadas),
  # pero el módulo usblp o el backend usb de CUPS pueden acapararlo.
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet cups 2>/dev/null; then
    log_warn "CUPS está activo en esta máquina: la impresora y el escáner comparten el mismo dispositivo USB."
    log_warn "Suelen coexistir sin problema, pero si el escáner no aparece revisa la sección"
    log_warn "'Convivencia con CUPS' de docs/RUNBOOK-validacion.md (usblp / backend usb)."
  elif command -v dpkg >/dev/null 2>&1 && dpkg -s cups >/dev/null 2>&1; then
    log_info "CUPS está instalado pero no activo; sin conflicto por ahora."
  fi
  if lsmod 2>/dev/null | grep -q '^usblp'; then
    log_info "Módulo de kernel usblp cargado (normal si también se imprime por USB)."
  fi

  # --- Puertos web --------------------------------------------------------------
  local port label
  for port in "${SCANSERVJS_PORT}" "${AIRSANE_PORT}"; do
    if [[ "${port}" == "${SCANSERVJS_PORT}" ]]; then label="scanservjs"; else label="AirSane"; fi
    if port_listening "${port}"; then
      log_warn "El puerto ${port} (previsto para ${label}) ya está en uso."
      log_warn "Si no es de una instalación previa de este proyecto, cambia el puerto por variable de entorno."
    else
      log_ok "Puerto ${port} libre para ${label}."
    fi
  done
  log_info "Nota: CUPS usa el 631; no choca con ${SCANSERVJS_PORT}/${AIRSANE_PORT}."

  # --- Espacio en disco ----------------------------------------------------------
  local avail_kb
  avail_kb="$(df --output=avail -k / | tail -n 1 | tr -d ' ')"
  if [[ "${avail_kb}" -lt 1048576 ]]; then
    log_warn "Menos de 1 GB libre en /: la instalación (y una posible compilación) puede fallar."
  else
    log_ok "Espacio en disco suficiente: $((avail_kb / 1024)) MB libres en /."
  fi

  if [[ "${failures}" -gt 0 ]]; then
    die "Comprobaciones previas fallidas: ${failures}. Corrige lo anterior antes de instalar."
  fi
  log_ok "Comprobaciones previas superadas."
}

main "$@"
