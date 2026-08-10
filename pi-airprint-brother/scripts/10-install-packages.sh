#!/usr/bin/env bash
# 10-install-packages.sh — instala CUPS, el driver brlaser, Avahi y Ghostscript.
#
# Idempotente: solo instala los paquetes que falten y solo habilita los
# servicios si no están ya activos.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

# printer-driver-brlaser: driver libre que implementa XL2HB, el lenguaje
# host-based propietario de la DCP-1600 series. Sin él la impresora no
# entiende nada de lo que se le envíe; por eso un print server USB genérico
# no sirve y el driver tiene que correr en la Pi.
readonly PACKAGES=(
  cups
  cups-filters
  printer-driver-brlaser
  avahi-daemon
  avahi-utils
  ghostscript
)

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Instala los paquetes necesarios y habilita los servicios cups y avahi-daemon.
Paquetes: ${PACKAGES[*]}
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
  require_root
  require_cmd dpkg apt-get systemctl

  # --- Paquetes ------------------------------------------------------------
  local missing=()
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
      log_ok "Paquete ya instalado: ${pkg}."
    else
      missing+=("${pkg}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    log_info "Paquetes pendientes de instalar: ${missing[*]}"
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    log_ok "Paquetes instalados."
  else
    log_ok "Todos los paquetes necesarios ya estaban instalados."
  fi

  # --- Servicios -----------------------------------------------------------
  local svc
  for svc in cups avahi-daemon; do
    if [[ "${DRY_RUN}" != "1" ]] && systemctl is-active --quiet "${svc}"; then
      log_ok "Servicio ya activo: ${svc}."
    else
      run systemctl enable --now "${svc}"
      log_ok "Servicio habilitado y arrancado: ${svc}."
    fi
  done

  # --- Grupo lpadmin para el usuario que invocó sudo -------------------------
  if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    if id -nG "${SUDO_USER}" | tr ' ' '\n' | grep -qxF lpadmin; then
      log_ok "El usuario ${SUDO_USER} ya pertenece al grupo lpadmin."
    else
      run usermod -aG lpadmin "${SUDO_USER}"
      log_ok "Usuario ${SUDO_USER} añadido al grupo lpadmin (aplica al reiniciar sesión)."
    fi
  fi

  state_mark "packages-installed"
  log_ok "Instalación de paquetes completada."
}

main "$@"
