#!/usr/bin/env bash
# 10-driver.sh — instala el backend SANE para el escáner Brother.
#
# El driver oficial de Brother (brscan4) solo viene precompilado para i386 y
# su código fuente publicado está incompleto; la vía qemu/i386 en ARM es
# frágil y NO se usa aquí. En su lugar se usa la reimplementación open source
# dmikushin/brscan, que publica binarios para amd64, arm64 y armv7 en sus
# GitHub Releases. Si no hay binario para la arquitectura detectada, se
# compila desde el código fuente como alternativa.
#
# Idempotente: no duplica la línea en dll.conf ni la regla udev.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/common.sh
source "${PROJECT_DIR}/lib/common.sh"

readonly DLL_CONF="/etc/sane.d/dll.conf"
readonly UDEV_RULE_FILE="/etc/udev/rules.d/60-brother-scanner.rules"
readonly UDEV_TEMPLATE="${PROJECT_DIR}/templates/60-brother-scanner.rules.tmpl"
# Dependencias de compilación documentadas por el proyecto brscan:
readonly BUILD_DEPS=(libsane-dev libusb-dev libjpeg-dev pkg-config cmake gcc g++ make git)

usage() {
  cat <<EOF
Uso: ${0##*/} [--dry-run] [--yes] [--help]

Instala el backend SANE 'brother' (dmikushin/brscan):
  1. Binario precompilado del último GitHub Release para la arquitectura
     detectada; si no existe, compila desde el código fuente.
  2. Registra el backend en ${DLL_CONF} (sin duplicar).
  3. Instala la regla udev con el product ID detectado en runtime.

Variables: BRSCAN_REPO (default dmikushin/brscan)
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

install_base_packages() {
  local base=(sane-utils usbutils curl ca-certificates)
  local missing=() pkg
  for pkg in "${base[@]}"; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
  log_ok "Paquetes base de SANE presentes (sane-utils, usbutils, curl)."
}

# Intenta instalar el binario precompilado del último release. Devuelve 1 si
# no hay asset utilizable para esta arquitectura (el llamador compila).
install_from_release() {
  local arch json urls asset tmpdir file
  if ! arch="$(arch_label)"; then
    log_warn "Arquitectura $(uname -m) sin etiqueta de release conocida."
    return 1
  fi

  log_info "Buscando binario ${arch} en el último release de ${BRSCAN_REPO}..."
  if ! json="$(github_latest_release_json "${BRSCAN_REPO}")"; then
    log_warn "No pude consultar los releases de ${BRSCAN_REPO} (¿sin red?)."
    return 1
  fi
  urls="$(github_release_asset_urls <<<"${json}")"

  # NOTA (no verificado): se asume que el nombre del asset contiene la
  # etiqueta de arquitectura (amd64/arm64/armv7). Si el proyecto cambia su
  # convención de nombres, este filtro no encontrará nada y se pasará a la
  # compilación desde el código fuente.
  asset="$(grep -i "${arch}" <<<"${urls}" | head -n 1)" || true
  if [[ -z "${asset}" ]]; then
    log_warn "El último release de ${BRSCAN_REPO} no trae asset para ${arch}."
    return 1
  fi

  case "${asset}" in
    *.deb)
      tmpdir="$(mktemp -d)"
      file="${tmpdir}/$(basename "${asset}")"
      log_info "Descargando ${asset}..."
      curl -fsSL --max-time 300 -o "${file}" "${asset}"
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${file}"
      rm -rf "${tmpdir}"
      log_ok "Backend brscan instalado desde el paquete precompilado (${arch})."
      ;;
    *)
      # Formato de asset no contemplado: mejor compilar que adivinar cómo
      # instalarlo.
      log_warn "Asset con formato no contemplado (${asset##*/}); se compilará desde el código fuente."
      return 1
      ;;
  esac
}

install_from_source() {
  local srcdir
  log_info "Compilando ${BRSCAN_REPO} desde el código fuente (alternativa)..."
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${BUILD_DEPS[@]}"

  srcdir="$(mktemp -d)/brscan"
  run git clone --depth 1 "https://github.com/${BRSCAN_REPO}.git" "${srcdir}"
  # NOTA (no verificado): flujo cmake estándar. Si el proyecto cambia su
  # sistema de build, consulta su README y docs/RUNBOOK-validacion.md.
  run cmake -S "${srcdir}" -B "${srcdir}/build"
  run cmake --build "${srcdir}/build" -j "$(nproc)"
  run cmake --install "${srcdir}/build"
  log_ok "Backend brscan compilado e instalado."
}

