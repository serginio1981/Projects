#!/usr/bin/env bash
# 40-scanservjs.sh — instala scanservjs (sbs20/scanservjs), el frontend web
# para SANE. Es la vía de escaneo para iOS: iPhone/iPad NO tienen cliente de
# escáner de red (el "Escanear documentos" de Notas/Archivos usa la cámara),
# así que se escanea desde Safari y se instala como PWA con "Añadir a
# pantalla de inicio".
#
# Instalación preferida: el paquete .deb de los GitHub Releases del proyecto.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Instala scanservjs desde el .deb del último GitHub Release de
\${SCANSERVJS_REPO} (${SCANSERVJS_REPO}) y comprueba que el puerto web
(\${SCANSERVJS_PORT}=${SCANSERVJS_PORT}) responde.
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

install_from_release() {
  local json urls asset tmpdir file
  log_info "Buscando el paquete .deb en el último release de ${SCANSERVJS_REPO}..."
  if ! json="$(github_latest_release_json "${SCANSERVJS_REPO}")"; then
    die "No pude consultar los releases de ${SCANSERVJS_REPO} (¿sin red?)."
  fi
  urls="$(github_release_asset_urls <<<"${json}")"
  asset="$(grep -i '\.deb$' <<<"${urls}" | head -n 1)" || true
  if [[ -z "${asset}" ]]; then
    # NOTA (no verificado para todas las versiones): los releases recientes
    # de scanservjs publican un .deb. Si esta versión no lo trae, no se
    # inventa otro método aquí: consulta el README del proyecto.
    die "El último release de ${SCANSERVJS_REPO} no trae un .deb; instala según su README oficial."
  fi

  tmpdir="$(mktemp -d)"
  file="${tmpdir}/$(basename "${asset}")"
  log_info "Descargando ${asset}..."
  curl -fsSL --max-time 300 -o "${file}" "${asset}"
  # apt resuelve las dependencias del .deb (sane-utils, nodejs, etc.). En
  # versiones antiguas de Raspberry Pi OS el nodejs de los repos puede ser
  # demasiado viejo; si apt falla por eso, ver docs/RUNBOOK-validacion.md.
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${file}"
  rm -rf "${tmpdir}"
  log_ok "scanservjs instalado desde el paquete .deb."
}

main() {
  parse_flags "$@"

  if [[ "${SKIP_SCANSERVJS}" == "1" ]]; then
    log_warn "SKIP_SCANSERVJS=1: se omite scanservjs (iOS quedará SIN vía de escaneo)."
    exit 0
  fi

  require_root
  require_cmd dpkg apt-get systemctl curl

  # Idempotencia: si el paquete ya está instalado no se re-descarga.
  if dpkg -s scanservjs >/dev/null 2>&1 && [[ "${FORCE_REINSTALL:-0}" != "1" ]]; then
    log_ok "scanservjs ya está instalado; omito la descarga (FORCE_REINSTALL=1 para forzar)."
  else
    install_from_release
  fi

  run systemctl enable --now scanservjs

  if [[ "${SCANSERVJS_PORT}" != "8080" ]]; then
    # NOTA (no verificado): el puerto de scanservjs se cambia en su
    # configuración local (según versión: /etc/scanservjs/config.local.js).
    # No se automatiza aquí para no corromper un formato que varía.
    log_warn "SCANSERVJS_PORT=${SCANSERVJS_PORT}: scanservjs seguirá en su puerto por defecto (8080)"
    log_warn "hasta que lo cambies en su configuración; ver docs/RUNBOOK-validacion.md."
  fi

  if [[ "${DRY_RUN}" != "1" ]]; then
    sleep 2
    if http_responds "${SCANSERVJS_PORT}"; then
      log_ok "scanservjs responde en http://$(hostname).local:${SCANSERVJS_PORT}/"
    else
      log_warn "scanservjs está habilitado pero el puerto ${SCANSERVJS_PORT} aún no responde."
      log_warn "Diagnóstico: journalctl -u scanservjs -n 50"
    fi
  fi

  state_mark "scanservjs-installed"
  log_ok "Interfaz web lista. En iOS: Safari → http://$(hostname 2>/dev/null || echo raspberrypi).local:${SCANSERVJS_PORT} → Compartir → 'Añadir a pantalla de inicio'."
}

main "$@"
