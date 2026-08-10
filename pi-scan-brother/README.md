# pi-scan-brother

Expone por red el **escáner** de una **Brother DCP-1602** (multifuncional
láser monocromática, solo USB 2.0) conectada a una Raspberry Pi, para
escanear desde **iOS, Windows, Android y macOS**.

Proyecto independiente y autocontenido: instala en una Pi limpia sin ningún
prerrequisito de otro proyecto. El escáner usa **SANE**; no usa CUPS ni nada
de la pila de impresión.

## Arquitectura

```
                    ┌───────────────────────────── Raspberry Pi ─┐
Windows (eSCL)   ──┐│                                            │
Android (Mopria) ──┼┼─▶ AirSane  :8090 ──┐                       │
macOS (AirScan)  ──┘│   (eSCL + mDNS)    ├─▶ SANE ──▶ backend    │──(USB)──▶ Brother
                    │                    │           brother     │           DCP-1602
iOS (Safari/PWA) ───┼─▶ scanservjs :8080─┘   (dmikushin/brscan)  │
                    │   (web/PWA)                                │
                    └────────────────────────────────────────────┘
```

## Por qué DOS servidores

| Cliente | Qué cliente trae | Servidor que lo atiende |
|---|---|---|
| Windows 10/11 | Cliente eSCL integrado, descubre por mDNS | **AirSane** |
| Android | App Mopria Scan (habla eSCL) | **AirSane** |
| macOS | Image Capture / Captura de Imagen (habla AirScan) | **AirSane** |
| iOS | **Ninguno** (ver abajo) | **scanservjs** (web/PWA) |

**iOS no tiene cliente de escáner de red, sin rodeos:** el "Escanear
documentos" de Notas y Archivos usa la **cámara**, no busca escáneres en la
LAN, y no existe un equivalente de AirPrint para escanear en iPhone. La única
vía práctica es una interfaz web abierta en Safari e instalada como PWA
("Añadir a pantalla de inicio"). Por eso, además de AirSane, se instala
scanservjs — el propio README de AirSane recomienda scanservjs como frontend
web, que es más completo que el suyo.

## El driver: el eslabón crítico

- El driver oficial de Brother (**brscan4**) solo viene precompilado para
  **i386**, y el código fuente que Brother publica está incompleto. La ruta
  habitual en ARM (qemu con entorno i386 virtual) es frágil y **no se usa
  aquí**.