register_backend_dll_conf() {
  if [[ ! -f "${DLL_CONF}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_dry "echo brother >> ${DLL_CONF}"
      return 0
    fi
    die "No existe ${DLL_CONF}: ¿está instalado sane-utils/libsane?"
  fi
  if grep -qxE '[[:space:]]*brother[[:space:]]*' "${DLL_CONF}"; then
    log_ok "El backend 'brother' ya está registrado en ${DLL_CONF}."
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "echo brother >> ${DLL_CONF}"
    return 0
  fi
  echo "brother" >>"${DLL_CONF}"
  log_ok "Backend 'brother' añadido a ${DLL_CONF}."
}

# Verifica si el modelo aparece en el Brsane.ini del backend instalado.
# INCERTIDUMBRE MANEJADA: no está confirmado que la DCP-1602 figure en el
# Brsane.ini de dmikushin/brscan. Si no figura, se avisa de que se intentará
# con el perfil de la DCP-1510 (mismo motor, USB ID de referencia
# 04f9:${FALLBACK_PRODUCT_ID}) y la compatibilidad pasa de "confirmada" a
# "probable". Nunca se presenta como segura.
check_model_profile() {
  local ini_path
  ini_path="$(find /usr /etc /opt -name 'Brsane.ini' -print 2>/dev/null | head -n 1)" || true
  if [[ -z "${ini_path}" ]]; then
    log_warn "No encontré ningún Brsane.ini instalado: no puedo confirmar el perfil del modelo."
    log_warn "Si el escáner no responde, revisa el paso de driver en docs/RUNBOOK-validacion.md."
    return 0
  fi
  log_info "Perfil de modelos del backend: ${ini_path}"
  if grep -qi 'DCP-1602' "${ini_path}"; then
    log_ok "La DCP-1602 aparece en Brsane.ini: compatibilidad confirmada por el backend."
  elif grep -qi 'DCP-1510' "${ini_path}"; then
    log_warn "La DCP-1602 NO aparece en Brsane.ini de este backend."
    log_warn "Se intentará con el perfil de la DCP-1510 (mismo motor, referencia ${BROTHER_VENDOR_ID}:${FALLBACK_PRODUCT_ID})."
    log_warn "La compatibilidad pasa de 'confirmada' a 'PROBABLE': valida con un escaneo real (20-verify-sane.sh)."
  else
    log_warn "Ni DCP-1602 ni DCP-1510 aparecen en ${ini_path}: compatibilidad SIN confirmar."
    log_warn "Valida con un escaneo real antes de dar nada por bueno (20-verify-sane.sh)."
  fi
}

install_udev_rule() {
  local product_id rendered
  if ! product_id="$(detect_brother_product_id)" || [[ -z "${product_id}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_warn "Sin dispositivo en --dry-run: uso el product ID de referencia ${FALLBACK_PRODUCT_ID}."
      product_id="${FALLBACK_PRODUCT_ID}"
    else
      die "No detecto el dispositivo Brother en USB: no puedo generar la regla udev."
    fi
  fi

  [[ -r "${UDEV_TEMPLATE}" ]] || die "No encuentro la plantilla ${UDEV_TEMPLATE}"
  rendered="$(sed -e "s/@VENDOR_ID@/${BROTHER_VENDOR_ID}/g" -e "s/@PRODUCT_ID@/${product_id}/g" "${UDEV_TEMPLATE}")"

  if [[ -f "${UDEV_RULE_FILE}" ]] && [[ "$(cat "${UDEV_RULE_FILE}")" == "${rendered}" ]]; then
    log_ok "La regla udev ya está instalada y al día: ${UDEV_RULE_FILE}."
    return 0
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry "Escribiría ${UDEV_RULE_FILE} con:"
    printf '%s\n' "${rendered}" >&2
    return 0
  fi

  printf '%s\n' "${rendered}" >"${UDEV_RULE_FILE}"
  chmod 0644 "${UDEV_RULE_FILE}"
  log_ok "Regla udev instalada: ${UDEV_RULE_FILE} (product ID ${product_id})."
  run udevadm control --reload-rules
  run udevadm trigger
  log_warn "Para que la regla aplique al dispositivo: desconecta y reconecta el cable USB"
  log_warn "de la impresora (o apágala y enciéndela)."
}

main() {
  parse_flags "$@"
  require_root
  require_cmd dpkg apt-get

  install_base_packages

  # Idempotencia: si el backend ya está registrado y hay un Brsane.ini
  # instalado, no se reinstala (fuerza con FORCE_REINSTALL=1).
  if [[ "${FORCE_REINSTALL:-0}" != "1" ]] \
    && grep -qxE '[[:space:]]*brother[[:space:]]*' "${DLL_CONF}" 2>/dev/null \
    && [[ -n "$(find /usr /etc /opt -name 'Brsane.ini' -print -quit 2>/dev/null)" ]]; then
    log_ok "El backend brscan ya parece instalado; omito la descarga (FORCE_REINSTALL=1 para forzar)."
  else
    install_from_release || install_from_source
  fi

  register_backend_dll_conf
  check_model_profile
  install_udev_rule

  # El acceso sin root al escáner requiere pertenecer a los grupos lp/scanner.
  if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    local grp
    for grp in lp scanner; do
      if getent group "${grp}" >/dev/null 2>&1; then
        if id -nG "${SUDO_USER}" | tr ' ' '\n' | grep -qxF "${grp}"; then
          log_ok "El usuario ${SUDO_USER} ya pertenece al grupo ${grp}."
        else
          run usermod -aG "${grp}" "${SUDO_USER}"
          log_ok "Usuario ${SUDO_USER} añadido al grupo ${grp} (aplica al reiniciar sesión)."
        fi
      fi
    done
  fi

  state_mark "driver-installed"
  log_ok "Backend SANE instalado y registrado."
  log_info "Siguiente paso: valida con un escaneo real → scripts/20-verify-sane.sh"
}

main "$@"
