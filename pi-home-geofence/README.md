# pi-home-geofence

Te **avisa en el iPhone cuando tu hijo llega a casa** (y, si quieres, cuando
sale), localizando su teléfono Android a través de Google. Los avisos llegan
a la **app de Home Assistant** (con mapa), a Telegram o por correo. Pensado
para correr 24/7 en una Raspberry Pi, pero funciona en cualquier
Linux/macOS/Windows con Python 3.9+.

Proyecto autocontenido. Opcionalmente se integra con el Home Assistant que
instala [`pi-homeassistant-setup`](../pi-homeassistant-setup/).

## Antes de empezar: cómo funciona (y qué NO hace)

Google **no ofrece ninguna API oficial** para localizar un teléfono. Este
proyecto soporta las dos vías que existen, ambas basadas en ingeniería
inversa mantenida por terceros. Elige una en `config.yaml`:

| Fuente | Qué localiza | Con qué cuenta te autenticas | Proyecto de terceros | Fragilidad |
|---|---|---|---|---|
| **`find_my_device`** (red *Find My Device / Find Hub*) | El **teléfono** del hijo como dispositivo | **La del hijo** (el teléfono es suyo en Find Hub) | [GoogleFindMyTools](https://github.com/leonboe1/GoogleFindMyTools) (GPLv3), incluido como submódulo | Alta: cifrado E2EE, respuesta por push, autenticación solo con Chrome en PC, límites de frecuencia |
| **`google`** (ubicación compartida) | La **persona**, tal como la ves en Maps → *Personas* / Family Link | **La tuya** (cookies del navegador) | [locationsharinglib](https://github.com/costastf/locationsharinglib) | Media: las cookies caducan, endpoint interno de Maps |

Cosas que hay que saber antes de decidir:

* **Google puede romper cualquiera de las dos sin aviso.** Si un día deja de
  funcionar, mira los *issues* del proyecto de terceros antes de tocar nada.
* **`find_my_device` opera con la cuenta del hijo.** En Find Hub un teléfono
  solo lo ve su propietario; no he encontrado en la documentación de Google
  forma de que la cuenta del padre vea el teléfono de un hijo con Family Link
  como *dispositivo* (Family Link lo muestra como *persona*, que es la vía
  `google`). Guarda `secrets.json` como lo que es: **credenciales de la
  cuenta del hijo**.
* **Cada consulta a Find My Device dispara una localización en la red de
  Google.** La integración de Home Assistant que usa la misma técnica trabaja
  con 5 minutos entre consultas; este proyecto impone el mismo mínimo
  (`min_request_interval_s`). No lo bajes para "ir más rápido".
* **Las credenciales caducan** (cookies o tokens; el plazo no está
  documentado). Verás errores claros en el log y habrá que regenerarlas.
* **Ética y legalidad.** Está pensado para un padre/madre y un hijo **menor
  que sabe que su teléfono se localiza**. Monitorizar a un adulto sin su
  consentimiento puede ser ilegal en tu país; no uso ni recomiendo este
  proyecto para eso.

## Cómo funciona

```
 teléfono del hijo ─┬─(red Find My Device, cifrado E2EE)──▶ Google ─┐
                    └─(Maps: compartir ubicación contigo)─▶ Google ─┤
                                                                     │
        Raspberry Pi ◀── find_my_device (secrets.json)  ó  google ───┘
             │             (cookies.txt)
             ├─ geocerca: ¿a < 100 m de casa?  (histéresis + confirmación)
             │
             └─ transición ENTRÓ / SALIÓ ──▶ Home Assistant (app iOS, con mapa)
                                             · Telegram · correo · log
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
git clone --recurse-submodules <este-repositorio>   # o: git submodule update --init
cd pi-home-geofence
./install.sh          # venv, dependencias (incl. Find My Device), config.yaml, .env y unidad systemd
./install.sh --no-fmd # igual, pero sin el submódulo ni las dependencias de Find My Device
```

Después, completa los pasos de la fuente elegida, prueba, y arranca:

```bash
sudo systemctl start home-geofence
journalctl -u home-geofence -f
```

Sin systemd (o para probar en el PC):

```bash
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt -r requirements-fmd.txt
cp config.example.yaml config.yaml   # y edítalo
./venv/bin/python -m home_geofence --config config.yaml
```

Para recibir los avisos en el iPhone con mapa, sigue
[docs/HOME-ASSISTANT.md](docs/HOME-ASSISTANT.md) (app Companion de Home
Assistant). Telegram y correo se configuran más abajo.

## Fuente A — Find My Device (el teléfono como dispositivo)

### A1 — Preparar el teléfono del hijo

En el Android del hijo: *Ajustes → Google → Todos los servicios → Encontrar
mi dispositivo* (o *Find Hub*) activado, y en *Encontrar tus dispositivos sin
conexión* elige **"Con la red en todas las zonas"**. Sin esto, la
herramienta muestra "Your encryption data is locked on your device" y no hay
ubicaciones que descifrar (limitación documentada por GoogleFindMyTools).

### A2 — Generar `secrets.json` en un PC con Chrome

Se hace **una vez, en un PC** (Windows/macOS/Linux x86). El README de la
herramienta indica que la autenticación **no funciona en ARM Linux**, es
decir, no la hagas en la Pi. Necesita **Google Chrome actualizado**.

```bash
cd pi-home-geofence/vendor/GoogleFindMyTools      # (tras git submodule update --init)
python3 -m venv venv && source venv/bin/activate  # Windows: venv\Scripts\activate
pip install -r requirements.txt
python main.py
```

1. Se abre Chrome: inicia sesión **con la cuenta de Google del hijo**.
2. `main.py` lista los dispositivos de esa cuenta; **escribe el número del
   teléfono** y pulsa Enter. Te pedirá **iniciar sesión otra vez** (es para
   obtener la clave de cifrado de extremo a extremo). Al final imprime las
   últimas ubicaciones.
3. Ese ciclo completo deja en `Auth/secrets.json` todo lo necesario
   (`username`, `aas_token`, `fcm_credentials`, `shared_key`, `owner_key`).
   El monitor lo comprueba y se niega a arrancar si falta algo, para no
   intentar nunca abrir Chrome en la Pi.
4. Copia el fichero a la Pi como `pi-home-geofence/secrets.json` y protégelo:
   `chmod 600 secrets.json`. Está en `.gitignore`.

Anota el nombre del teléfono tal como lo listó `main.py` (o su *canonic id*)
y ponlo en `find_my_device.device`. Desde la Pi puedes comprobarlo con:

```bash
./venv/bin/python -m home_geofence --list-devices
```

> La integración de Home Assistant que usa esta misma técnica advierte que
> Google "ata" las claves a la cuenta y puede revocarlas si las peticiones
> llegan desde otra IP o región. Genera `secrets.json` desde la **misma red**
> donde va a correr la Pi si puedes.

## Fuente B — Ubicación compartida (Maps / Find Hub → Personas / Family Link)

### B1 — Tu hijo comparte su ubicación contigo

En el teléfono del hijo: **Google Maps → foto de perfil → Compartir
ubicación → Compartir ubicación → Hasta que lo desactives → elegir tu
cuenta**. Si ya lo ves en **Find Hub → Personas** o en **Family Link**, es la
misma compartición (Google usa un único sistema de *Location Sharing* para
Maps, Find Hub, Family Link y Seguridad personal) y no hay que hacer nada más.

### B2 — Exporta las cookies de TU cuenta de Google

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

## Configurar `config.yaml` y los avisos

Edita `config.yaml` (hay comentarios en cada línea). Lo imprescindible:

| Clave | Qué poner |
|---|---|
| `home.latitude` / `home.longitude` | Coordenadas de tu casa (clic derecho en Google Maps → copia las coordenadas) |
| `find_my_device.secrets_file` / `.device` | Fuente A: ruta a `secrets.json` y nombre del teléfono (`--list-devices`) |
| `google.cookies_file` / `.account_email` / `.person` | Fuente B: cookies, tu cuenta y el `nickname`/`full_name` de `--list-people` |
| `poll_interval_s` | `300` con Find My Device (no bajar); `60` va bien con ubicación compartida |
| `notify.home_assistant.webhook_url` | Avisos en el iPhone vía app Companion, ver [docs/HOME-ASSISTANT.md](docs/HOME-ASSISTANT.md) |
| `notify.telegram` | Token del bot y `chat_id` (ver abajo) |

Solo puede haber **una** fuente activa (`find_my_device`, `google` o
`file_provider`); el monitor rechaza la configuración si hay varias.

Los secretos van en `.env` (lo crea `install.sh`, permisos 600) y se
referencian en el YAML como `${HA_WEBHOOK_ID}` o `${TELEGRAM_BOT_TOKEN}`.

**Telegram:** crea un bot hablando con `@BotFather` en Telegram (`/newbot`),
copia el token; luego escribe cualquier mensaje a tu bot y obtén tu
`chat_id` abriendo `https://api.telegram.org/bot<TOKEN>/getUpdates` en el
navegador (aparece como `"chat":{"id":123456789,...}`).

**Correo (opcional):** con Gmail usa `smtp.gmail.com:587` y una *contraseña
de aplicación* (requiere verificación en dos pasos en tu cuenta), nunca la
contraseña normal.

### Probar antes de dejarlo en marcha

```bash
./venv/bin/python -m home_geofence --test-notify   # ¿llega el aviso al iPhone / Telegram?
./venv/bin/python -m home_geofence --once          # una consulta real, sin bucle
```

Con `find_my_device`, `--once` tarda unos segundos: envía la petición y
espera la respuesta push de Google (`request_timeout_s`, 60 s por defecto).

## Configuración de referencia

Todas las claves con sus valores por defecto están en
[`config.example.yaml`](config.example.yaml). Las más útiles para ajustar:

| Clave | Default | Notas |
|---|---|---|
| `home.radius_m` | `100` | Con GPS en interiores, menos de 50 m suele dar problemas |
| `home.hysteresis_m` | `50` | Se sale solo al superar `radius_m + hysteresis_m` |
| `home.confirm_samples` | `2` | Con dos muestras y 5 min de intervalo, el aviso llega ~10 min tras llegar; pon `1` si prefieres rapidez a robustez |
| `poll_interval_s` | `300` | Find My Device: mínimo 300. Ubicación compartida: 60 (bajar de 30 no aporta) |
| `find_my_device.min_request_interval_s` | `300` | Garantía adicional: nunca se consulta a Google más a menudo, aunque `poll_interval_s` sea menor |
| `find_my_device.request_timeout_s` | `60` | Espera máxima de la respuesta push |
| `notify.on_leave` | `true` | `false` = avisar solo de llegadas |
| `notify.quiet_hours` | *(ninguno)* | `{from: 23, to: 7}` silencia de noche (hora local de la Pi) |

Para probar la lógica sin Google, deja solo
`file_provider: {path: ./posicion.json}` con un JSON
`{"latitude": …, "longitude": …, "accuracy": 20}`; cambia el fichero y
ejecuta `--once` para simular movimientos.

## Estructura

| Fichero | Rol |
|---|---|
| `home_geofence/geo.py` | Haversine + máquina de estados de la geocerca (sin dependencias) |
| `home_geofence/providers.py` | Fuentes: ubicación compartida (`locationsharinglib`) y JSON de prueba |
| `home_geofence/findmydevice.py` | Fuente Find My Device sobre `vendor/GoogleFindMyTools` (submódulo GPLv3) |
| `home_geofence/notifiers.py` | Home Assistant (webhook), Telegram (Bot API `sendMessage`), correo SMTP, consola |
| `home_geofence/monitor.py` | Bucle, persistencia de estado, horas de silencio, backoff ante errores |
| `home_geofence/config.py` | Carga/validación del YAML, expansión de `${VARIABLES}` |
| `homeassistant/packages/hijo_en_casa.yaml` | Automatizaciones de HA: aviso con mapa en la app Companion |
| `docs/HOME-ASSISTANT.md` | Guía de la app iOS (Companion) y de la integración alternativa de HA |
| `templates/home-geofence.service` | Unidad systemd (se instala con `install.sh`) |
| `requirements-fmd.txt` | Dependencias de GoogleFindMyTools sin `frida` (no se usa para localizar) |
| `tests/` | 48 pruebas: geocerca, monitor, configuración, notificadores y proveedor Find My Device (`pytest`) |

**Qué está probado y qué no.** La geocerca, el monitor, la configuración y
los notificadores tienen pruebas automáticas. El proveedor `find_my_device`
tiene pruebas de su lógica (validación de `secrets.json`, elección del
informe más reciente, límite de frecuencia, redirección del fichero de
secretos dentro de la herramienta) pero **la consulta real a Google no se ha
podido probar en el desarrollo** por no disponer de una cuenta y un teléfono
de prueba: sigue paso a paso el mismo flujo que `main.py` de la herramienta
y reutiliza sus funciones, pero verifícalo con `--once` antes de fiarte.

## Problemas frecuentes

* **`secrets.json está incompleto (faltan: owner_key…)`** → en el PC
  ejecutaste `main.py` pero no llegaste a **localizar** un dispositivo (paso
  A2.2), que es lo que rellena las claves de cifrado. Repítelo.
* **`Sin respuesta de Google en 60 s`** → el teléfono está apagado, sin red,
  o la red Find My Device no tiene informes recientes. No es un error del
  monitor; si persiste con el teléfono encendido, comprueba A1.
* **`No se pudo descifrar la clave del dispositivo`** → se reinició el
  cifrado E2EE de la cuenta (o cambió el bloqueo de pantalla). Regenera
  `secrets.json` en el PC.
* **`Your encryption data is locked on your device`** (en el PC) → falta el
  paso A1 en el teléfono.
* **`No se pudo iniciar sesión con las cookies`** → cookies caducadas o
  exportadas sin haber abierto Google Maps. Repite B2.
* **`Sin posición para X`** → con `google`, el hijo dejó de compartir o
  `person` no coincide (`--list-people`); con `find_my_device`, el teléfono
  no aparece en la cuenta (`--list-devices`).
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
