#!/usr/bin/env bash
# uninstall.sh — revierte pi-airplay-speaker por completo.
# No toca avahi-daemon (lo comparten AirPrint y Home Assistant).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Detiene y desinstala shairport-sync y restaura la configuración original si
existe el respaldo .orig. No toca avahi ni el servidor de impresión.
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

  if [[ "${DRY_RUN}" != "1" ]]; then
    confirm "¿Desinstalar el receptor AirPlay?" || die "Desinstalación cancelada."
  fi

  if systemctl list-unit-files shairport-sync.service >/dev/null 2>&1; then
    run systemctl disable --now shairport-sync 2>/dev/null || true
  fi
  if [[ -f /etc/shairport-sync.conf.orig ]]; then
    run mv /etc/shairport-sync.conf.orig /etc/shairport-sync.conf
    log_ok "Configuración original restaurada."
  fi
  if dpkg -s shairport-sync >/dev/null 2>&1; then
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y shairport-sync
    run apt-get autoremove -y
  fi
  log_ok "Receptor AirPlay desinstalado. AirPrint y Home Assistant no se tocaron."
}

main "$@"
