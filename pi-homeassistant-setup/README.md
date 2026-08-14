# pi-homeassistant-setup

Instala **Home Assistant en modo Container (Docker)** sobre una Raspberry
Pi 4 que **ya trabaja como servidor de impresión AirPrint** (CUPS + brlaser +
Avahi), **sin romper ese servicio**. La impresión es la carga principal de la
Pi y este proyecto la trata como intocable.

Proyecto independiente y autocontenido: no depende de ningún otro
repositorio ni comparte código con otros proyectos.

> **Documentación oficial consultada y fecha de verificación:** el
> `docker-compose` de Home Assistant Container y el procedimiento de
> instalación de Docker Engine se tomaron de
> [home-assistant.io/installation/linux](https://www.home-assistant.io/installation/linux)
> y [docs.docker.com/engine/install/debian](https://docs.docker.com/engine/install/debian/)
> el **2026-08-14**. Ambos cambian con el tiempo (HA publica versión mensual):
> si pasó mucho desde esa fecha, revísalos antes de instalar.

## Por qué modo Container (decisión de diseño, no preferencia)

| Modo | ¿Sirve aquí? | Motivo |
|---|---|---|
| **Container (este proyecto)** | ✅ | Corre como un contenedor más sobre el Raspberry Pi OS existente; CUPS/Avahi siguen intactos |
| Home Assistant OS | ❌ **NUNCA en esta Pi** | Se apodera de la máquina completa: **eliminaría el servidor de impresión** |
| Home Assistant Supervised | ❌ | Impone requisitos estrictos sobre el anfitrión y puede alterar configuración existente |
| Core (venv) | ➖ | Viable pero más frágil de mantener que el contenedor |

`00-preflight.sh` detecta CUPS/avahi y lo informa; si encuentra rastros de
HA OS o Supervised, **aborta**.

## Arquitectura

```
                 ┌──────────────────────── Raspberry Pi 4 (2 GB, WiFi) ──┐
 iPhone/PC ──────┼─▶ CUPS :631 + Avahi (AirPrint) ── (USB) ─▶ impresora  │
                 │        ▲ intocable                                    │
 navegador ──────┼─▶ Home Assistant :8123 (contenedor Docker,            │
 app Casa ───────┼─▶ HomeKit Bridge (opcional, se configura en HA)       │
                 │        └── network_mode: host (descubrimiento LAN)    │
                 └────────────────────────────────────────────────────────┘
```

- **Puertos:** CUPS mantiene el 631; HA usa el **8123** (y ahí se queda, aun
  cuando instalaciones nuevas de HA OS hayan pasado al 80). El despliegue
  falla con mensaje claro si el 8123 está ocupado.
- **Red del contenedor:** `network_mode: host`, requisito para el
  descubrimiento automático de dispositivos.
- **Coexistencia mDNS (riesgo verificado, no asumido):** el zeroconf de HA y
  el HomeKit Bridge publican mDNS sobre la misma interfaz donde avahi-daemon
  anuncia AirPrint. Normalmente coexisten (HA usa su propia pila zeroconf en
  Python, no compite por el socket de Avahi), pero `90-verify.sh` lo
  **comprueba tras el despliegue**: exige que el anuncio `_ipp._tcp` de
  AirPrint siga visible y reporta el de `_home-assistant._tcp`/`_hap._tcp`.
  En las pruebas de este proyecto no se observó conflicto; si en tu red
  ambos anuncios no conviven, es una limitación a reportar, no a silenciar.

## Instalación

```bash
git clone <este-repositorio>
cd pi-homeassistant-setup
sudo ./install.sh --dry-run    # SIEMPRE primero: muestra lo que haría
sudo ./install.sh
```

Antes de la primera ejecución real, respalda la configuración del servidor
de impresión (es la red de seguridad barata):

```bash
sudo tar czf ~/respaldo-impresion-$(date +%F).tgz \
  /etc/cups/ppd /etc/cups/printers.conf /etc/avahi/services 2>/dev/null
```

### Flags

| Flag | Efecto |
|---|---|
| `--dry-run` | Muestra los comandos que modificarían el sistema |
| `--validate-only` | Solo preflight + diagnóstico end-to-end; no instala |
| `--skip-hardening` | Omite las mitigaciones de microSD (no recomendado) |
| `--yes`, `-y` | Responde 'sí' a las confirmaciones |
| `--help`, `-h` | Ayuda |

### Etapas

| Script | Qué hace | ¿Modifica el sistema? |
|---|---|---|
| `00-preflight.sh` | Detecta HA OS/Supervised (aborta), CUPS/avahi (informa), RAM/disco/arquitectura, puerto 8123 | No |
| `10-docker.sh` | Docker Engine + plugin compose desde el repositorio apt oficial | Sí |
| `30-hardening-sd.sh` | Rotación de logs de Docker + recorder de ejemplo (corre **antes** del despliegue: las opciones de log solo aplican a contenedores nuevos) | Sí |
| `20-homeassistant.sh` | Renderiza el compose oficial y despliega el contenedor | Sí |
| `90-verify.sh` | Criterio doble: HA responde **y** la impresión sigue viva; coexistencia mDNS | No |

Todos idempotentes y ejecutables por separado; `90-verify.sh` sirve como
diagnóstico en cualquier momento.

### Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `HA_CONTAINER_NAME` | `homeassistant` | Nombre del contenedor |
| `HA_IMAGE` | `ghcr.io/home-assistant/home-assistant:stable` | Imagen oficial |
| `HA_BASE_DIR` | `/opt/homeassistant` | Dónde vive el compose |
| `HA_CONFIG_DIR` | `/opt/homeassistant/config` | `/config` persistente de HA |
| `HA_TZ` | `America/Santiago` | Zona horaria del contenedor |
| `HA_PORT` | `8123` | Puerto de la interfaz (informativo: en modo host no se mapea) |
| `DOCKER_LOG_MAX_SIZE` / `DOCKER_LOG_MAX_FILE` | `10m` / `3` | Rotación de logs de Docker |
| `RECORDER_PURGE_KEEP_DAYS` | `7` | Días de histórico en el recorder de ejemplo |

## Criterio de éxito

**Doble e inseparable:** la interfaz de HA responde en el 8123 **y** la cola
de impresión sigue aceptando trabajos con su anuncio AirPrint publicado.
`90-verify.sh` falla si cualquiera de las dos patas cae.

## Desgaste de la microSD — requisito, no consejo

HA escribe continuamente su histórico y Docker suma logs y capas. Bajo esa
carga, una microSD suele fallar **en el orden de 1 a 2 años** (cifra
estimada, procedente de tutoriales de la comunidad, no de fuente primaria:
tómala como orden de magnitud). Mitigaciones que aplica `30-hardening-sd.sh`:

1. **Rotación de logs de Docker** (`/etc/docker/daemon.json`, json-file con
   `max-size`/`max-file` acotados, fusionado sin pisar claves existentes).
2. **Recorder acotado**: genera `recorder.yaml.example` en el directorio de
   configuración con `purge_keep_days`, `commit_interval` y exclusiones de
   entidades ruidosas. HA no lo lee solo: copia el bloque a
   `configuration.yaml` (paso guiado en el runbook).
3. **La mitigación real: migrar a SSD USB.** El script **no** lo hace — es
   una operación destructiva que merece decisión humana. Procedimiento
   general: clonar la microSD al SSD (`rpi-clone` o Raspberry Pi Imager +
   restaurar respaldo), habilitar arranque USB en la EEPROM de la Pi 4
   (`raspi-config` → opciones de arranque) y arrancar desde el SSD. Hazlo
   con el servidor de impresión ya respaldado.

## Actualizar Home Assistant (manual en modo Container)

HA publica versión cada mes; en Container la actualización es manual:

```bash
sudo docker compose -f /opt/homeassistant/docker-compose.yml pull
sudo docker compose -f /opt/homeassistant/docker-compose.yml up -d
```

(Descarga la imagen nueva y recrea el contenedor solo si cambió; la
configuración en `/config` persiste. Después, borra imágenes viejas con
`sudo docker image prune -f` para no acumular capas en la microSD.)

## HomeKit Bridge y el límite de Apple

- HA incluye la integración **HomeKit Bridge** para exponer entidades a la
  app Casa: se configura **desde la interfaz de HA** (Ajustes → Dispositivos
  y servicios → Añadir integración → HomeKit Bridge) escaneando el código QR
  con el iPhone. No se automatiza por archivo y este instalador no lo
  intenta; solo queda documentado aquí.
- **Límite que hay que saber:** la Raspberry **no puede ser home hub de
  Apple**. Apple restringe ese rol a HomePod, HomePod mini y Apple TV (el
  iPad quedó excluido con la nueva arquitectura de Casa). Sin un hub de
  Apple **no hay control fuera de casa ni automatizaciones de HomeKit**.
- Las **automatizaciones de Home Assistant** sí corren en la Pi y no
  necesitan ningún hub de Apple: **esa es la vía recomendada**. HomeKit
  queda como espejo de control local desde la app Casa.

## Limitaciones conocidas del modo Container

- **Sin Supervisor ni tienda de add-ons.** Lo que en HA OS es un add-on aquí
  se resuelve con otro contenedor o servicio del sistema.
- **Integraciones que dependen de add-ons** — por ejemplo **Thread** y
  **Z-Wave** — no tienen soporte inmediato en instalaciones Container
  (requieren desplegar sus servicios por separado).
- **Actualizaciones manuales** (procedimiento arriba).
- 2 GB de RAM alcanzan para CUPS + Docker + HA **sin holgura**: el preflight
  lo reporta; evita apilar más servicios pesados en esta Pi.

## Documentación

- [docs/RUNBOOK-validacion.md](docs/RUNBOOK-validacion.md) — validación
  manual paso a paso con troubleshooting.
- [docs/ROLLBACK.md](docs/ROLLBACK.md) — reversión completa; lo que se lee
  cuando algo sale mal a las 11 de la noche.

## Desarrollo

```bash
shellcheck -x install.sh lib/common.sh scripts/*.sh   # sin hallazgos
```
