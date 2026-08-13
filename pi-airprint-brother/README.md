# pi-airprint-brother

Convierte una **Brother DCP-1602** (impresora láser solo USB, sin red) en una
impresora **AirPrint** usando una Raspberry Pi como servidor de impresión.
Imprime desde iPhone, iPad y macOS sin instalar nada en los dispositivos.

## Por qué hace falta la Pi

- La DCP-1602 **solo tiene USB 2.0**: no trae WiFi ni Ethernet.
- Su lenguaje de impresión es **XL2HB**, un protocolo *host-based* propietario
  de Brother: la impresora no interpreta PostScript ni PCL, el trabajo lo
  rasteriza el ordenador. Por eso **un print server USB genérico no sirve**
  con este modelo — el driver tiene que ejecutarse en la Pi.
- El driver libre correcto es **brlaser** (paquete Debian
  `printer-driver-brlaser`). Su README lista "Brother DCP-1600 series" como
  soportada y su `brlaser.drv.in` declara:

  ```
  MFG:Brother;CMD:PJL,XL2HB;MDL:DCP-1600 series;CLS:PRINTER;CID:Brother Laser Type1
  ```

```
iPhone/iPad/Mac ──(mDNS/AirPrint por WiFi)──▶ Raspberry Pi ──(USB)──▶ Brother DCP-1602
                                              CUPS + brlaser
                                              Avahi (mDNS)
```

## Qué exige AirPrint (y por qué iOS "no ve" impresoras)

El anuncio mDNS debe cumplir **dos condiciones, ambas obligatorias**:

1. El subtipo `_universal._sub._ipp._tcp`.
2. Un registro TXT `URF` presente y **no vacío** (aquí se usa `URF=DM3`).

Si falta cualquiera de las dos, iOS simplemente **no lista la impresora y no
muestra ningún error**. Debian/Raspberry Pi OS trae CUPS parcheado para
publicar ambas cosas por sí solo cuando la cola está compartida; por eso el
anuncio manual de Avahi de este proyecto es **condicional**: solo se genera si
el de CUPS está incompleto (ver `scripts/30-airprint.sh`). Generarlo siempre
haría que macOS mostrara la impresora duplicada.

## Requisitos

- Raspberry Pi (cualquier modelo con USB) con Raspberry Pi OS / Debian.
- Brother DCP-1602 conectada por USB a la Pi y encendida.
- La Pi en la misma red WiFi/LAN que los dispositivos que imprimirán.

## Instalación rápida

```bash
git clone <este-repositorio>
cd pi-airprint-brother
sudo ./install.sh
```

`install.sh` orquesta todos los pasos y termina imprimiendo una página de
prueba que **debes validar visualmente**: el criterio de éxito es una hoja
física legible, no un job "completado" en CUPS.

La instalación deja activada la **consola web de CUPS** (solo consulta desde
la red) en `http://<hostname>.local:631/printers/` para ver la cola y el
historial de trabajos. La administración remota (`cupsctl --remote-admin`)
queda desactivada a propósito; actívala tú solo si la necesitas, sabiendo que
expone la configuración de CUPS a toda la LAN.

### Opciones de install.sh

| Opción | Efecto |
|---|---|
| `--dry-run` | Muestra los comandos que modificarían el sistema, sin ejecutarlos |
| `--validate-only` | No instala nada: solo preflight + verificación end-to-end |
| `--skip-airprint` | Crea la cola pero omite la publicación mDNS |
| `--yes`, `-y` | Responde 'sí' a las confirmaciones (no a la validación visual) |
| `--help`, `-h` | Ayuda |

### Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `QUEUE_NAME` | `Brother_DCP1602` | Nombre de la cola CUPS y del anuncio AirPrint |
| `QUEUE_LOCATION` | `Oficina` | Ubicación mostrada en CUPS/AirPrint |
| `PPD_OVERRIDE` | *(vacío)* | Fuerza un PPD concreto en lugar de la detección automática |

Ejemplo:

```bash
sudo QUEUE_NAME=Impresora_Salon QUEUE_LOCATION=Salon ./install.sh --yes
```

## Nada hardcodeado: detección en runtime

- **URI USB**: incluye el número de serie de cada unidad
  (`usb://Brother/DCP-1602?serial=...`), así que se detecta con
  `lpinfo -l -v` buscando `usb://Brother`.
- **PPD**: su nombre varía entre versiones de brlaser. Se busca con
  `lpinfo -m | grep -i brlaser`, prefiriendo `DCP-1600` y con `DCP-1510` como
  alternativa. `PPD_OVERRIDE` permite forzar cualquier otro.

## Estructura

```
pi-airprint-brother/
├── README.md
├── install.sh                       # orquestador de un toque
├── lib/common.sh                    # logging, dry-run, guards, estado
├── scripts/
│   ├── 00-preflight.sh              # detecta hardware, NO modifica nada
│   ├── 10-install-packages.sh       # cups, brlaser, avahi, ghostscript
│   ├── 20-add-queue.sh              # detecta URI+PPD, crea la cola
│   ├── 30-airprint.sh               # publicación mDNS condicional
│   └── 90-verify.sh                 # verificación end-to-end
├── templates/airprint.service.tmpl  # anuncio Avahi (solo si hace falta)
└── docs/RUNBOOK-validacion-driver.md
```

Todos los scripts son **idempotentes** y pueden ejecutarse por separado
(aceptan `--dry-run`, `--yes` y `--help`). El estado de los pasos completados
se registra en `/var/lib/pi-airprint-brother/state`.

## Verificación

```bash
sudo ./scripts/90-verify.sh              # completa, con página de prueba
sudo ./scripts/90-verify.sh --checks-only  # solo comprobaciones, sin imprimir
```

La validación manual paso a paso (incluida la del driver), la tabla de
troubleshooting y el procedimiento de rollback están en
[docs/RUNBOOK-validacion-driver.md](docs/RUNBOOK-validacion-driver.md).

## Limitaciones conocidas

- **El escaneo queda fuera de alcance.** La DCP-1602 es un multifunción, pero
  su escáner requiere el backend SANE propietario de Brother (`brscan`), cuya
  disponibilidad y funcionamiento en ARM **no está verificada**. Este proyecto
  solo cubre la impresión.
- Impresión monocroma y a una cara (la impresora no tiene dúplex automático).
- La Pi debe quedar siempre encendida y con la impresora conectada.

## Desarrollo

Validación estática del proyecto:

```bash
cd pi-airprint-brother
shellcheck -x install.sh lib/common.sh scripts/*.sh   # debe salir sin hallazgos
xmllint --noout templates/airprint.service.tmpl        # XML bien formado
```