- Se usa la reimplementación open source
  [dmikushin/brscan](https://github.com/dmikushin/brscan), con binarios
  precompilados para amd64, arm64 y armv7 en sus GitHub Releases. Si no hay
  binario para la arquitectura detectada, se compila desde el código fuente
  (dependencias: libsane-dev, libusb-dev, libjpeg-dev, pkg-config, cmake,
  gcc).
- **Incertidumbre conocida:** no está confirmado que la DCP-1602 aparezca en
  el `data/Brsane.ini` de ese proyecto. `10-driver.sh` lo verifica en la
  instalación y, si no está, avisa de que se intenta con el perfil de la
  **DCP-1510** (mismo motor, USB ID de referencia `04f9:02d0`). En ese caso la
  compatibilidad es **probable, no confirmada** — de ahí que la validación
  con un escaneo real sea obligatoria.

## Instalación

```bash
git clone <este-repositorio>
cd pi-scan-brother
sudo ./install.sh
```

### Flags

| Flag | Efecto |
|---|---|
| `--dry-run` | Muestra los comandos que modificarían el sistema, sin ejecutarlos |
| `--validate-only` | Solo comprobaciones y diagnóstico; no instala nada |
| `--skip-airsane` | No instala AirSane (Windows/Android/macOS quedan sin eSCL) |
| `--skip-scanservjs` | No instala scanservjs (iOS queda sin vía de escaneo) |
| `--yes`, `-y` | Responde 'sí' a las confirmaciones (no a la validación visual) |
| `--help`, `-h` | Ayuda |

### Etapas

| Script | Qué hace | ¿Modifica el sistema? |
|---|---|---|
| `00-preflight.sh` | Detecta el escáner USB (product ID en runtime), SO, CUPS, puertos | No |
| `10-driver.sh` | Instala el backend SANE (binario o compilación), `dll.conf`, regla udev | Sí |
| `20-verify-sane.sh` | `scanimage -L` + **escaneo real a archivo** + confirmación visual | Solo escribe el archivo |
| `30-airsane.sh` | Compila e instala AirSane (eSCL/mDNS), asegura avahi | Sí |
| `40-scanservjs.sh` | Instala scanservjs desde el .deb de sus releases | Sí |
| `90-verify.sh` | Diagnóstico end-to-end standalone, ejecutable en cualquier momento | No |

Todos los scripts son idempotentes (reejecutar no duplica reglas udev, líneas
en `dll.conf` ni unidades systemd), se pueden ejecutar por separado y aceptan
`--dry-run`, `--yes` y `--help`.

### Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `AIRSANE_PORT` | `8090` | Puerto web de AirSane |
| `SCANSERVJS_PORT` | `8080` | Puerto web de scanservjs |
| `SCAN_TEST_DIR` | `/var/lib/pi-scan-brother/test-scans` | Carpeta de escaneos de prueba |
| `SCAN_RESOLUTION` | `150` | Resolución (dpi) del escaneo de prueba |
| `BRSCAN_REPO` | `dmikushin/brscan` | Origen del backend SANE |
| `AIRSANE_REPO` | `SimulPiscator/AirSane` | Origen de AirSane |
| `SCANSERVJS_REPO` | `sbs20/scanservjs` | Origen de scanservjs |

Nada va hardcodeado: el product ID USB se detecta en runtime con
`lsusb -d 04f9:` (varía por modelo), y versiones y assets se resuelven contra
el último GitHub Release de cada proyecto.

## Criterio de éxito

**Un archivo escaneado que se abre y se ve legible.** Que `scanimage -L`
liste el dispositivo **no** es éxito (solo prueba que el backend carga) y los
scripts no lo reportan como tal. `20-verify-sane.sh` hace un escaneo real a
archivo y pide confirmación visual explícita, que nunca se auto-responde.

## Decisiones de diseño

- **dmikushin/brscan en lugar de brscan4 + qemu:** binarios ARM nativos
  frente a una emulación i386 frágil.
- **Dos servidores en lugar de uno:** ningún servidor cubre los cuatro
  sistemas operativos (ver matriz de clientes).
- **Publicación mDNS delegada en AirSane** (que requiere avahi-daemon activo;
  sin él falla con "Bad State (-2)").
- **Puertos 8080/8090 por defecto**, comprobados en preflight para que no
  choquen con nada existente (CUPS, si está, usa el 631).

## Limitaciones conocidas

- **Compatibilidad del modelo:** si la DCP-1602 no figura en el `Brsane.ini`
  del backend, se usa el perfil de la DCP-1510 y la compatibilidad es
  *probable*, no confirmada (ver arriba).
- **iOS sin integración nativa:** no existe cliente de escáner de red en
  iPhone/iPad; la vía es la PWA de scanservjs. Es una limitación de iOS, no
  de este proyecto.
- **Un consumidor a la vez (contención SANE):** AirSane y scanservjs comparten
  el mismo escáner físico, que admite un solo consumidor simultáneo. Ninguno
  de los dos mantiene el dispositivo abierto en reposo (lo abren solo durante
  el escaneo), así que en la práctica coexisten; pero si dos clientes escanean
  **a la vez**, el segundo recibirá un error de dispositivo ocupado
  (`Device busy`) y debe reintentar al terminar el primero. No hay un
  mecanismo de cola entre ambos servidores; se documenta el comportamiento en
  el runbook.
- **Convivencia con un servidor de impresión:** la DCP-1602 es un solo
  dispositivo USB multifunción. Si en la misma Pi corre CUPS, ambas pilas
  hablan al mismo `04f9:xxxx`; normalmente coexisten (interfaces USB
  separadas), pero el módulo de kernel `usblp` o el backend `usb` de CUPS
  pueden acaparar el dispositivo. El preflight lo detecta y avisa; el
  diagnóstico está en `docs/RUNBOOK-validacion.md`.

## Documentación

- [docs/CLIENTES.md](docs/CLIENTES.md) — cómo escanear desde iOS, Windows,
  Android y macOS, paso a paso.
- [docs/RUNBOOK-validacion.md](docs/RUNBOOK-validacion.md) — validación
  manual, troubleshooting y rollback completo.

## Desarrollo

```bash
shellcheck -x install.sh lib/common.sh scripts/*.sh   # debe salir sin hallazgos
```
