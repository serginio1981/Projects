#!/usr/bin/env bash
# install.sh — pi-wifi-failover: WiFi automática cuando no hay cable de red.
#
# Qué hace:
#   1. Corrige las causas típicas de "la WiFi no funciona" en Raspberry Pi OS:
#      fija el país WiFi (sin él, la radio queda bloqueada por rfkill) y
#      desbloquea rfkill.
#   2. Crea (o actualiza) el perfil WiFi en NetworkManager con tu SSID/clave.
#   3. Instala el mecanismo de failover:
#      - /usr/local/sbin/wifi-failover               (lógica)
#      - dispatcher de NetworkManager                (cable puesto/quitado)
#      - unidad systemd wifi-failover-boot.service   (arranque sin cable)
#
# Requiere Raspberry Pi OS Bookworm o posterior (NetworkManager). Idempotente.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Configuración (sobreescribible por variable de entorno) -----------------
: "${WIFI_SSID:=}"
: "${WIFI_PASSWORD:=}"
: "${WIFI_COUNTRY:=CL}"
: "${WIFI_PROFILE:=wifi-failover}"
: "${ETH_IFACE:=eth0}"
: "${WLAN_IFACE:=wlan0}"
: "${FAILOVER_MODE:=exclusive}"
: "${ETH_WAIT_SECONDS:=15}"

readonly RUNTIME_TARGET="/usr/local/sbin/wifi-failover"
readonly DISPATCHER_TARGET="/etc/NetworkManager/dispatcher.d/90-wifi-failover"
readonly UNIT_TARGET="/etc/systemd/system/wifi-failover-boot.service"
readonly CONFIG_TARGET="/etc/default/wifi-failover"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Activa la WiFi de la Raspberry Pi automáticamente cuando el cable de red no
está conectado (al arrancar sin cable y al desconectarlo en caliente).

Variables de entorno:
  WIFI_SSID         Nombre de la red WiFi (se pregunta si falta)
  WIFI_PASSWORD     Clave de la red (se pregunta oculta si falta)
  WIFI_COUNTRY      País WiFi, obligatorio para desbloquear la radio (default: CL)
  WIFI_PROFILE      Nombre del perfil en NetworkManager (default: wifi-failover)
  ETH_IFACE         Interfaz de cable (default: eth0)
  WLAN_IFACE        Interfaz WiFi (default: wlan0)
  FAILOVER_MODE     exclusive: WiFi solo sin cable (default)
                    always:    WiFi siempre encendida; el cable tiene prioridad
                               de ruta cuando está puesto
  ETH_WAIT_SECONDS  Espera del enlace de cable al arrancar (default: 15)

Ejemplos:
  sudo WIFI_SSID='SERGIO ROOM_5G' ./install.sh
  sudo FAILOVER_MODE=always ./install.sh --yes
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

preflight() {
  require_cmd rfkill install
  if ! command -v nmcli >/dev/null 2>&1; then
    die "No hay nmcli: este proyecto requiere NetworkManager (Raspberry Pi OS Bookworm o posterior). En Bullseye/dhcpcd no aplica."
  fi
  if [[ "${DRY_RUN}" != "1" ]] && ! systemctl is-active --quiet NetworkManager; then
    die "NetworkManager no está activo: ¿esta imagen usa dhcpcd? Este proyecto requiere Bookworm o posterior."
  fi
  if [[ ! -e "/sys/class/net/${WLAN_IFACE}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_warn "No existe la interfaz ${WLAN_IFACE} en esta máquina (aceptable en --dry-run)."
    else
      die "No existe la interfaz ${WLAN_IFACE}. ¿Modelo de Pi sin WiFi, o nombre distinto? (ajusta WLAN_IFACE)"
    fi
  fi
  if [[ ! -e "/sys/class/net/${ETH_IFACE}" ]] && [[ "${DRY_RUN}" != "1" ]]; then
    die "No existe la interfaz ${ETH_IFACE} (ajusta ETH_IFACE)."
  fi
  case "${FAILOVER_MODE}" in
    exclusive|always) ;;
    *) die "FAILOVER_MODE debe ser 'exclusive' o 'always' (actual: ${FAILOVER_MODE})." ;;
  esac
}

