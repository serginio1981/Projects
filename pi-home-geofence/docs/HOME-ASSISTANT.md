# Avisos en el iPhone con Home Assistant (app Companion)

La app **Home Assistant Companion** para iOS recibe notificaciones push con
**mapa**, agrupa los avisos, respeta los modos de concentración y muestra el
histórico. Es la "app para iOS" de este proyecto: no hay que escribir ni
firmar una app propia, y funciona con el Home Assistant que instala
[`pi-homeassistant-setup`](../../pi-homeassistant-setup/) en la misma Pi.

Hay dos montajes posibles. Ambos usan el package
[`homeassistant/packages/hijo_en_casa.yaml`](../homeassistant/packages/hijo_en_casa.yaml).

| Montaje | Quién decide "llegó/salió" | Fuente de ubicación | Cuándo elegirlo |
|---|---|---|---|
| **A. pi-home-geofence → webhook → HA** | Este monitor (histéresis, confirmación, filtros) | `find_my_device` o `google` | Quieres la lógica de este proyecto y/o la ubicación compartida de Maps |
| **B. Integración *Google Find My Device* de HA** | Home Assistant (zona `home` + `for: 3 min`) | Solo red Find My Device | Prefieres no correr nada fuera de HA; la integración está mantenida por terceros y hace lo mismo que nuestro proveedor `find_my_device` |

> Verificado el 2026-09-17 contra la documentación de Home Assistant (trigger
> `webhook`, sintaxis `triggers: - trigger:`) y de la app Companion
> (notificación con mapa vía `data.action_data.latitude/longitude`, apertura
> de URL con `data.url`). Si tu HA es anterior a 2024.10, la sintaxis de
> triggers era `trigger: - platform:`; adapta el package.

## Paso 0 — App Companion en el iPhone

1. Instala **Home Assistant** desde la App Store e inicia sesión contra tu HA
   (`http://<ip-de-la-pi>:8123`). Acepta el permiso de **notificaciones**.
2. Anota el nombre del dispositivo: en HA, *Ajustes → Dispositivos y
   servicios → Mobile App → tu iPhone*. El servicio de aviso se llama
   `notify.mobile_app_<ese nombre en minúsculas y con guiones bajos>`.
   Puedes confirmarlo en *Herramientas para desarrolladores → Acciones*
   escribiendo `notify.mobile_app_`.
3. Prueba desde ahí mismo una acción `notify.mobile_app_<tu_iphone>` con un
   `message` cualquiera: debe sonar el iPhone.

## Paso 1 — Instalar el package

En la Pi (rutas por defecto de `pi-homeassistant-setup`: `/opt/homeassistant/config`):

```bash
sudo mkdir -p /opt/homeassistant/config/packages
sudo cp pi-home-geofence/homeassistant/packages/hijo_en_casa.yaml /opt/homeassistant/config/packages/
```

Añade (una sola vez) a `configuration.yaml`:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

Edita el package y sustituye los marcadores:

| Marcador | Valor |
|---|---|
| `__MOBILE_APP__` | nombre del iPhone (paso 0), p. ej. `iphone_de_sergio` |
| `__WEBHOOK_ID__` | id aleatorio largo: `openssl rand -hex 16` (montaje A) |
| `__DEVICE_TRACKER__` | entidad del teléfono creada por la integración (montaje B) |

Si no usas uno de los dos montajes, borra su automatización del package para
que HA no se queje de una entidad inexistente.

Comprueba y aplica: *Herramientas para desarrolladores → YAML → Comprobar
configuración* y después *Reiniciar*.

## Montaje A — pi-home-geofence avisa a HA por webhook

En `pi-home-geofence/.env`:

```
HA_WEBHOOK_ID=<el mismo id que pusiste en el package>
```

y en `config.yaml`:

```yaml
notify:
  home_assistant:
    webhook_url: http://homeassistant.local:8123/api/webhook/${HA_WEBHOOK_ID}
```

