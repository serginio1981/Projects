#!/usr/bin/env bash
# 20-verify-sane.sh — valida el backend SANE con un ESCANEO REAL.
#
# Que `scanimage -L` liste el dispositivo NO es éxito y aquí no se reporta
# como tal: solo demuestra que el backend carga. El criterio de éxito del
# proyecto es un archivo escaneado que se abre y se ve legible, con
# confirmación visual explícita de una persona.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: ${0##*/} [--list-only] [--dry-run] [--yes] [--help]

1. Lista los dispositivos SANE (scanimage -L) — comprobación previa, NO éxito.
2. Hace un escaneo real a archivo en \${SCAN_TEST_DIR} (${SCAN_TEST_DIR}).
3. Pide confirmación visual de que el archivo se abre y se ve legible.

--list-only se queda en el paso 1 (útil para diagnóstico rápido).
La confirmación visual nunca se responde sola, ni con --yes.

Variables: SCAN_TEST_DIR, SCAN_RESOLUTION (actual: ${SCAN_RESOLUTION} dpi)
EOF
}

LIST_ONLY=0

parse_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --list-only) LIST_ONLY=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Opción no reconocida: ${arg} (usa --help)" ;;
    esac
  done
}

detect_sane_device() {
  local listing device
  listing="$(scanimage -L 2>/dev/null)" || true
  if [[ -z "${listing}" ]] || grep -qi 'No scanners were identified' <<<"${listing}"; then
    return 1
  fi
  # Formato de scanimage -L: device `brother4:bus1;dev1' is a Brother ...
  device="$(awk '/^device/ {print $2}' <<<"${listing}" | tr -d '`'\''' | grep -i 'brother' | head -n 1)" || true
  [[ -n "${device}" ]] && echo "${device}"
}

do_scan() {
  local device="$1" outfile="$2"
  # --format=png requiere una versión moderna de sane-utils; si falla se
  # reintenta con pnm (formato soportado desde siempre por scanimage).
  if scanimage -d "${device}" --format=png --resolution "${SCAN_RESOLUTION}" >"${outfile}" 2>/dev/null; then
    return 0
  fi
  log_warn "El formato png falló; reintento en formato pnm."
  outfile="${outfile%.png}.pnm"
  scanimage -d "${device}" --format=pnm --resolution "${SCAN_RESOLUTION}" >"${outfile}"
  SCAN_RESULT_FILE="${outfile}"
}

main() {
  parse_flags "$@"
  require_cmd scanimage

  # --- Paso 1: listado (NO es el criterio de éxito) -------------------------
  log_info "Listando dispositivos SANE (scanimage -L)..."
  local device
  if device="$(detect_sane_device)"; then
    log_ok "Backend cargado; dispositivo visible: ${device}"
    log_warn "OJO: que aparezca en scanimage -L NO valida el escáner; falta el escaneo real."
  else
    log_error "scanimage -L no lista ningún dispositivo Brother."
    log_error "Revisa: línea 'brother' en /etc/sane.d/dll.conf, regla udev aplicada"
    log_error "(¿reconectaste el USB?), y el paso de driver en docs/RUNBOOK-validacion.md."
    exit 1
  fi

  if [[ "${LIST_ONLY}" == "1" ]]; then
    log_info "Modo --list-only: no se escanea. La validación real sigue pendiente."
    exit 0
  fi

  # --- Paso 2: escaneo real ---------------------------------------------------
  local outfile
  outfile="${SCAN_TEST_DIR}/scan-test-$(date +%Y%m%d-%H%M%S).png"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "mkdir -p ${SCAN_TEST_DIR}"
    log_dry "scanimage -d ${device} --format=png --resolution ${SCAN_RESOLUTION} > ${outfile}"
    log_warn "Modo --dry-run: no se escaneó nada, la validación queda pendiente."
    exit 0
  fi

  mkdir -p "${SCAN_TEST_DIR}"
  log_info "Coloca una página impresa (con texto) sobre el cristal del escáner."
  confirm "¿Página colocada y tapa cerrada?" || die "Escaneo cancelado."

  log_info "Escaneando a ${SCAN_RESOLUTION} dpi..."
  SCAN_RESULT_FILE="${outfile}"
  do_scan "${device}" "${outfile}"
  outfile="${SCAN_RESULT_FILE}"

  [[ -s "${outfile}" ]] || die "El archivo de salida está vacío: el escaneo falló."
  log_ok "Escaneo terminado: ${outfile} ($(du -h "${outfile}" | cut -f1))"

  # --- Paso 3: confirmación visual (el criterio de éxito real) ----------------
  log_info "Abre el archivo y míralo. Opciones desde otro equipo:"
  log_info "  scp $(whoami)@$(hostname).local:${outfile} ."
  log_info "  (o cuando scanservjs esté instalado, escanea de nuevo desde el navegador)"
  if confirm_visual "¿Abriste ${outfile##*/} y la imagen se ve completa y legible?"; then
    state_mark "sane-scan-verified"
    log_ok "Backend SANE VALIDADO con un escaneo real y legible."
  else
    log_error "Validación FALLIDA: el archivo no es legible (o no se pudo comprobar)."
    log_error "Imagen negra/vacía o cortada → driver/perfil de modelo incorrecto."
    log_error "Sigue docs/RUNBOOK-validacion.md (pasos de driver y troubleshooting)."
    exit 1
  fi
}

main "$@"
