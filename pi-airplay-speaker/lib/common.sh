#!/usr/bin/env bash
# lib/common.sh — utilidades propias de pi-airplay-speaker: logging, dry-run
# y guards. Librería autocontenida: se carga con `source`, no se ejecuta, y
# no depende de ningún otro proyecto.

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: lib/common.sh es una librería; cárgala con 'source', no la ejecutes." >&2
  exit 64
fi

: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
# Nombre con el que la Pi aparece en el menú AirPlay del iPhone/Mac:
: "${AIRPLAY_NAME:=Parlante Pi}"
# Dispositivo ALSA de salida (vacío = el por defecto del sistema). Ejemplos
# según `aplay -l`: "hw:Headphones" (jack 3.5mm de la Pi), "hw:0", "hw:1".
: "${AUDIO_DEVICE:=}"

export DRY_RUN ASSUME_YES AIRPLAY_NAME AUDIO_DEVICE

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

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "$(printf '%q ' "$@")"
    return 0
  fi
  "$@"
}

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
