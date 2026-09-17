#!/usr/bin/env bash
# Instala el monitor como servicio systemd en una Raspberry Pi (o cualquier Linux con systemd).
# Uso: ./install.sh   (sin sudo; pedirá sudo solo para instalar la unidad)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE=home-geofence
RUN_USER="${SUDO_USER:-$USER}"

cd "$DIR"

if ! command -v python3 >/dev/null; then
  echo "Necesitas python3 (sudo apt install python3 python3-venv)" >&2; exit 1
fi

if [ ! -d venv ]; then
  echo "→ Creando entorno virtual"
  python3 -m venv venv
fi
echo "→ Instalando dependencias"
./venv/bin/pip install -q -r requirements.txt

# Proveedor find_my_device: la herramienta vendida (submódulo) y sus dependencias.
# Se omite con --no-fmd si solo vas a usar la ubicación compartida (google).
if [[ "${1:-}" != "--no-fmd" ]]; then
  if [ ! -f vendor/GoogleFindMyTools/main.py ]; then
    echo "→ Descargando GoogleFindMyTools (submódulo git)"
    git -C "$DIR" submodule update --init --depth 1 vendor/GoogleFindMyTools
  fi
  echo "→ Instalando dependencias de Find My Device (puede tardar en una Pi)"
  ./venv/bin/pip install -q -r requirements-fmd.txt
fi

if [ ! -f config.yaml ]; then
  cp config.example.yaml config.yaml
  echo "→ Creado config.yaml a partir del ejemplo. EDÍTALO antes de arrancar el servicio."
fi
if [ ! -f .env ]; then
  cat > .env <<'ENV'
# Secretos leídos por el servicio (referenciados como ${VAR} en config.yaml)
HA_WEBHOOK_ID=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
SMTP_APP_PASSWORD=
ENV
  chmod 600 .env
  echo "→ Creado .env (rellena los tokens)."
fi

echo "→ Instalando unidad systemd ($SERVICE.service)"
sed -e "s|__DIR__|$DIR|g" -e "s|__USER__|$RUN_USER|g" templates/$SERVICE.service \
  | sudo tee /etc/systemd/system/$SERVICE.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE.service

cat <<MSG

Listo. Pasos que faltan:
  1. Credenciales según la fuente elegida (ver README):
       find_my_device → genera secrets.json en un PC con Chrome y cópialo a $DIR/secrets.json
       google         → exporta cookies.txt de tu cuenta y cópialo a $DIR/cookies.txt
  2. Edita $DIR/config.yaml (coordenadas de casa, dispositivo/persona) y $DIR/.env (ids y tokens).
  3. Comprueba:   ./venv/bin/python -m home_geofence --list-devices
                  ./venv/bin/python -m home_geofence --test-notify
                  ./venv/bin/python -m home_geofence --once
  4. Arranca:     sudo systemctl start $SERVICE && journalctl -u $SERVICE -f
  Avisos en el iPhone con la app de Home Assistant: docs/HOME-ASSISTANT.md
MSG
