#!/usr/bin/env bash
# 30-hardening-sd.sh — mitigaciones de desgaste de la microSD.
#
# Home Assistant escribe de forma continua a su base de datos de histórico y
# Docker suma logs y capas de imagen. Bajo esa carga, una microSD suele
# fallar en el orden de 1 a 2 años (cifra estimada de tutoriales de la
# comunidad, no de fuente primaria: tómala como orden de magnitud).
#
# Este script:
#   1. Configura rotación de logs de Docker en /etc/docker/daemon.json
#      (json-file con max-size/max-file acotados), FUSIONANDO con el
#      contenido existente sin duplicar claves (idempotente, con respaldo).
#   2. Genera un recorder.yaml de ejemplo en el directorio de configuración
#      de HA para acotar el histórico (purge_keep_days + exclusiones).
#   3. NO migra a SSD: esa es la mitigación real pero es una operación
#      destructiva que merece decisión humana; está documentada en el README.
#
# Nota de orden: las opciones de log de daemon.json solo aplican a
# contenedores CREADOS después del cambio. install.sh ejecuta este paso
# ANTES de desplegar HA por esa razón; si lo corres suelto con el contenedor
# ya creado, el script te avisa y te da el comando para recrearlo.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly DAEMON_JSON="/etc/docker/daemon.json"
readonly DAEMON_TEMPLATE="${PROJECT_DIR}/templates/daemon.json.tmpl"
readonly RECORDER_TEMPLATE="${PROJECT_DIR}/templates/recorder.yaml.tmpl"

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Mitigaciones de desgaste de microSD:
  - Rotación de logs de Docker (max-size=\${DOCKER_LOG_MAX_SIZE}=${DOCKER_LOG_MAX_SIZE},
    max-file=\${DOCKER_LOG_MAX_FILE}=${DOCKER_LOG_MAX_FILE}) en ${DAEMON_JSON}
  - recorder.yaml de ejemplo (purge_keep_days=\${RECORDER_PURGE_KEEP_DAYS}=${RECORDER_PURGE_KEEP_DAYS})
    en \${HA_CONFIG_DIR}=${HA_CONFIG_DIR}
La migración a SSD USB (la mitigación real) NO se hace aquí: ver README.
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

configure_docker_log_rotation() {
  local rendered
  rendered="$(sed \
    -e "s|@LOG_MAX_SIZE@|${DOCKER_LOG_MAX_SIZE}|g" \
    -e "s|@LOG_MAX_FILE@|${DOCKER_LOG_MAX_FILE}|g" \
    "${DAEMON_TEMPLATE}")"

  if [[ ! -f "${DAEMON_JSON}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_dry "Escribiría ${DAEMON_JSON}:"
      printf '%s\n' "${rendered}" >&2
      return 0
    fi
    mkdir -p /etc/docker
    printf '%s\n' "${rendered}" >"${DAEMON_JSON}"
    log_ok "Rotación de logs de Docker configurada en ${DAEMON_JSON} (archivo nuevo)."
    restart_docker_if_needed
    return 0
  fi

  # El archivo existe: fusionar sin duplicar ni pisar otras claves.
  # python3 viene de serie en Raspberry Pi OS.
  require_cmd python3
  local merged
  merged="$(python3 - "$DAEMON_JSON" "$DOCKER_LOG_MAX_SIZE" "$DOCKER_LOG_MAX_FILE" <<'PYEOF'
import json, sys
path, max_size, max_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["log-driver"] = "json-file"
opts = data.get("log-opts")
if not isinstance(opts, dict):
    opts = {}
opts["max-size"] = max_size
opts["max-file"] = str(max_file)
data["log-opts"] = opts
print(json.dumps(data, indent=2, sort_keys=True))
PYEOF
)"
  if [[ "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2, sort_keys=True))' "${DAEMON_JSON}")" == "${merged}" ]]; then
    log_ok "La rotación de logs ya estaba configurada en ${DAEMON_JSON}; sin cambios."
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Fusionaría la rotación de logs en ${DAEMON_JSON} (con respaldo .bak)."
    return 0
  fi
  cp -a "${DAEMON_JSON}" "${DAEMON_JSON}.bak"
  printf '%s\n' "${merged}" >"${DAEMON_JSON}"
  log_ok "Rotación de logs fusionada en ${DAEMON_JSON} (respaldo en ${DAEMON_JSON}.bak)."
  restart_docker_if_needed
}

restart_docker_if_needed() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "systemctl restart docker"
    return 0
  fi
  if ! systemctl is-active --quiet docker 2>/dev/null; then
    log_info "El servicio docker no está activo aún: la configuración aplicará cuando arranque."
    return 0
  fi
  run systemctl restart docker
  log_ok "Servicio docker reiniciado para tomar la nueva configuración."
  if ha_container_exists; then
    log_warn "Las opciones de log solo aplican a contenedores CREADOS tras el cambio."
    log_warn "Para que ${HA_CONTAINER_NAME} las tome, recréalo cuando te convenga:"
    log_warn "  sudo docker compose -f ${HA_BASE_DIR}/docker-compose.yml up -d --force-recreate"
  fi
}

install_recorder_example() {
  local target="${HA_CONFIG_DIR}/recorder.yaml.example"
  local rendered
  rendered="$(sed "s|@PURGE_KEEP_DAYS@|${RECORDER_PURGE_KEEP_DAYS}|g" "${RECORDER_TEMPLATE}")"

  if [[ -f "${target}" ]] && [[ "$(cat "${target}")" == "${rendered}" ]]; then
    log_ok "El recorder de ejemplo ya está al día: ${target}."
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${target}."
    return 0
  fi
  mkdir -p "${HA_CONFIG_DIR}"
  printf '%s\n' "${rendered}" >"${target}"
  log_ok "Recorder de ejemplo escrito en ${target}."
  log_info "Es un EJEMPLO: HA no lo lee solo. Copia su bloque 'recorder:' dentro de"
  log_info "${HA_CONFIG_DIR}/configuration.yaml y reinicia HA (ver runbook, paso de recorder)."
}

main() {
  parse_flags "$@"
  require_root
  [[ -r "${DAEMON_TEMPLATE}" ]] || die "No encuentro la plantilla ${DAEMON_TEMPLATE}"
  [[ -r "${RECORDER_TEMPLATE}" ]] || die "No encuentro la plantilla ${RECORDER_TEMPLATE}"

  if [[ "${SKIP_HARDENING}" == "1" ]]; then
    log_warn "SKIP_HARDENING=1: se omiten las mitigaciones de desgaste de la microSD."
    log_warn "Sin ellas, la escritura continua de HA acorta la vida de la tarjeta (orden de 1-2 años según la comunidad)."
    exit 0
  fi

  configure_docker_log_rotation
  install_recorder_example

  log_warn "La mitigación REAL del desgaste es migrar el sistema a un SSD USB."
  log_warn "Es una operación destructiva y manual: está documentada en el README, no la hace este script."

  state_mark "sd-hardening-applied"
  log_ok "Mitigaciones de microSD aplicadas."
}

main "$@"
