#!/usr/bin/env bash
# rebuild-pi.sh — reconstrucción SILENCIOSA de toda la pila de la Pi.
#
# Reinstala en orden, sin preguntas (exporta ASSUME_YES=1 para todos los
# proyectos): servidor de impresión AirPrint → (opcional) failover WiFi →
# Home Assistant → Matter Server → receptor AirPlay, y restaura la
# configuración de Home Assistant desde un respaldo si se indica.
#
# Lo ÚNICO que no se automatiza, por diseño: la validación física de la
# impresora (hoja real legible). El script termina recordándola.
#
# Uso típico tras grabar una SD nueva (Raspberry Pi OS 64 bits + SSH):
#   sudo apt-get update && sudo apt-get install -y git
#   git clone https://github.com/serginio1981/Projects.git ~/Projects
#   cd ~/Projects
#   sudo RESTORE_HA_TGZ=/home/serginio/homeassistant.tgz ./rebuild-pi.sh
#
# Interruptores (variable=0 omite la etapa):
#   INSTALL_AIRPRINT=1  INSTALL_HOMEASSISTANT=1  INSTALL_MATTER=1
#   INSTALL_AIRPLAY=1   INSTALL_WIFI_FAILOVER=0
#   (el failover requiere además WIFI_SSID y WIFI_PASSWORD; va apagado por
#    defecto porque el Imager ya deja el WiFi configurado)
#   RESTORE_HA_TGZ=/ruta/homeassistant.tgz   respaldo a restaurar (opcional)
# Las variables propias de cada proyecto (QUEUE_NAME, HA_TZ, AIRPLAY_NAME,
# AUDIO_DEVICE, etc.) también se respetan si se exportan.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

: "${INSTALL_AIRPRINT:=1}"
: "${INSTALL_WIFI_FAILOVER:=0}"
: "${INSTALL_HOMEASSISTANT:=1}"
: "${INSTALL_MATTER:=1}"
: "${INSTALL_AIRPLAY:=1}"
: "${RESTORE_HA_TGZ:=}"
: "${HA_BASE_DIR:=/opt/homeassistant}"
: "${HA_CONTAINER_NAME:=homeassistant}"

export ASSUME_YES=1

banner() { printf '\n════ %s ════\n' "$*" >&2; }
fail()   { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecútalo con sudo: sudo ./rebuild-pi.sh"

if [[ -n "${RESTORE_HA_TGZ}" && ! -f "${RESTORE_HA_TGZ}" ]]; then
  fail "No existe el respaldo indicado en RESTORE_HA_TGZ: ${RESTORE_HA_TGZ}"
fi

if [[ "${INSTALL_AIRPRINT}" == "1" ]]; then
  banner "1/5 Servidor de impresión AirPrint"
  "${REPO_DIR}/pi-airprint-brother/scripts/00-preflight.sh" --yes
  "${REPO_DIR}/pi-airprint-brother/scripts/10-install-packages.sh" --yes
  "${REPO_DIR}/pi-airprint-brother/scripts/20-add-queue.sh" --yes
  "${REPO_DIR}/pi-airprint-brother/scripts/30-airprint.sh" --yes
  # Solo comprobaciones: la página de prueba con confirmación visual queda
  # como paso manual final (es el criterio de éxito y exige una persona).
  "${REPO_DIR}/pi-airprint-brother/scripts/90-verify.sh" --checks-only --yes
fi

if [[ "${INSTALL_WIFI_FAILOVER}" == "1" ]]; then
  banner "2/5 Failover WiFi"
  [[ -n "${WIFI_SSID:-}" && -n "${WIFI_PASSWORD:-}" ]] \
    || fail "INSTALL_WIFI_FAILOVER=1 requiere WIFI_SSID y WIFI_PASSWORD en el entorno."
  "${REPO_DIR}/pi-wifi-failover/install.sh" --yes
else
  printf '\n(2/5 Failover WiFi omitido: INSTALL_WIFI_FAILOVER=0)\n' >&2
fi

if [[ "${INSTALL_HOMEASSISTANT}" == "1" ]]; then
  banner "3/5 Home Assistant Container"
  "${REPO_DIR}/pi-homeassistant-setup/install.sh" --yes

  if [[ -n "${RESTORE_HA_TGZ}" ]]; then
    banner "3b/5 Restaurando configuración de Home Assistant"
    docker stop "${HA_CONTAINER_NAME}"
    # El respaldo se creó con: tar czf ... -C .../opt homeassistant
    # por lo que contiene el directorio homeassistant/ completo.
    tar xzf "${RESTORE_HA_TGZ}" -C "$(dirname "${HA_BASE_DIR}")"
    docker start "${HA_CONTAINER_NAME}"
    printf '[OK] Configuración de HA restaurada desde %s\n' "${RESTORE_HA_TGZ}" >&2
  fi
fi

if [[ "${INSTALL_MATTER}" == "1" ]]; then
  banner "4/5 Matter Server"
  "${REPO_DIR}/pi-homeassistant-setup/scripts/40-matter-server.sh" --yes
fi

if [[ "${INSTALL_AIRPLAY}" == "1" ]]; then
  banner "5/5 Receptor AirPlay"
  "${REPO_DIR}/pi-airplay-speaker/install.sh" --yes
fi

banner "Reconstrucción terminada"
printf 'Queda UN paso manual, el criterio de éxito de la impresora:\n' >&2
printf '  sudo %s/pi-airprint-brother/scripts/90-verify.sh\n' "${REPO_DIR}" >&2
printf '(imprime una página de prueba y pide confirmar que salió legible)\n' >&2
