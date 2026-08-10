#!/usr/bin/env bash
# 30-airsane.sh — instala AirSane (SimulPiscator/AirSane), el servidor
# eSCL/AirScan que atiende a Windows, Android (Mopria Scan) y macOS
# (Image Capture). Publica el escáner por mDNS y entrega JPEG, PNG y PDF.
#
# Requiere avahi-daemon activo: sin él, airsaned falla con "Bad State (-2)".
# AirSane no está empaquetado en Debian, así que se compila desde el código
# fuente (flujo documentado por su README).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly AIRSANE_DEFAULT_FILE="/etc/default/airsane"
# Dependencias de compilación según el README de SimulPiscator/AirSane:
readonly BUILD_DEPS=(libsane-dev libjpeg-dev libpng-dev libavahi-client-dev libusb-1.0-0-dev g++ cmake make git)

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Compila e instala AirSane (servidor eSCL/AirScan sobre SANE):
  - Asegura avahi-daemon activo (obligatorio; sin él: "Bad State (-2)")
  - Compila desde ${AIRSANE_REPO} e instala la unidad systemd airsaned
  - Verifica que el puerto web (\${AIRSANE_PORT}=${AIRSANE_PORT}) responde

Variables: AIRSANE_REPO, AIRSANE_PORT
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

ensure_avahi() {
  if ! dpkg -s avahi-daemon >/dev/null 2>&1; then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y avahi-daemon avahi-utils
  fi
  if [[ "${DRY_RUN}" != "1" ]] && ! systemctl is-active --quiet avahi-daemon; then
    run systemctl enable --now avahi-daemon
  fi
  log_ok "avahi-daemon presente y activo (requisito de AirSane)."
}

build_and_install() {
  local srcdir
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${BUILD_DEPS[@]}"

  srcdir="$(mktemp -d)/AirSane"
  run git clone --depth 1 "https://github.com/${AIRSANE_REPO}.git" "${srcdir}"
  run cmake -S "${srcdir}" -B "${srcdir}/build"
  run cmake --build "${srcdir}/build" -j "$(nproc)"
  run cmake --install "${srcdir}/build"
  log_ok "AirSane compilado e instalado."
}

configure_port() {
  # El puerto por defecto de airsaned es 8090. Si se pide otro por
  # AIRSANE_PORT, se ajusta en /etc/default/airsane (archivo que instala el
  # propio AirSane y consume su unidad systemd).
  if [[ "${AIRSANE_PORT}" == "8090" ]]; then
    return 0
  fi
  if [[ ! -f "${AIRSANE_DEFAULT_FILE}" ]]; then
    log_warn "AIRSANE_PORT=${AIRSANE_PORT} pero no existe ${AIRSANE_DEFAULT_FILE}:"
    log_warn "ajusta el puerto a mano según la documentación de AirSane (opción --listen-port)."
    return 0
  fi
  if grep -q -- "--listen-port=${AIRSANE_PORT}" "${AIRSANE_DEFAULT_FILE}"; then
    log_ok "Puerto ${AIRSANE_PORT} ya configurado en ${AIRSANE_DEFAULT_FILE}."
    return 0
  fi
  # NOTA (no verificado en todas las versiones): el formato exacto de
  # /etc/default/airsane puede variar; si esta sustitución no aplica, se
  # avisa en lugar de romper el archivo.
  if grep -q -- '--listen-port=[0-9]*' "${AIRSANE_DEFAULT_FILE}"; then
    run sed -i "s/--listen-port=[0-9]*/--listen-port=${AIRSANE_PORT}/" "${AIRSANE_DEFAULT_FILE}"
    log_ok "Puerto de AirSane cambiado a ${AIRSANE_PORT} en ${AIRSANE_DEFAULT_FILE}."
  else
    log_warn "No encontré una opción --listen-port en ${AIRSANE_DEFAULT_FILE}."
    log_warn "Añádela a mano para usar el puerto ${AIRSANE_PORT}; mientras, seguirá en 8090."
  fi
}

main() {
  parse_flags "$@"

  if [[ "${SKIP_AIRSANE}" == "1" ]]; then
    log_warn "SKIP_AIRSANE=1: se omite AirSane (Windows/Android/macOS quedarán sin eSCL)."
    exit 0
  fi

  require_root
  require_cmd dpkg apt-get systemctl

  ensure_avahi

  # Idempotencia: si airsaned ya existe no se recompila (FORCE_REINSTALL=1
  # para forzar). systemctl enable de una unidad ya habilitada es inocuo.
  if command -v airsaned >/dev/null 2>&1 && [[ "${FORCE_REINSTALL:-0}" != "1" ]]; then
    log_ok "airsaned ya está instalado; omito la compilación (FORCE_REINSTALL=1 para forzar)."
  else
    build_and_install
  fi

  configure_port
  run systemctl enable --now airsaned

  if [[ "${DRY_RUN}" != "1" ]]; then
    sleep 2
    if http_responds "${AIRSANE_PORT}"; then
      log_ok "AirSane responde en http://$(hostname).local:${AIRSANE_PORT}/"
    else
      log_warn "airsaned está habilitado pero el puerto ${AIRSANE_PORT} aún no responde."
      log_warn "Diagnóstico: journalctl -u airsaned -n 50 (un 'Bad State (-2)' = avahi caído)."
    fi
  fi

  state_mark "airsane-installed"
  log_ok "Servidor eSCL/AirScan listo para Windows, Android y macOS."
}

main "$@"
