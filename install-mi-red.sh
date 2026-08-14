#!/usr/bin/env bash
# install-mi-red.sh — instalador PERSONALIZADO de pi-wifi-failover con las
# credenciales de la red de Sergio ya incluidas.
#
# ⚠ CONTIENE UNA CREDENCIAL DE TU WIFI: no lo subas a ningún repositorio
#   (el repo Projects es PÚBLICO). Guárdalo solo en la Pi; el .gitignore del
#   proyecto ya lo excluye por nombre, no lo renombres.
#
# Uso en la Pi (junto a pi-wifi-failover/ o dentro de esa carpeta):
#   sudo ./install-mi-red.sh            # pedirá una confirmación
#   sudo ./install-mi-red.sh --yes      # sin preguntas
#   sudo ./install-mi-red.sh --dry-run  # solo muestra lo que haría

set -euo pipefail

# --- Credenciales de la red local -------------------------------------------
export WIFI_SSID='SERGIO ROOM_5G'
# NOTA: esto es la PSK derivada en hexadecimal (64 caracteres) que ya usabas;
# NetworkManager la acepta como clave WPA-PSK cruda. Una PSK se deriva de
# SSID + clave JUNTOS: solo es válida si se generó exactamente para
# "SERGIO ROOM_5G". Si la conexión falla en la autenticación, reemplaza el
# valor de abajo por tu clave WiFi en claro (entre comillas simples) y
# reejecuta este script: el perfil se actualiza solo.
export WIFI_PASSWORD='f31479530d3f7db46d6bd506216754eda7e814ba83c236a684541074a41b5ead'
export WIFI_COUNTRY='CL'

# --- Localizar el instalador base --------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CANDIDATES=(
  "${SCRIPT_DIR}/install.sh"
  "${SCRIPT_DIR}/pi-wifi-failover/install.sh"
  "${HOME}/Projects/pi-wifi-failover/install.sh"
)
INSTALLER=""
for candidate in "${CANDIDATES[@]}"; do
  if [[ -x "${candidate}" ]]; then
    INSTALLER="${candidate}"
    break
  fi
done
if [[ -z "${INSTALLER}" ]]; then
  echo "ERROR: no encuentro pi-wifi-failover/install.sh." >&2
  echo "Clona/actualiza el repo primero:  cd ~/Projects && git pull" >&2
  exit 1
fi

exec "${INSTALLER}" "$@"
