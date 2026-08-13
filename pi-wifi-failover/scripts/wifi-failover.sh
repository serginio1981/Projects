#!/usr/bin/env bash
# wifi-failover — activa la WiFi cuando el cable de red no está conectado.
#
# Este archivo lo instala pi-wifi-failover/install.sh como
# /usr/local/sbin/wifi-failover y es autocontenido (no depende del
# repositorio). Lo invocan:
#   - El dispatcher de NetworkManager, en cada conexión/desconexión del
#     cable:            wifi-failover check
#   - La unidad systemd wifi-failover-boot.service, al arrancar (cubre el
#     arranque SIN cable, donde no hay evento de dispatcher):
#                       wifi-failover boot
#
# Modos (FAILOVER_MODE en /etc/default/wifi-failover):
#   exclusive  WiFi encendida SOLO cuando no hay cable (comportamiento pedido)
#   always     WiFi siempre encendida; con cable, el tráfico prefiere el cable
#              por métrica de ruta (NetworkManager: ethernet 100 < wifi 600)

set -euo pipefail

CONFIG_FILE="/etc/default/wifi-failover"

# Valores por defecto; el archivo de configuración los sobreescribe.
ETH_IFACE="eth0"
WLAN_IFACE="wlan0"
WIFI_PROFILE="wifi-failover"
FAILOVER_MODE="exclusive"
ETH_WAIT_SECONDS="15"

# shellcheck disable=SC1090
if [[ -r "${CONFIG_FILE}" ]]; then
  source "${CONFIG_FILE}"
fi

log() { logger -t wifi-failover -- "$*"; }

eth_has_carrier() {
  local carrier
  carrier="$(cat "/sys/class/net/${ETH_IFACE}/carrier" 2>/dev/null || echo 0)"
  [[ "${carrier}" == "1" ]]
}

wifi_profile_active() {
  nmcli -t -f NAME connection show --active 2>/dev/null | grep -qxF "${WIFI_PROFILE}"
}

wifi_up() {
  rfkill unblock wlan 2>/dev/null || true
  nmcli radio wifi on
  # El autoconnect de NetworkManager suele levantar el perfil solo en cuanto
  # la radio enciende; se le dan unos segundos antes de forzarlo.
  local _attempt
  for _attempt in 1 2 3 4 5; do
    if wifi_profile_active; then
      log "WiFi activa con el perfil ${WIFI_PROFILE}."
      return 0
    fi
    sleep 2
  done
  if nmcli connection up "${WIFI_PROFILE}" ifname "${WLAN_IFACE}" >/dev/null 2>&1; then
    log "WiFi activada manualmente con el perfil ${WIFI_PROFILE}."
  else
    log "ERROR: no pude activar el perfil ${WIFI_PROFILE}; revisa 'nmcli device wifi list' y journalctl -u NetworkManager."
  fi
}

wifi_off() {
  nmcli radio wifi off
  log "Cable de red presente: WiFi apagada (FAILOVER_MODE=exclusive)."
}

apply_state() {
  if eth_has_carrier; then
    if [[ "${FAILOVER_MODE}" == "exclusive" ]]; then
      wifi_off
    else
      log "Cable de red presente; FAILOVER_MODE=always: la WiFi se mantiene encendida."
      wifi_up
    fi
  else
    log "Sin cable en ${ETH_IFACE}: activando la WiFi."
    wifi_up
  fi
}

case "${1:-check}" in
  check)
    apply_state
    ;;
  boot)
    # Al arrancar, espera a que el enlace ethernet negocie (si hay cable)
    # antes de decidir; sin cable, el bucle agota la espera y activa la WiFi.
    _waited=0
    while [[ "${_waited}" -lt "${ETH_WAIT_SECONDS}" ]]; do
      if eth_has_carrier; then
        break
      fi
      sleep 1
      _waited=$((_waited + 1))
    done
    apply_state
    ;;
  *)
    echo "Uso: wifi-failover {check|boot}" >&2
    exit 64
    ;;
esac
