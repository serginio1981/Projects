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

if [ ! -f config.yaml ]; then
  cp config.example.yaml config.yaml
  echo "→ Creado config.yaml a partir del ejemplo. EDÍTALO antes de arrancar el servicio."
fi
if [ ! -f .env ]; then
  cat > .env <<'ENV'
# Secretos leídos por el servicio (referenciados como ${VAR} en config.yaml)
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
  1. Exporta cookies.txt de tu cuenta de Google y cópialo a $DIR/cookies.txt (ver README).
  2. Edita $DIR/config.yaml (coordenadas de casa, google.person) y $DIR/.env (tokens).
  3. Comprueba:   ./venv/bin/python -m home_geofence --list-people
                  ./venv/bin/python -m home_geofence --test-notify
                  ./venv/bin/python -m home_geofence --once
  4. Arranca:     sudo systemctl start $SERVICE && journalctl -u $SERVICE -f
MSG
