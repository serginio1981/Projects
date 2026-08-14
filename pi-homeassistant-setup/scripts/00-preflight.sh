#!/usr/bin/env bash
# 00-preflight.sh — verifica el entorno. NO modifica nada.
#
# La restricción número uno de este proyecto: la Pi de destino YA es un
# servidor de impresión AirPrint (CUPS + brlaser + Avahi) en uso diario y no
# puede degradarse. Este preflight lo detecta e informa, y ABORTA si
# encuentra una instalación de Home Assistant OS o Supervised (incompatibles
# con conservar el sistema anfitrión).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Comprobaciones previas (solo lectura):
  - Que NO exista Home Assistant OS/Supervised (aborta si lo hay)
  - Servidor de impresión presente (CUPS/Avahi): se informa y se protege
  - Arquitectura, RAM y disco (informa, no aborta)
  - Puerto ${HA_PORT} y estado previo de Docker
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

  log_info "Comprobaciones previas de pi-homeassistant-setup (nada se modifica)."

  # --- Home Assistant OS / Supervised: incompatibles, abortar ---------------
  # HA OS reemplaza el sistema completo y Supervised impone requisitos sobre
  # el anfitrión; cualquiera de los dos destruiría/alteraría el servidor de
  # impresión existente.
  local os_id
  os_id="$([[ -r /etc/os-release ]] && . /etc/os-release && echo "${ID:-}")" || os_id=""
  if [[ "${os_id}" == "haos" ]]; then
    die "Este sistema ES Home Assistant OS: aquí no hay servidor de impresión que conservar y este proyecto no aplica."
  fi
  if [[ -d /usr/share/hassio ]] \
    || systemctl list-unit-files 2>/dev/null | grep -q '^hassio-supervisor'; then
    die "Detectada una instalación de Home Assistant Supervised: incompatible con este proyecto. Aborto para no tocar nada."
  fi
  log_ok "Sin rastro de Home Assistant OS/Supervised: seguro continuar en modo Container."

  # --- Servidor de impresión: la carga a proteger -----------------------------
  local cups_active=0 avahi_active=0
  if systemctl is-active --quiet cups 2>/dev/null; then cups_active=1; fi
  if systemctl is-active --quiet avahi-daemon 2>/dev/null; then avahi_active=1; fi
  if [[ "${cups_active}" == "1" || "${avahi_active}" == "1" ]]; then
    log_ok "Servidor de impresión detectado (cups activo: ${cups_active}, avahi-daemon activo: ${avahi_active})."
    log_warn "Este servicio es la carga principal de la Pi y NO se tocará."
    log_warn "Recordatorio: el modo Home Assistant OS lo ELIMINARÍA por completo; por eso este proyecto usa el modo Container."
    if command -v lpstat >/dev/null 2>&1; then
      local queues
      queues="$(lpstat -p 2>/dev/null | awk '/^printer|^impresora/ {print $2}' | tr '\n' ' ')" || true
      [[ -n "${queues}" ]] && log_info "Colas de impresión presentes: ${queues}"
    fi
  else
    log_warn "No se detecta CUPS/avahi activos: no parece haber servidor de impresión que proteger en esta máquina."
  fi

  # --- Sistema y arquitectura ---------------------------------------------------
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    aarch64)
      log_ok "Arquitectura de 64 bits (${arch}): la esperada para la imagen de Home Assistant."
      ;;
    armv7l|armv6l)
      log_warn "Arquitectura de 32 bits (${arch}): el hardware objetivo es Raspberry Pi OS de 64 bits."
      log_warn "El repositorio apt de Docker para Debian y la imagen de HA asumen 64 bits; en 32 bits este instalador no está soportado."
      failures=$((failures + 1))
      ;;
    x86_64)
      log_info "Arquitectura x86_64: no es una Raspberry Pi, pero el modo Container funciona igual."
      ;;
    *)
      log_warn "Arquitectura ${arch} no prevista."
      ;;
  esac
  if [[ -r /proc/device-tree/model ]]; then
    local pi_model
    pi_model="$(tr -d '\0' </proc/device-tree/model)"
    log_ok "Modelo: ${pi_model}."
  fi

  # --- RAM y disco: informar, no abortar -----------------------------------------
  # 2 GB alcanzan para CUPS + Docker + HA, pero sin holgura.
  local mem_total_mb mem_avail_mb
  mem_total_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  mem_avail_mb="$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)"
  log_info "RAM total: ${mem_total_mb} MB; disponible ahora: ${mem_avail_mb} MB."
  if [[ "${mem_total_mb}" -le 2200 ]]; then
    log_warn "Con 2 GB de RAM el conjunto funciona pero SIN holgura: evita añadir más servicios pesados a esta Pi."
  fi
  if [[ "${mem_avail_mb}" -lt 500 ]]; then
    log_warn "Menos de 500 MB de RAM disponibles ahora mismo: Home Assistant puede arrancar lento o provocar swapping."
  fi

  local avail_kb avail_mb
  avail_kb="$(df --output=avail -k / | tail -n 1 | tr -d ' ')"
  avail_mb=$((avail_kb / 1024))
  log_info "Disco libre en /: ${avail_mb} MB."
  if [[ "${avail_mb}" -lt 5120 ]]; then
    log_warn "Menos de 5 GB libres: la imagen de HA (~1.5 GB) más su base de datos dejarán la microSD justa."
  fi

  # --- Puerto de Home Assistant ----------------------------------------------------
  # CUPS ocupa el 631; HA Container usa el ${HA_PORT} y ahí se mantiene.
  if port_listening "${HA_PORT}"; then
    if docker_ready && ha_container_running; then
      log_ok "El puerto ${HA_PORT} está en uso por el propio contenedor ${HA_CONTAINER_NAME} (reinstalación idempotente)."
    else
      log_error "El puerto ${HA_PORT} ya está ocupado por otro proceso (mira: ss -tlnp | grep ${HA_PORT})."
      failures=$((failures + 1))
    fi
  else
    log_ok "Puerto ${HA_PORT} libre para Home Assistant (CUPS sigue en el 631; no chocan)."
  fi

  # --- Docker previo -----------------------------------------------------------------
  if docker_ready; then
    log_info "Docker ya está instalado y activo: 10-docker.sh no lo reinstalará."
    if ha_container_exists; then
      log_info "El contenedor ${HA_CONTAINER_NAME} ya existe: el despliegue será una actualización idempotente."
    fi
  elif command -v docker >/dev/null 2>&1; then
    log_warn "Docker está instalado pero el daemon no responde (¿servicio parado?)."
  else
    log_info "Docker no está instalado: lo instalará 10-docker.sh."
  fi

  if [[ "${failures}" -gt 0 ]]; then
    die "Comprobaciones previas con ${failures} problemas bloqueantes. Corrige lo anterior antes de instalar."
  fi
  log_ok "Comprobaciones previas superadas."
}

main "$@"
