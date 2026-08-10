#!/usr/bin/env bash
# lib/common.sh — utilidades compartidas: logging, dry-run, guards y estado.
#
# Este archivo es una librería: se carga con `source`, no se ejecuta.
# Todos los scripts del proyecto lo cargan al inicio.

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: lib/common.sh es una librería; cárgala con 'source', no la ejecutes." >&2
  exit 64
fi

# ---------------------------------------------------------------------------
# Configuración (sobreescribible por variables de entorno)
# ---------------------------------------------------------------------------
: "${QUEUE_NAME:=Brother_DCP1602}"
: "${QUEUE_LOCATION:=Oficina}"
: "${PPD_OVERRIDE:=}"
: "${URF_VALUE:=DM3}"
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${SKIP_AIRPRINT:=0}"
: "${STATE_FILE:=/var/lib/pi-airprint-brother/state}"

export QUEUE_NAME QUEUE_LOCATION PPD_OVERRIDE URF_VALUE
export DRY_RUN ASSUME_YES SKIP_AIRPRINT STATE_FILE

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
# run CMD ARGS...
# En modo normal ejecuta el comando tal cual. Con DRY_RUN=1 solo lo muestra.
# Usar únicamente para comandos que MODIFICAN el sistema; los comandos de
# solo lectura (detección) se ejecutan siempre directamente.
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
      die "Falta el comando requerido: ${cmd}. Ejecuta antes scripts/10-install-packages.sh"
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

# confirm PREGUNTA
# Devuelve 0 si el usuario acepta. ASSUME_YES=1 la responde automáticamente.
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

# confirm_visual PREGUNTA
# Igual que confirm, pero NUNCA se responde sola: exige a una persona delante.
# Se usa para la verificación física de la hoja impresa (90-verify.sh).
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
# Comprobaciones mDNS compartidas (usadas por 30-airprint.sh y 90-verify.sh)
# ---------------------------------------------------------------------------
# mdns_records_for_queue TIPO_SERVICIO
# Imprime los registros resueltos de avahi-browse cuyo TXT rp= apunta a la cola.
mdns_records_for_queue() {
  local service_type="${1:?falta el tipo de servicio}"
  avahi-browse --resolve --terminate --parsable "${service_type}" 2>/dev/null \
    | grep '^=' | grep -F "rp=printers/${QUEUE_NAME}" || true
}

# mdns_has_urf: 0 si el anuncio _ipp._tcp de la cola trae un TXT URF NO vacío.
mdns_has_urf() {
  local records
  records="$(mdns_records_for_queue "_ipp._tcp")"
  [[ -n "${records}" ]] && grep -Eq '"URF=[^"]+"' <<<"${records}"
}

# mdns_has_universal_subtype: 0 si la cola se anuncia bajo el subtipo
# _universal._sub._ipp._tcp (obligatorio para que iOS la liste).
mdns_has_universal_subtype() {
  local records
  records="$(mdns_records_for_queue "_universal._sub._ipp._tcp")"
  [[ -n "${records}" ]]
}
