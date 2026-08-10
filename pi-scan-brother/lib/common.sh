#!/usr/bin/env bash
# lib/common.sh — utilidades propias de pi-scan-brother: logging, dry-run,
# guards, estado y detección de hardware.
#
# Librería autocontenida de ESTE proyecto: se carga con `source`, nunca se
# ejecuta directamente y no depende de ningún otro repositorio.

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: lib/common.sh es una librería; cárgala con 'source', no la ejecutes." >&2
  exit 64
fi

# ---------------------------------------------------------------------------
# Configuración (todo sobreescribible por variables de entorno)
# ---------------------------------------------------------------------------
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${SKIP_AIRSANE:=0}"
: "${SKIP_SCANSERVJS:=0}"
: "${AIRSANE_PORT:=8090}"
: "${SCANSERVJS_PORT:=8080}"
: "${SCAN_RESOLUTION:=150}"
: "${SCAN_TEST_DIR:=/var/lib/pi-scan-brother/test-scans}"
: "${STATE_FILE:=/var/lib/pi-scan-brother/state}"
# Repositorios upstream (parametrizados, no hardcodeados en los scripts):
: "${BRSCAN_REPO:=dmikushin/brscan}"
: "${AIRSANE_REPO:=SimulPiscator/AirSane}"
: "${SCANSERVJS_REPO:=sbs20/scanservjs}"
# USB ID de referencia de la DCP-1510 (mismo motor que la DCP-1602). Se usa
# SOLO como último recurso en --dry-run sin hardware presente; con hardware
# real el product ID siempre se detecta en runtime con lsusb.
: "${BROTHER_VENDOR_ID:=04f9}"
: "${FALLBACK_PRODUCT_ID:=02d0}"

export DRY_RUN ASSUME_YES SKIP_AIRSANE SKIP_SCANSERVJS
export AIRSANE_PORT SCANSERVJS_PORT SCAN_RESOLUTION SCAN_TEST_DIR STATE_FILE
export BRSCAN_REPO AIRSANE_REPO SCANSERVJS_REPO
export BROTHER_VENDOR_ID FALLBACK_PRODUCT_ID

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  _c_red=$'\e[31m'; _c_green=$'\e[32m'; _c_yellow=$'\e[33m'
  _c_blue=$'\e[34m'; _c_dim=$'\e[2m'; _c_reset=$'\e[0m'
else
  _c_red=""; _c_green=""; _c_yellow=""; _c_blue=""; _c_dim=""; _c_reset=""
fi

log_info() { printf '%s[INFO]%s  %s\n' "${_c_blue}" "${_c_reset}" "$*" >&2; }
log_ok()   { printf '%s[OK]%s    %s\n' "${_c_green}" "${_c_reset}" "$*" >&2; }
log_warn() { printf '%s[AVISO]%s %s\n' "${_c_yellow}" "${_c_reset}" "$*" >&2; }
log_error(){ printf '%s[ERROR]%s %s\n' "${_c_red}" "${_c_reset}" "$*" >&2; }
log_dry()  { printf '%s[DRY]%s   %s\n' "${_c_dim}" "${_c_reset}" "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# Dry-run
# ---------------------------------------------------------------------------
# run CMD ARGS... — ejecuta el comando, o solo lo muestra con DRY_RUN=1.
# Úsalo solo con comandos que MODIFICAN el sistema; la detección (solo
# lectura) se ejecuta siempre.
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "$(printf '%q ' "$@")"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      die "Falta el comando requerido: ${cmd}."
    fi
  done
}

require_root() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Este script necesita privilegios de root. Vuelve a ejecutarlo con sudo."
  fi
}

# confirm PREGUNTA — 0 si el usuario acepta; ASSUME_YES=1 responde sola.
confirm() {
  local prompt="${1:-¿Continuar?}"
  local reply
  if [[ "${ASSUME_YES}" == "1" ]]; then
    log_info "${prompt} — respondido automáticamente con 'sí' (--yes)."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log_error "Sesión no interactiva y sin --yes: no puedo pedir confirmación."
    return 1
  fi
  read -r -p "${prompt} [s/N] " reply
  [[ "${reply}" =~ ^[sSyY]$ ]]
}

# confirm_visual PREGUNTA — como confirm, pero NUNCA se responde sola (ni con
# --yes): exige a una persona mirando el resultado. Es la base del criterio de
# éxito del proyecto: un archivo escaneado legible.
confirm_visual() {
  local prompt="${1:?falta la pregunta}"
  local reply
  if [[ ! -t 0 ]]; then
    log_error "La confirmación visual requiere una terminal interactiva."
    return 2
  fi
  read -r -p "${prompt} [s/N] " reply
  [[ "${reply}" =~ ^[sSyY]$ ]]
}

# ---------------------------------------------------------------------------
# Estado (pasos completados entre ejecuciones)
# ---------------------------------------------------------------------------
state_mark() {
  local step="${1:?falta el nombre del paso}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  if ! mkdir -p "$(dirname "${STATE_FILE}")" 2>/dev/null; then
    log_warn "No pude escribir el estado en ${STATE_FILE} (sin permisos); continúo sin registrarlo."
    return 0
  fi
  touch "${STATE_FILE}"
  if ! grep -qxF "${step}" "${STATE_FILE}"; then
    echo "${step}" >>"${STATE_FILE}"
  fi
}

state_done() {
  local step="${1:?falta el nombre del paso}"
  [[ -f "${STATE_FILE}" ]] && grep -qxF "${step}" "${STATE_FILE}"
}

state_reset() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "rm -f ${STATE_FILE}"
    return 0
  fi
  rm -f "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Detección de hardware y red
# ---------------------------------------------------------------------------
# detect_brother_product_id — imprime el product ID USB (4 hex) del primer
# dispositivo Brother conectado. El product ID varía por modelo, así que
# SIEMPRE se detecta en runtime; nunca va hardcodeado.
detect_brother_product_id() {
  local line
  line="$(lsusb -d "${BROTHER_VENDOR_ID}:" 2>/dev/null | head -n 1)" || true
  if [[ -z "${line}" ]]; then
    return 1
  fi
  sed -n "s/.*ID ${BROTHER_VENDOR_ID}:\([0-9a-fA-F]\{4\}\).*/\1/p" <<<"${line}"
}

# port_listening PUERTO — 0 si algo escucha en TCP en ese puerto.
port_listening() {
  local port="${1:?falta el puerto}"
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
}

# http_responds PUERTO — 0 si un servidor HTTP local responde en ese puerto
# (cualquier código HTTP cuenta como respuesta; un 404 sigue siendo un
# servidor vivo).
http_responds() {
  local port="${1:?falta el puerto}"
  local code
  code="$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${port}/" || true)"
  [[ -n "${code}" && "${code}" != "000" ]]
}

# arch_label — imprime la etiqueta de arquitectura usada por los binarios de
# los GitHub Releases (amd64/arm64/armv7) a partir de uname -m.
arch_label() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l|armv7*) echo "armv7" ;;
    *) return 1 ;;
  esac
}

# github_latest_release_json REPO — imprime el JSON del último release.
github_latest_release_json() {
  local repo="${1:?falta el repo}"
  curl -fsSL --max-time 30 "https://api.github.com/repos/${repo}/releases/latest"
}

# github_release_asset_urls JSON — extrae las URLs de descarga de los assets.
github_release_asset_urls() {
  grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4
}
