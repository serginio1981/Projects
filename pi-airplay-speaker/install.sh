#!/usr/bin/env bash
# install.sh — pi-airplay-speaker: convierte la Raspberry Pi en receptor
# AirPlay con shairport-sync (paquete oficial de Debian/Raspberry Pi OS).
#
# El iPhone/iPad/Mac verá la Pi en el menú AirPlay y podrá enviarle música.
# Requiere un parlante conectado a la Pi (jack 3.5mm, HDMI o USB): este
# script configura el receptor, no puede verificar que haya altavoz físico.
#
# Convive con el resto de la Pi: usa el avahi-daemon ya presente (el mismo
# que anuncia AirPrint) y consume muy poca RAM. La verificación final
# comprueba que el anuncio de AirPrint sigue publicado.
#
# Idempotente: no reinstala si ya está, y la configuración solo se
# reescribe si cambió (con respaldo .orig del archivo original).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly CONF_FILE="/etc/shairport-sync.conf"
readonly CONF_TEMPLATE="${SCRIPT_DIR}/templates/shairport-sync.conf.tmpl"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Instala y configura shairport-sync (receptor AirPlay).

Variables de entorno:
  AIRPLAY_NAME   Nombre en el menú AirPlay (actual: ${AIRPLAY_NAME})
  AUDIO_DEVICE   Dispositivo ALSA de salida; vacío = default del sistema.
                 Mira los disponibles con: aplay -l
                 Ejemplo jack 3.5mm de la Pi: AUDIO_DEVICE="hw:Headphones"

Ejemplos:
  sudo ./install.sh
  sudo AIRPLAY_NAME='Parlante Living' AUDIO_DEVICE='hw:Headphones' ./install.sh --yes
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

install_packages() {
  local missing=() pkg
  for pkg in shairport-sync alsa-utils; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    log_ok "Paquetes instalados: ${missing[*]}"
  else
    log_ok "shairport-sync y alsa-utils ya estaban instalados."
  fi
}

render_conf() {
  sed "s|@AIRPLAY_NAME@|${AIRPLAY_NAME}|g" "${CONF_TEMPLATE}"
  if [[ -n "${AUDIO_DEVICE}" ]]; then
    printf 'alsa = {\n  output_device = "%s";\n};\n' "${AUDIO_DEVICE}"
  fi
}

write_conf() {
  local rendered
  rendered="$(render_conf)"
  if [[ -f "${CONF_FILE}" ]] && [[ "$(cat "${CONF_FILE}")" == "${rendered}" ]]; then
    log_ok "Configuración ya al día: ${CONF_FILE}."
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${CONF_FILE}:"
    printf '%s\n' "${rendered}" >&2
    return 0
  fi
  if [[ -f "${CONF_FILE}" ]] && [[ ! -f "${CONF_FILE}.orig" ]]; then
    cp -a "${CONF_FILE}" "${CONF_FILE}.orig"
    log_info "Original respaldado en ${CONF_FILE}.orig."
  fi
  printf '%s\n' "${rendered}" >"${CONF_FILE}"
  log_ok "Configuración escrita: nombre AirPlay '${AIRPLAY_NAME}'${AUDIO_DEVICE:+, salida ${AUDIO_DEVICE}}."
}

verify() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  systemctl is-active --quiet shairport-sync \
    || die "shairport-sync no quedó activo. Diagnóstico: journalctl -u shairport-sync -n 50"
  log_ok "Servicio shairport-sync activo."

  # Versión y variante de protocolo: el paquete de Debian clásico es
  # AirPlay 1 (suficiente para enviar audio desde iPhone/Mac); las
  # compilaciones con AirPlay 2 lo indican en la salida de -V.
  local version
  version="$(shairport-sync -V 2>/dev/null | head -n 1)" || true
  if grep -qi 'AirPlay2' <<<"${version}"; then
    log_ok "Variante AirPlay 2 detectada: ${version}"
  else
    log_info "Versión instalada: ${version:-desconocida} (AirPlay clásico: el iPhone la ve y le envía audio igual)."
  fi

  if command -v avahi-browse >/dev/null 2>&1; then
    sleep 3
    if avahi-browse --terminate --parsable _raop._tcp 2>/dev/null | grep -q .; then
      log_ok "Receptor AirPlay anunciado por mDNS (_raop._tcp)."
    else
      log_warn "Aún no veo el anuncio _raop._tcp; dale unos segundos y comprueba: avahi-browse -rt _raop._tcp"
    fi
    # La regla de la casa: nada de lo que instalemos degrada la impresión.
    if avahi-browse --resolve --terminate --parsable _ipp._tcp 2>/dev/null | grep '^=' | grep -qF 'rp=printers/'; then
      log_ok "El anuncio AirPrint de la impresora sigue publicado."
    else
      log_warn "No veo el anuncio AirPrint: verifica el servidor de impresión (no debería estar relacionado con este cambio)."
    fi
  fi
}

main() {
  parse_flags "$@"
  require_root
  require_cmd dpkg apt-get systemctl

  log_info "pi-airplay-speaker — la Pi como receptor AirPlay"
  log_info "  Nombre AirPlay: ${AIRPLAY_NAME}"
  log_info "  Salida de audio: ${AUDIO_DEVICE:-(default del sistema)}"
  log_warn "Recuerda: hace falta un parlante conectado a la Pi (jack/HDMI/USB) para oír algo."

  if [[ "${DRY_RUN}" != "1" ]]; then
    confirm "¿Instalar y configurar el receptor AirPlay?" || die "Instalación cancelada."
  fi

  if ! systemctl is-active --quiet avahi-daemon 2>/dev/null && [[ "${DRY_RUN}" != "1" ]]; then
    die "avahi-daemon no está activo y AirPlay lo necesita para anunciarse. En esta Pi debería estarlo (AirPrint depende de él)."
  fi

  install_packages
  write_conf
  run systemctl enable --now shairport-sync
  if [[ "${DRY_RUN}" != "1" ]]; then
    run systemctl restart shairport-sync
  fi
  verify

  log_ok "Listo. En el iPhone: Centro de Control → icono AirPlay → '${AIRPLAY_NAME}'."
  if [[ "${DRY_RUN}" != "1" ]] && command -v aplay >/dev/null 2>&1; then
    log_info "Salidas de audio disponibles en esta Pi (para AUDIO_DEVICE si quieres forzar una):"
    aplay -l 2>/dev/null | grep '^card' >&2 || log_info "  (aplay no listó tarjetas)"
    log_info "Volumen: alsamixer (tecla F6 para elegir tarjeta)."
  fi
}

main "$@"
