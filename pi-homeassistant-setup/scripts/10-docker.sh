#!/usr/bin/env bash
# 10-docker.sh — instala Docker Engine + plugin compose desde el repositorio
# apt oficial de Docker.
#
# Procedimiento tomado de la documentación oficial docs.docker.com/engine/
# install/debian/ (verificada el 2026-08-14). Raspberry Pi OS de 64 bits usa
# las instrucciones de Debian; la variante de 32 bits (ID=raspbian) NO está
# cubierta por ese repositorio y este script la rechaza.
#
# Idempotente: si docker y el plugin compose ya funcionan, no reinstala; el
# archivo de repositorio solo se escribe si cambió.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_SOURCES="/etc/apt/sources.list.d/docker.sources"
readonly DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Instala Docker Engine y el plugin compose desde el repositorio apt oficial
de Docker para Debian (método documentado en docs.docker.com, verificado el
2026-08-14). Si ya están instalados y funcionando, no hace nada.
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

setup_repository() {
  local codename arch content
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -n "${codename}" ]] || die "No pude determinar VERSION_CODENAME de /etc/os-release."
  arch="$(dpkg --print-architecture)"

  run install -m 0755 -d /etc/apt/keyrings
  if [[ -f "${DOCKER_KEYRING}" ]]; then
    log_ok "Llave GPG de Docker ya presente: ${DOCKER_KEYRING}."
  elif [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "curl -fsSL https://download.docker.com/linux/debian/gpg -o ${DOCKER_KEYRING}"
  else
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "${DOCKER_KEYRING}"
    chmod a+r "${DOCKER_KEYRING}"
    log_ok "Llave GPG de Docker instalada."
  fi

  # Formato deb822 (.sources), tal como lo documenta docs.docker.com.
  content="Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: ${DOCKER_KEYRING}"
  if [[ -f "${DOCKER_SOURCES}" ]] && [[ "$(cat "${DOCKER_SOURCES}")" == "${content}" ]]; then
    log_ok "Repositorio de Docker ya configurado: ${DOCKER_SOURCES}."
  elif [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${DOCKER_SOURCES} (suite ${codename}, arquitectura ${arch})."
  else
    printf '%s\n' "${content}" >"${DOCKER_SOURCES}"
    log_ok "Repositorio de Docker configurado (${codename}/${arch})."
  fi
}

main() {
  parse_flags "$@"
  require_root
  require_cmd dpkg apt-get systemctl curl

  # --- ¿Ya está todo? ---------------------------------------------------------
  if docker_ready && docker compose version >/dev/null 2>&1; then
    log_ok "Docker ya instalado y funcionando: $(docker --version)."
    log_ok "Plugin compose disponible: $(docker compose version --short 2>/dev/null || echo 'sí')."
    state_mark "docker-installed"
    exit 0
  fi

  # --- Rechazo explícito del caso 32 bits --------------------------------------
  local os_id
  os_id="$(. /etc/os-release && echo "${ID:-}")"
  if [[ "${os_id}" == "raspbian" ]]; then
    die "Raspberry Pi OS de 32 bits (ID=raspbian): el repositorio Debian de Docker no lo cubre y el hardware objetivo es de 64 bits. Reinstala la Pi con la imagen de 64 bits."
  fi

  # Docker ya instalado pero daemon parado: solo arrancar.
  if command -v docker >/dev/null 2>&1; then
    log_warn "Docker está instalado pero el daemon no responde: intento arrancarlo."
    run systemctl enable --now docker
    if [[ "${DRY_RUN}" == "1" ]] || docker_ready; then
      state_mark "docker-installed"
      log_ok "Docker operativo."
      exit 0
    fi
    die "Docker sigue sin responder tras arrancar el servicio. Diagnóstico: journalctl -u docker -n 50"
  fi

  log_info "Instalando Docker Engine desde el repositorio oficial..."
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
  setup_repository
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${DOCKER_PACKAGES[@]}"
  run systemctl enable --now docker

  # Permite usar docker sin sudo al usuario que invocó (aplica al reabrir sesión).
  if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    if id -nG "${SUDO_USER}" | tr ' ' '\n' | grep -qxF docker; then
      log_ok "El usuario ${SUDO_USER} ya pertenece al grupo docker."
    else
      run usermod -aG docker "${SUDO_USER}"
      log_ok "Usuario ${SUDO_USER} añadido al grupo docker (aplica al reiniciar sesión)."
    fi
  fi

  if [[ "${DRY_RUN}" != "1" ]]; then
    docker_ready || die "Docker no responde tras la instalación. Diagnóstico: journalctl -u docker -n 50"
    docker compose version >/dev/null 2>&1 || die "El plugin docker compose no quedó disponible."
    log_ok "Docker operativo: $(docker --version)."
  fi

  state_mark "docker-installed"
  log_ok "Docker Engine + compose instalados."
}

main "$@"
