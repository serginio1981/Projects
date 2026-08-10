#!/usr/bin/env bash
# 20-add-queue.sh — detecta la URI USB y el PPD de brlaser, y crea la cola CUPS.
#
# Nada va hardcodeado:
#   - La URI USB incluye el número de serie de la impresora, distinto en cada
#     unidad, así que se detecta en runtime con lpinfo.
#   - El nombre del PPD varía entre versiones de brlaser, así que se busca en
#     lpinfo -m (preferencia: DCP-1600; alternativa: DCP-1510). Se puede forzar
#     con la variable de entorno PPD_OVERRIDE.
#
# Idempotente: lpadmin sobre una cola existente converge la configuración sin
# duplicarla.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Crea (o actualiza) la cola CUPS "\${QUEUE_NAME}" apuntando a la DCP-1602.

Variables de entorno:
  QUEUE_NAME      Nombre de la cola (actual: ${QUEUE_NAME})
  QUEUE_LOCATION  Ubicación mostrada en CUPS (actual: ${QUEUE_LOCATION})
  PPD_OVERRIDE    Fuerza un PPD concreto en lugar de la detección automática
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

# Imprime la URI USB de la impresora Brother detectada por CUPS.
detect_printer_uri() {
  local uri
  uri="$(lpinfo -l -v 2>/dev/null \
    | sed -n 's/.*uri = \(usb:\/\/Brother[^[:space:]]*\).*/\1/p' \
    | head -n 1)"
  if [[ -z "${uri}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_warn "Sin impresora detectable en modo --dry-run: uso una URI simulada."
      echo "usb://Brother/DCP-1602?serial=SIMULADA"
      return 0
    fi
    log_error "CUPS no ve ninguna impresora Brother por USB (lpinfo -l -v)."
    log_error "Comprueba encendido y cable, y repasa scripts/00-preflight.sh."
    return 1
  fi
  echo "${uri}"
}

# Imprime el identificador del PPD de brlaser a usar.
detect_ppd() {
  if [[ -n "${PPD_OVERRIDE}" ]]; then
    log_info "PPD forzado por PPD_OVERRIDE." >&2
    echo "${PPD_OVERRIDE}"
    return 0
  fi

  local models ppd
  models="$(lpinfo -m 2>/dev/null | grep -i brlaser || true)"
  if [[ -z "${models}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_warn "Sin PPDs de brlaser en modo --dry-run: uso un PPD simulado."
      echo "drv:///brlaser.drv/br1600.ppd"
      return 0
    fi
    log_error "No hay ningún PPD de brlaser disponible (lpinfo -m)."
    log_error "Instala printer-driver-brlaser con scripts/10-install-packages.sh."
    return 1
  fi

  # Preferencia: el PPD de la serie DCP-1600 (la DCP-1602 pertenece a ella).
  ppd="$(grep -i 'DCP-1600' <<<"${models}" | awk '{print $1}' | head -n 1)"
  if [[ -z "${ppd}" ]]; then
    # Alternativa conocida y compatible en versiones antiguas de brlaser.
    ppd="$(grep -i 'DCP-1510' <<<"${models}" | awk '{print $1}' | head -n 1)"
    if [[ -n "${ppd}" ]]; then
      log_warn "Sin PPD para DCP-1600; uso la alternativa DCP-1510." >&2
    fi
  fi
  if [[ -z "${ppd}" ]]; then
    log_error "brlaser está instalado pero sin PPD para DCP-1600 ni DCP-1510."
    log_error "Fuerza uno manualmente: PPD_OVERRIDE=... ${0##*/}"
    return 1
  fi
  echo "${ppd}"
}

main() {
  parse_flags "$@"
  require_root
  require_cmd lpinfo lpadmin lpstat cupsctl cupsenable cupsaccept

  local uri ppd
  uri="$(detect_printer_uri)"
  log_ok "URI detectada: ${uri}"
  ppd="$(detect_ppd)"
  log_ok "PPD seleccionado: ${ppd}"

  if lpstat -p "${QUEUE_NAME}" >/dev/null 2>&1; then
    log_info "La cola ${QUEUE_NAME} ya existe: se actualizará su configuración."
  else
    log_info "Creando la cola ${QUEUE_NAME}..."
  fi

  # -E (tras -p) deja la cola habilitada; printer-is-shared la publica en la
  # red, requisito para que CUPS genere su propio anuncio AirPrint.
  run lpadmin -p "${QUEUE_NAME}" \
    -v "${uri}" \
    -m "${ppd}" \
    -D "Brother DCP-1602 (brlaser)" \
    -L "${QUEUE_LOCATION}" \
    -o printer-is-shared=true \
    -o printer-error-policy=retry-job \
    -E
  run cupsenable "${QUEUE_NAME}"
  run cupsaccept "${QUEUE_NAME}"
  run cupsctl --share-printers

  if [[ "${DRY_RUN}" != "1" ]]; then
    lpstat -p "${QUEUE_NAME}" >&2
  fi

  state_mark "queue-created"
  log_ok "Cola ${QUEUE_NAME} lista y compartida."
}

main "$@"
