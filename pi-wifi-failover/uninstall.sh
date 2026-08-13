#!/usr/bin/env bash
# uninstall.sh — revierte todo lo que instala pi-wifi-failover.
#
# Deja la radio WiFi ENCENDIDA al terminar (para no dejar la Pi inalcanzable
# si en ese momento no hay cable). El perfil WiFi de NetworkManager solo se
# borra con --purge-profile.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

: "${WIFI_PROFILE:=wifi-failover}"

readonly RUNTIME_TARGET="/usr/local/sbin/wifi-failover"
readonly DISPATCHER_TARGET="/etc/NetworkManager/dispatcher.d/90-wifi-failover"
readonly UNIT_TARGET="/etc/systemd/system/wifi-failover-boot.service"
readonly CONFIG_TARGET="/etc/default/wifi-failover"

usage() {
  cat <<EOF
Uso: ${0##*/} [--purge-profile] [--dry-run] [--yes] [--help]

Desinstala el mecanismo de failover (dispatcher, unidad systemd, lógica y
configuración). Con --purge-profile borra también el perfil WiFi
'${WIFI_PROFILE}' de NetworkManager (la Pi olvidará la red).
EOF
}

PURGE_PROFILE=0

parse_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --purge-profile) PURGE_PROFILE=1 ;;
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
    confirm "¿Desinstalar el failover WiFi?" || die "Desinstalación cancelada."
  fi

  if [[ "${DRY_RUN}" != "1" ]] && systemctl list-unit-files wifi-failover-boot.service >/dev/null 2>&1; then
    run systemctl disable --now wifi-failover-boot.service 2>/dev/null || true
  fi
  run rm -f "${UNIT_TARGET}"
  run systemctl daemon-reload
  run rm -f "${DISPATCHER_TARGET}"
  run rm -f "${RUNTIME_TARGET}"
  run rm -f "${CONFIG_TARGET}"
  log_ok "Mecanismo de failover eliminado."

  if [[ "${PURGE_PROFILE}" == "1" ]]; then
    if command -v nmcli >/dev/null 2>&1 && nmcli -t -f NAME connection show | grep -qxF "${WIFI_PROFILE}"; then
      run nmcli connection delete "${WIFI_PROFILE}"
      log_ok "Perfil WiFi ${WIFI_PROFILE} eliminado de NetworkManager."
    else
      log_info "No existe el perfil ${WIFI_PROFILE}; nada que borrar."
    fi
  else
    log_info "El perfil WiFi ${WIFI_PROFILE} se conserva (bórralo con --purge-profile)."
  fi

  # Nunca dejar la radio apagada al desinstalar: si el modo era exclusive y
  # había cable, quedaría off y una Pi sin cable sería inalcanzable.
  if command -v nmcli >/dev/null 2>&1; then
    run nmcli radio wifi on
    log_ok "Radio WiFi dejada encendida."
  fi

  log_ok "Desinstalación terminada."
}

main "$@"
