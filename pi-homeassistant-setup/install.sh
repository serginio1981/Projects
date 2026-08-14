#!/usr/bin/env bash
# install.sh — instalador de un toque de pi-homeassistant-setup.
#
# Instala Home Assistant CONTAINER (Docker) sobre una Raspberry Pi que YA es
# servidor de impresión AirPrint, sin degradar ese servicio. Deliberadamente
# NO usa Home Assistant OS (se apodera de la máquina y destruiría el servidor
# de impresión) ni Supervised (altera el sistema anfitrión).
#
# Orden de ejecución: el hardening de microSD (30) corre ANTES del despliegue
# (20) porque las opciones de log de /etc/docker/daemon.json solo aplican a
# contenedores creados después del cambio.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

VALIDATE_ONLY=0

usage() {
  cat <<EOF
Uso: ${0##*/} [OPCIONES]

Instala Home Assistant Container en esta máquina sin tocar el servidor de
impresión existente (CUPS/Avahi).

Opciones:
  --dry-run          Muestra los comandos que modificarían el sistema.
  --validate-only    No instala: solo preflight (00) y diagnóstico (90).
  --skip-hardening   Omite las mitigaciones de desgaste de microSD (30).
  --yes, -y          Responde 'sí' a las confirmaciones.
  --help, -h         Esta ayuda.

Variables de entorno (defaults razonables):
  HA_CONTAINER_NAME  (${HA_CONTAINER_NAME})   HA_IMAGE (${HA_IMAGE})
  HA_CONFIG_DIR      (${HA_CONFIG_DIR})
  HA_TZ              (${HA_TZ})               HA_PORT  (${HA_PORT})
  DOCKER_LOG_MAX_SIZE (${DOCKER_LOG_MAX_SIZE}) DOCKER_LOG_MAX_FILE (${DOCKER_LOG_MAX_FILE})
  RECORDER_PURGE_KEEP_DAYS (${RECORDER_PURGE_KEEP_DAYS})

Ejemplos:
  sudo ./install.sh --dry-run     # primero, siempre
  sudo ./install.sh
  sudo HA_TZ=America/Santiago ./install.sh --yes
EOF
}

parse_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --validate-only) VALIDATE_ONLY=1 ;;
      --skip-hardening) SKIP_HARDENING=1 ;;
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
    || die "El paso ${script} falló. Corrige y reejecuta install.sh (todos los pasos son idempotentes). Si la impresión quedó afectada: docs/ROLLBACK.md"
}

main() {
  parse_flags "$@"

  log_info "pi-homeassistant-setup — Home Assistant Container sin romper el servidor de impresión"
  log_info "Configuración:"
  log_info "  Contenedor:  ${HA_CONTAINER_NAME}  (imagen ${HA_IMAGE})"
  log_info "  Config dir:  ${HA_CONFIG_DIR}"
  log_info "  Zona horaria: ${HA_TZ}   Puerto: ${HA_PORT}"
  log_info "  Dry-run: ${DRY_RUN}  Solo validar: ${VALIDATE_ONLY}  Sin hardening: ${SKIP_HARDENING}"

  if [[ "${VALIDATE_ONLY}" == "1" ]]; then
    run_step "00-preflight.sh"
    run_step "90-verify.sh"
    exit 0
  fi

  if [[ "${DRY_RUN}" != "1" ]]; then
    confirm "Se instalará Docker (si falta) y se desplegará Home Assistant. ¿Continuar?" \
      || die "Instalación cancelada por el usuario."
  fi

  run_step "00-preflight.sh"
  run_step "10-docker.sh"
  if [[ "${SKIP_HARDENING}" == "1" ]]; then
    log_warn "Se omite el hardening de microSD (--skip-hardening)."
  else
    # Antes del despliegue: las opciones de log solo aplican a contenedores
    # creados después de configurarlas.
    run_step "30-hardening-sd.sh"
  fi
  run_step "20-homeassistant.sh"
  run_step "90-verify.sh"

  local host
  host="$(hostname 2>/dev/null || echo raspberrypi)"
  log_ok "Instalación terminada."
  log_info "Siguiente paso: abre http://${host}.local:${HA_PORT} y completa el asistente inicial de HA."
  log_info "Recorder acotado: copia el bloque de ${HA_CONFIG_DIR}/recorder.yaml.example a configuration.yaml (runbook)."
  log_info "HomeKit Bridge se configura desde la interfaz de HA (Ajustes → Dispositivos y servicios); ver README."
  log_info "Actualizar HA más adelante:"
  log_info "  sudo docker compose -f ${HA_BASE_DIR}/docker-compose.yml pull"
  log_info "  sudo docker compose -f ${HA_BASE_DIR}/docker-compose.yml up -d"
}

main "$@"