ask_credentials() {
  if [[ -z "${WIFI_SSID}" ]]; then
    if [[ ! -t 0 ]]; then
      die "Falta WIFI_SSID y no hay terminal para preguntarlo. Pásalo por variable de entorno."
    fi
    read -r -p "Nombre de la red WiFi (SSID): " WIFI_SSID
    [[ -n "${WIFI_SSID}" ]] || die "El SSID no puede estar vacío."
  fi
  if [[ -z "${WIFI_PASSWORD}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_warn "Sin WIFI_PASSWORD en --dry-run: se usa un marcador."
      WIFI_PASSWORD="********"
      return 0
    fi
    if [[ ! -t 0 ]]; then
      die "Falta WIFI_PASSWORD y no hay terminal para preguntarla. Pásala por variable de entorno."
    fi
    read -r -s -p "Clave de '${WIFI_SSID}' (no se muestra al escribir): " WIFI_PASSWORD
    echo >&2
    [[ -n "${WIFI_PASSWORD}" ]] || die "La clave no puede estar vacía."
  fi
}

set_wifi_country() {
  # Sin país configurado, Raspberry Pi OS deja la radio WiFi bloqueada por
  # rfkill: es la causa más común de "no funciona el WiFi" en instalación
  # headless.
  if command -v raspi-config >/dev/null 2>&1; then
    run raspi-config nonint do_wifi_country "${WIFI_COUNTRY}"
    log_ok "País WiFi fijado en ${WIFI_COUNTRY} (persistente, vía raspi-config)."
  else
    run iw reg set "${WIFI_COUNTRY}"
    log_warn "Sin raspi-config: país aplicado con 'iw reg set ${WIFI_COUNTRY}', que NO persiste tras reiniciar."
    log_warn "En Raspberry Pi OS instala raspi-config; en otros Debian configura cfg80211/regulatory."
  fi
  run rfkill unblock wlan
  log_ok "Radio WiFi desbloqueada (rfkill)."
}

set_wifi_profile() {
  # La clave nunca se pasa por run(): en --dry-run se mostraría en claro.
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "nmcli connection add/modify '${WIFI_PROFILE}' ssid '${WIFI_SSID}' psk '********' autoconnect yes"
    return 0
  fi
  if nmcli -t -f NAME connection show | grep -qxF "${WIFI_PROFILE}"; then
    nmcli connection modify "${WIFI_PROFILE}" \
      802-11-wireless.ssid "${WIFI_SSID}" \
      wifi-sec.key-mgmt wpa-psk \
      wifi-sec.psk "${WIFI_PASSWORD}" \
      connection.interface-name "${WLAN_IFACE}" \
      connection.autoconnect yes \
      connection.autoconnect-priority 10
    log_ok "Perfil ${WIFI_PROFILE} actualizado (SSID: ${WIFI_SSID})."
  else
    nmcli connection add type wifi \
      con-name "${WIFI_PROFILE}" \
      ifname "${WLAN_IFACE}" \
      ssid "${WIFI_SSID}" \
      -- \
      wifi-sec.key-mgmt wpa-psk \
      wifi-sec.psk "${WIFI_PASSWORD}" \
      connection.autoconnect yes \
      connection.autoconnect-priority 10 >/dev/null
    log_ok "Perfil ${WIFI_PROFILE} creado (SSID: ${WIFI_SSID})."
  fi
}

verify_ssid_visible() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  nmcli radio wifi on
  nmcli device wifi rescan 2>/dev/null || true
  sleep 4
  if nmcli -t -f SSID device wifi list 2>/dev/null | grep -qxF "${WIFI_SSID}"; then
    log_ok "La red '${WIFI_SSID}' es visible desde esta Pi."
  else
    log_warn "La red '${WIFI_SSID}' NO aparece en el escaneo. Causas típicas:"
    log_warn "  - Red de 5 GHz con una Pi sin radio de 5 GHz (Zero W, 3B o anterior): usa la SSID de 2.4 GHz."
    log_warn "  - SSID mal escrito (es sensible a mayúsculas y espacios)."
    log_warn "  - Señal insuficiente donde está la Pi."
    log_warn "El failover queda instalado igualmente; corrige la red y prueba de nuevo."
  fi
}

write_config() {
  local content
  content="# /etc/default/wifi-failover — generado por pi-wifi-failover/install.sh
ETH_IFACE=\"${ETH_IFACE}\"
WLAN_IFACE=\"${WLAN_IFACE}\"
WIFI_PROFILE=\"${WIFI_PROFILE}\"
FAILOVER_MODE=\"${FAILOVER_MODE}\"
ETH_WAIT_SECONDS=\"${ETH_WAIT_SECONDS}\""
  if [[ -f "${CONFIG_TARGET}" ]] && [[ "$(cat "${CONFIG_TARGET}")" == "${content}" ]]; then
    log_ok "Configuración ya al día: ${CONFIG_TARGET}."
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${CONFIG_TARGET}:"
    printf '%s\n' "${content}" >&2
    return 0
  fi
  printf '%s\n' "${content}" >"${CONFIG_TARGET}"
  chmod 0644 "${CONFIG_TARGET}"
  log_ok "Configuración escrita en ${CONFIG_TARGET}."
}

install_files() {
  run install -m 0755 "${SCRIPT_DIR}/scripts/wifi-failover.sh" "${RUNTIME_TARGET}"
  log_ok "Lógica instalada en ${RUNTIME_TARGET}."

  local rendered
  rendered="$(sed "s/@ETH_IFACE@/${ETH_IFACE}/g" "${SCRIPT_DIR}/templates/90-wifi-failover.dispatcher.tmpl")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${DISPATCHER_TARGET} (dispatcher para ${ETH_IFACE})."
  else
    printf '%s\n' "${rendered}" >"${DISPATCHER_TARGET}"
    # NetworkManager exige que los dispatchers sean de root y no escribibles
    # por el grupo; si no, los ignora en silencio.
    chown root:root "${DISPATCHER_TARGET}"
    chmod 0755 "${DISPATCHER_TARGET}"
    log_ok "Dispatcher instalado: ${DISPATCHER_TARGET}."
  fi

  run install -m 0644 "${SCRIPT_DIR}/templates/wifi-failover-boot.service.tmpl" "${UNIT_TARGET}"
  run systemctl daemon-reload
  run systemctl enable wifi-failover-boot.service
  log_ok "Unidad de arranque habilitada: wifi-failover-boot.service."
}

main() {
  parse_flags "$@"
  require_root
  preflight
  ask_credentials

  log_info "pi-wifi-failover — WiFi automática sin cable de red"
  log_info "  SSID:    ${WIFI_SSID}"
  log_info "  País:    ${WIFI_COUNTRY}"
  log_info "  Modo:    ${FAILOVER_MODE}"
  log_info "  Cable:   ${ETH_IFACE} / WiFi: ${WLAN_IFACE}"

  if [[ "${DRY_RUN}" != "1" ]]; then
    confirm "¿Configurar la WiFi e instalar el failover?" || die "Instalación cancelada."
  fi

  set_wifi_country
  set_wifi_profile
  verify_ssid_visible
  write_config
  install_files

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_ok "Dry-run terminado: nada se modificó."
    return 0
  fi

  # Aplica el estado ahora mismo. Con cable puesto y modo exclusive, esto
  # APAGA la radio WiFi: si tu SSH actual va por WiFi, se cortará (por cable
  # no afecta).
  log_info "Aplicando el estado actual del cable..."
  "${RUNTIME_TARGET}" check || true

  log_ok "Instalación terminada."
  log_info "Prueba de fuego: apaga la Pi, quita el cable de red, enciéndela y"
  log_info "en ~1 minuto debería aparecer en tu WiFi (busca su IP en el router o usa el hostname .local)."
  log_info "Registros del mecanismo: journalctl -t wifi-failover"
}

main "$@"