Si el monitor corre en la **misma Pi** que HA, `http://127.0.0.1:8123/...`
es lo más fiable (el webhook está configurado con `local_only: true`, así que
solo acepta llamadas desde la red local).

Prueba:

```bash
./venv/bin/python -m home_geofence --test-notify
```

Debe llegar al iPhone una notificación "✅ Prueba de aviso" con un mapa
centrado en tu casa. A partir de ahí, cada llegada/salida real llega igual,
con la posición del hijo en el mapa y un enlace a Google Maps al tocarla.

El JSON que envía el monitor (por si quieres ampliar la automatización):

```json
{"title": "🏠 Juan llegó a casa", "message": "...", "name": "Juan",
 "event": "entered", "zone": "inside", "latitude": -33.44, "longitude": -70.66,
 "accuracy_m": 18, "distance_m": 12, "address": null, "battery_level": null,
 "timestamp": "2026-09-17T18:05:00+00:00", "maps_url": "https://www.google.com/maps/..."}
```

`event` es `entered`, `left` o `test`.

## Montaje B — Integración "Google Find My Device" de HA

Integración de terceros [BSkando/GoogleFindMy-HA](https://github.com/BSkando/GoogleFindMy-HA)
(no oficial; requiere HA 2025.9.1 o posterior, recomendada 2025.10+ según su
README). Usa la misma ingeniería inversa que nuestro proveedor
`find_my_device` y crea una entidad `device_tracker.<teléfono>` que HA sitúa
en la zona `home` por sí solo.

1. **Instalación manual** (la Pi de `pi-homeassistant-setup` no lleva HACS):
   descarga el repositorio y copia la carpeta `custom_components/googlefindmy`
   a `/opt/homeassistant/config/custom_components/googlefindmy`. Reinicia HA.
2. **Autenticación**: es la misma que en el README de este proyecto, sección
   *Find My Device*: se ejecuta `main.py` de GoogleFindMyTools en un PC con
   Chrome, **con la cuenta del hijo**, se lista y localiza el teléfono una
   vez, y se copia el contenido de `Auth/secrets.json`. Su README pide
   hacerlo desde la **misma red/IP pública** que HA, porque Google puede
   revocar las claves si las peticiones llegan desde otra región.
3. En HA: *Ajustes → Dispositivos y servicios → Añadir integración → Google
   Find My Device* y pega el contenido de `secrets.json`.
4. Opciones que importan: `location_poll_interval` (300 s por defecto; no
   bajes de 60) y `stale_threshold`.
5. Pon el `entity_id` del teléfono en `__DEVICE_TRACKER__` del package. La
   automatización avisa cuando el tracker lleva **3 minutos** en `home` (o
   fuera), que es el equivalente a `confirm_samples` de este proyecto.

Con este montaje pi-home-geofence no hace falta; el resto del package (mapa,
agrupación, horario nocturno) es el mismo.

## Problemas frecuentes

* **No llega nada al iPhone** → prueba primero la acción `notify.mobile_app_…`
  desde *Herramientas para desarrolladores*. Si eso funciona y el webhook no,
  revisa que `HA_WEBHOOK_ID` coincide con el package y que la URL apunta a la
  IP correcta (`curl -X POST -H 'Content-Type: application/json' -d
  '{"title":"t","message":"m"}' http://127.0.0.1:8123/api/webhook/<id>` debe
  devolver 200 y disparar la notificación).
* **Llega sin mapa** → el JSON no traía `latitude`/`longitude` numéricos
  (la rama `default` de la automatización). Con `--test-notify` siempre
  van las coordenadas de casa.
* **Notificaciones duplicadas** → tienes los dos montajes activos a la vez.
  Deja uno.
* **Android en vez de iPhone** → el mismo package funciona; Android ignora
  `action_data` (mapa) y abre el `url` al tocar la notificación.
