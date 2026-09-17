# pi-home-geofence

Te **avisa por Telegram (o correo) cuando tu hijo llega a casa** (y, si
quieres, cuando sale), usando la ubicación que él **comparte contigo en
Google Maps**. Pensado para correr 24/7 en una Raspberry Pi, pero funciona en
cualquier Linux/macOS/Windows con Python 3.9+.

Proyecto independiente y autocontenido. No depende de ningún otro proyecto de
este repositorio.

## Antes de empezar: cómo funciona (y qué NO hace)

* **No entra en la cuenta de tu hijo.** El programa se autentica con **tu**
  cuenta de Google y lee lo que tu hijo ya comparte contigo mediante
  *Google Maps → Compartir ubicación*. Si él deja de compartir, el monitor
  deja de ver su posición. Es el mismo modelo de confianza que la app de
  Google Maps.
* **Google no ofrece una API oficial** para la ubicación compartida. Se usa la
  librería no oficial [`locationsharinglib`](https://github.com/costastf/locationsharinglib)
  (la misma que usa la integración *Google Maps* de Home Assistant). Lee el
  endpoint interno de la web de Google Maps con las cookies de tu sesión.
  **Google puede cambiar ese endpoint sin aviso** y romper la librería; si un
  día deja de funcionar, mira los *issues* del proyecto antes de tocar nada.
* **Las cookies caducan** (normalmente en semanas o meses, no es un valor
  documentado). Cuando pase, verás errores `No se pudo iniciar sesión` en el
  log y tendrás que volver a exportarlas.
* **Ética y legalidad.** Está pensado para un padre/madre y un hijo **menor
  que sabe que comparte su ubicación**. Compartir ubicación en Google Maps es
  siempre una acción explícita del hijo en su teléfono, y él puede
  desactivarla cuando quiera. Monitorizar a un adulto sin su consentimiento
  puede ser ilegal en tu país; no uso ni recomiendo este proyecto para eso.

## Cómo funciona

```
 teléfono del hijo ──(Google Maps: compartir ubicación contigo)──▶ Google
                                                                     │
        Raspberry Pi ◀──── locationsharinglib (cookies de TU cuenta) ─┘
             │
             ├─ geocerca: ¿a < 100 m de casa?  (histéresis + confirmación)
             │
             └─ transición ENTRÓ / SALIÓ ──▶ Telegram · correo · log
```

Para no dar falsas alarmas (el GPS "baila" cuando el teléfono está en
interiores), la geocerca aplica tres filtros, todos configurables:

| Filtro | Config | Qué evita |
|---|---|---|
| Histéresis | `radius_m` + `hysteresis_m` | Entrar/salir en bucle cuando la posición oscila en el borde |
| Confirmación | `confirm_samples` | Cambiar de estado por una única lectura rara |
| Calidad | `max_accuracy_m`, `max_age_min` | Usar posiciones imprecisas (>250 m) o antiguas (teléfono apagado) |

Además guarda el último estado en `state.json`, así un reinicio de la Pi no
manda un "llegó a casa" falso.

## Instalación rápida

```bash
cd pi-home-geofence
./install.sh          # crea venv, instala dependencias, config.yaml, .env y la unidad systemd
```

Después, completa los tres pasos de abajo, prueba, y arranca el servicio:

```bash
sudo systemctl start home-geofence
journalctl -u home-geofence -f
```

Sin systemd (o para probar en el PC):

```bash
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
cp config.example.yaml config.yaml   # y edítalo
./venv/bin/python -m home_geofence --config config.yaml
```

### Paso 1 — Tu hijo comparte su ubicación contigo

En el teléfono del hijo: **Google Maps → foto de perfil → Compartir
ubicación → Compartir ubicación → Hasta que lo desactives → elegir tu
cuenta**. Comprueba desde tu propio teléfono que le ves en el mapa.

### Paso 2 — Exporta las cookies de TU cuenta de Google

`locationsharinglib` necesita un fichero `cookies.txt` en formato Netscape de
una sesión de tu cuenta en `google.com`:

1. En un navegador de escritorio, inicia sesión en Google con tu cuenta y
   abre <https://www.google.com/maps>.
2. Instala una extensión que exporte cookies en formato Netscape (por ejemplo
   *Get cookies.txt LOCALLY* para Chrome/Firefox; cualquiera que genere el
   formato "Netscape HTTP Cookie File" sirve).
3. Exporta las cookies de `google.com` y guarda el fichero como
   `pi-home-geofence/cookies.txt` en la Pi (`scp` va bien).
4. Protege el fichero: `chmod 600 cookies.txt`. **Esas cookies dan acceso a tu
   cuenta de Google**; trátalas como una contraseña y no las subas a ningún
   sitio (ya están en `.gitignore`).

Consejo: usa un perfil del navegador que no uses para nada más y **no cierres
sesión** en él; cerrar sesión invalida las cookies exportadas.

Comprueba que funciona y anota el nombre exacto con el que aparece tu hijo:

```bash
./venv/bin/python -m home_geofence --list-people
# - nickname='Juan' full_name='Juan Pérez' id='1234…' lat=-33.44 lon=-70.66 acc=15 m fecha=…
```

### Paso 3 — Configura `config.yaml` y los secretos

Edita `config.yaml` (hay comentarios en cada línea). Lo imprescindible:

| Clave | Qué poner |
|---|---|
| `home.latitude` / `home.longitude` | Coordenadas de tu casa (clic derecho en Google Maps → copia las coordenadas) |
| `google.cookies_file` | Ruta al `cookies.txt` del paso 2 |
| `google.account_email` | Tu cuenta de Google |
| `google.person` | `nickname` o `full_name` tal como lo mostró `--list-people` |
| `notify.telegram` | Token del bot y `chat_id` (ver abajo) |

Los secretos van en `.env` (lo crea `install.sh`, permisos 600) y se
referencian en el YAML como `${TELEGRAM_BOT_TOKEN}`.

**Telegram:** crea un bot hablando con `@BotFather` en Telegram (`/newbot`),
copia el token; luego escribe cualquier mensaje a tu bot y obtén tu
`chat_id` abriendo `https://api.telegram.org/bot<TOKEN>/getUpdates` en el
navegador (aparece como `"chat":{"id":123456789,...}`).

**Correo (opcional):** con Gmail usa `smtp.gmail.com:587` y una *contraseña
de aplicación* (requiere verificación en dos pasos en tu cuenta), nunca la
contraseña normal.

### Probar antes de dejarlo en marcha

```bash
./venv/bin/python -m home_geofence --test-notify   # ¿llega el mensaje a Telegram?
./venv/bin/python -m home_geofence --once          # una consulta real, sin bucle
```

## Configuración de referencia

Todas las claves con sus valores por defecto están en
[`config.example.yaml`](config.example.yaml). Las más útiles para ajustar:

| Clave | Default | Notas |
|---|---|---|
| `home.radius_m` | `100` | Con GPS en interiores, menos de 50 m suele dar problemas |
| `home.hysteresis_m` | `50` | Se sale solo al superar `radius_m + hysteresis_m` |
| `home.confirm_samples` | `2` | Con `poll_interval_s: 60`, el aviso llega 1-2 min tras llegar |
| `poll_interval_s` | `60` | Google actualiza la posición compartida cada pocos minutos; bajar de 30 s no aporta |
| `notify.on_leave` | `true` | `false` = avisar solo de llegadas |
| `notify.quiet_hours` | *(ninguno)* | `{from: 23, to: 7}` silencia de noche (hora local de la Pi) |

Para probar la lógica sin Google, comenta la sección `google` y usa
`file_provider: {path: ./posicion.json}` con un JSON
`{"latitude": …, "longitude": …, "accuracy": 20}`; cambia el fichero y
ejecuta `--once` para simular movimientos.

## Estructura

| Fichero | Rol |
|---|---|
| `home_geofence/geo.py` | Haversine + máquina de estados de la geocerca (sin dependencias) |
| `home_geofence/providers.py` | Fuente de ubicación: Google Maps (`locationsharinglib`) o JSON de prueba |
| `home_geofence/notifiers.py` | Consola, Telegram (Bot API `sendMessage`), correo SMTP |
| `home_geofence/monitor.py` | Bucle, persistencia de estado, horas de silencio, backoff ante errores |
| `home_geofence/config.py` | Carga/validación del YAML, expansión de `${VARIABLES}` |
| `templates/home-geofence.service` | Unidad systemd (se instala con `install.sh`) |
| `tests/` | 30 pruebas de la geocerca, el monitor y la configuración (`pytest`) |

## Problemas frecuentes

* **`No se pudo iniciar sesión con las cookies`** → cookies caducadas o
  exportadas sin haber abierto Google Maps. Repite el paso 2.
* **`X no aparece entre las personas que comparten ubicación contigo`** →
  el hijo dejó de compartir, o `google.person` no coincide; compara con
  `--list-people`.
* **Avisos con retraso** → Google solo refresca la posición compartida cada
  varios minutos y el teléfono debe tener datos y ubicación activos. El
  monitor no puede ir más rápido que eso.
* **Entra/sale varias veces seguidas** → sube `hysteresis_m` o
  `confirm_samples`; el GPS en interiores puede saltar 50-100 m.
* **Nunca "sale" aunque se fue** → si el teléfono se apaga, Google deja de
  actualizar y la última posición sigue siendo "en casa". `max_age_min`
  descarta esas posiciones antiguas, pero no genera una salida por sí solo.

## Desinstalar

```bash
sudo systemctl disable --now home-geofence
sudo rm /etc/systemd/system/home-geofence.service && sudo systemctl daemon-reload
```
