#!/usr/bin/env bash
# install.sh — instalador de un toque de pi-scan-brother.
#
# Expone por red el escáner de una Brother DCP-1602 (USB) conectada a esta
# máquina: AirSane (eSCL/AirScan) para Windows, Android y macOS, y scanservjs
# (web/PWA) para iOS. Autocontenido: no depende de ningún otro proyecto.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

VALIDATE_ONLY=0

usage() {
  cat <<EOF
Uso: ${0##*/} [OPCIONES]

Convierte esta máquina en servidor de escaneo en red para la Brother
DCP-1602 (USB), accesible desde iOS, Windows, Android y macOS.

Opciones:
  --dry-run           Muestra los comandos que modificarían el sistema sin
                      ejecutarlos.
  --validate-only     No instala nada: solo comprobaciones (00-preflight) y
                      diagnóstico end-to-end (90-verify).
  --skip-airsane      No instala AirSane (Windows/Android/macOS sin eSCL).
  --skip-scanservjs   No instala scanservjs (iOS sin vía de escaneo).
  --yes, -y           Responde 'sí' a las confirmaciones de instalación.
                      NO afecta a la confirmación visual del escaneo.
  --help, -h          Muestra esta ayuda.

Variables de entorno:
  AIRSANE_PORT        Puerto web de AirSane (default: 8090)
  SCANSERVJS_PORT     Puerto web de scanservjs (default: 8080)
  SCAN_TEST_DIR       Carpeta de los escaneos de prueba
  SCAN_RESOLUTION     Resolución del escaneo de prueba en dpi (default: 150)
  BRSCAN_REPO, AIRSANE_REPO, SCANSERVJS_REPO
                      Repos upstream (defaults: dmikushin/brscan,
                      SimulPiscator/AirSane, sbs20/scanservjs)

Ejemplos:
  sudo ./install.sh
  sudo ./install.sh --dry-run
  sudo ./install.sh --skip-scanservjs --yes
  ./install.sh --validate-only
EOF
}

parse_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --validate-only) VALIDATE_ONLY=1 ;;
      --skip-airsane) SKIP_AIRSANE=1 ;;
      --skip-scanservjs) SKIP_SCANSERVJS=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "Opción no reconocida: ${arg}"; usage; exit 64 ;;
    esac
  done
}

run_step() {
  local script="$1"
  log_info "──────────────────────────────────────────────"
  log_info "Paso: ${script}"
  log_info "──────────────────────────────────────────────"
  "${SCRIPTS_DIR}/${script}" \
    || die "El paso ${script} falló. Corrige el problema y reejecuta install.sh (todos los pasos son idempotentes)."
}

main() {
  parse_flags "$@"

  log_info "pi-scan-brother — escáner Brother DCP-1602 (USB) expuesto por red"
  log_info "Configuración:"
  log_info "  AirSane (eSCL):    puerto ${AIRSANE_PORT}$([[ "${SKIP_AIRSANE}" == "1" ]] && echo ' — OMITIDO')"
  log_info "  scanservjs (web):  puerto ${SCANSERVJS_PORT}$([[ "${SKIP_SCANSERVJS}" == "1" ]] && echo ' — OMITIDO')"
  log_info "  Dry-run:           ${DRY_RUN}"
  log_info "  Solo validar:      ${VALIDATE_ONLY}"

  if [[ "${VALIDATE_ONLY}" == "1" ]]; then
    run_step "00-preflight.sh"
    run_step "90-verify.sh"
    exit 0
  fi

  if [[ "${DRY_RUN}" != "1" ]]; then
    confirm "Se instalarán el backend SANE y los servidores de escaneo. ¿Continuar?" \
      || die "Instalación cancelada por el usuario."
  fi

  run_step "00-preflight.sh"
  run_step "10-driver.sh"
  run_step "20-verify-sane.sh"
  run_step "30-airsane.sh"
  run_step "40-scanservjs.sh"
  run_step "90-verify.sh"

  local host
  host="$(hostname 2>/dev/null || echo raspberrypi)"
  log_ok "Instalación terminada."
  log_info "Cómo escanear desde cada sistema (detalle en docs/CLIENTES.md):"
  log_info "  Windows:  Configuración → Impresoras y escáneres → Agregar dispositivo"
  log_info "  Android:  app Mopria Scan (descubre el escáner sola)"
  log_info "  macOS:    Captura de Imagen / Ajustes → Impresoras y escáneres"
  log_info "  iOS:      Safari → http://${host}.local:${SCANSERVJS_PORT} → 'Añadir a pantalla de inicio'"
}

main "$@"
