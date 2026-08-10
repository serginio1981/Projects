# RUNBOOK — Validación manual del driver y de AirPrint

Procedimiento paso a paso para validar la cadena completa
**iOS → Avahi/mDNS → CUPS → brlaser → Brother DCP-1602 (USB)**.

Úsalo la primera vez que instales, después de actualizar paquetes, o cuando
"antes imprimía y ya no". Cada paso indica el **resultado esperado** y la
**acción correctiva** si no se cumple.

> Recordatorio: el criterio de éxito final es **una hoja física legible**.
> Un job "completed" en CUPS con un driver equivocado puede no imprimir nada
> (o imprimir basura) sin que CUPS reporte error alguno.

---

## Paso 1 — La impresora aparece en el bus USB

```bash
lsusb | grep -i -e 04f9 -e brother
```

- **Resultado esperado:** una línea con el vendor ID `04f9` (Brother), p. ej.
  `Bus 001 Device 004: ID 04f9:xxxx Brother Industries, Ltd`.
- **Acción correctiva:** comprueba alimentación y cable USB; prueba otro
  puerto de la Pi; mira `dmesg | tail -20` justo tras conectar el cable. Si
  el kernel ni siquiera registra el dispositivo, el problema es físico
  (cable/puerto/impresora), no de software.

## Paso 2 — Los paquetes están instalados

```bash
dpkg -s cups printer-driver-brlaser avahi-daemon avahi-utils ghostscript | grep -E '^(Package|Status)'
```

- **Resultado esperado:** cada paquete con `Status: install ok installed`.
- **Acción correctiva:** ejecuta `sudo ./scripts/10-install-packages.sh`.

## Paso 3 — CUPS ve la impresora por USB (URI)

```bash
sudo lpinfo -l -v | grep -A2 usb://Brother
```

- **Resultado esperado:** una URI del tipo
  `usb://Brother/DCP-1602?serial=XXXXXXXXXX`. La parte `serial=` es única de
  cada unidad: por eso el proyecto la detecta en runtime y no la hardcodea.
- **Acción correctiva:** si el paso 1 pasó pero aquí no aparece nada,
  reinicia CUPS (`sudo systemctl restart cups`) y repite. Revisa también que
  el backend usb de CUPS existe: `ls /usr/lib/cups/backend/usb`.

## Paso 4 — Existe un PPD de brlaser para el modelo

```bash
lpinfo -m | grep -i brlaser
```

- **Resultado esperado:** una línea que mencione `DCP-1600 series` (la
  DCP-1602 pertenece a esa serie; el `brlaser.drv.in` del driver declara
  `MDL:DCP-1600 series` con `CMD:PJL,XL2HB`).
- **Acción correctiva:**
  - Si no hay ninguna línea: reinstala el driver
    (`sudo apt-get install --reinstall printer-driver-brlaser`).
  - Si hay líneas brlaser pero ninguna `DCP-1600` (versión antigua del
    driver): usa la alternativa `DCP-1510`, que el script
    `20-add-queue.sh` selecciona solo, o fuerza una concreta:
    `sudo PPD_OVERRIDE='drv:///brlaser.drv/br1510.ppd' ./scripts/20-add-queue.sh`.

## Paso 5 — La cola existe, está habilitada y compartida

```bash
lpstat -p Brother_DCP1602
lpstat -a Brother_DCP1602
lpstat -v Brother_DCP1602
cupsctl | grep _share_printers
```

- **Resultado esperado:** la cola aparece como *idle/enabled*, *accepting
  requests*, con la URI USB del paso 3, y `_share_printers=1`.
- **Acción correctiva:** `sudo ./scripts/20-add-queue.sh` (idempotente). Si
  está en pausa: `sudo cupsenable Brother_DCP1602`; si rechaza trabajos:
  `sudo cupsaccept Brother_DCP1602`.

## Paso 6 — Validación del driver: impresión local desde la Pi

Este paso valida brlaser/XL2HB **sin** involucrar mDNS ni iOS.

```bash
lp -d Brother_DCP1602 /usr/share/cups/data/default-testpage.pdf
lpstat -W not-completed
```

- **Resultado esperado:** el LED de la impresora parpadea en pocos segundos y
  sale **una hoja física legible** con la página de prueba de CUPS.
- **Acción correctiva:**
  - No sale nada y el job desaparece de la cola: driver/PPD incorrecto (la
    impresora descarta el flujo XL2HB mal formado). Revisa el paso 4 y prueba
    el PPD alternativo.
  - Sale papel con caracteres basura: mismo diagnóstico, PPD equivocado.
  - El job se queda en la cola: mira el motivo con `lpstat -l -o` y el log
    `journalctl -u cups --since '-10 min'`. Errores del tipo
    `Filter failed` suelen indicar que falta ghostscript o cups-filters.

**No sigas al paso 7 hasta que este paso produzca papel legible**: si el
driver no funciona en local, AirPrint tampoco funcionará y estarás depurando
dos problemas a la vez.

## Paso 7 — Anuncio mDNS completo (los dos requisitos AirPrint)

```bash
avahi-browse -rt _universal._sub._ipp._tcp | grep -B3 -A6 Brother_DCP1602
avahi-browse -rt _ipp._tcp | grep -o 'URF=[^"]*'
```

- **Resultado esperado:** la cola aparece bajo el subtipo
  `_universal._sub._ipp._tcp` **y** su TXT incluye un `URF=` **no vacío**
  (este proyecto usa `URF=DM3`). Ambos son obligatorios: si falta cualquiera,
  iOS no lista la impresora **y no muestra ningún error**.
- **Acción correctiva:** ejecuta `sudo ./scripts/30-airprint.sh`. Inspecciona
  primero qué publica CUPS solo: en Debian/Raspberry Pi OS el CUPS parcheado
  ya publica el URF si la cola está compartida; el archivo manual
  `/etc/avahi/services/airprint-Brother_DCP1602.service` únicamente debe
  existir si el anuncio de CUPS está incompleto.

## Paso 8 — Prueba real desde iOS

En un iPhone/iPad de la misma red: cualquier app → **Compartir → Imprimir →
Seleccionar impresora**.

- **Resultado esperado:** aparece `Brother_DCP1602` (o el `QUEUE_NAME`
  elegido) **una sola vez**, y al imprimir sale la hoja física.
- **Acción correctiva:**
  - No aparece: repite el paso 7 desde otro terminal y comprueba que el
    iPhone está en la misma red/VLAN (el mDNS no cruza redes sin un
    reflector). Reinicia avahi: `sudo systemctl restart avahi-daemon`.
  - Aparece duplicada (típico en macOS): hay dos anuncios (CUPS + archivo
    manual). Elimina el manual:
    `sudo rm /etc/avahi/services/airprint-Brother_DCP1602.service && sudo systemctl reload-or-restart avahi-daemon`.
  - Aparece pero falla al imprimir: revisa `journalctl -u cups -f` mientras
    lanzas el trabajo desde iOS.

## Paso 9 — Verificación automatizada

```bash
sudo ./scripts/90-verify.sh
```

- **Resultado esperado:** todas las comprobaciones en verde y, tras la página
  de prueba, respondes **s** a la pregunta de confirmación visual.
- **Acción correctiva:** el propio script indica el paso de este runbook al
  que volver según qué comprobación falle.

---

## Tabla de troubleshooting

| Síntoma | Causa probable | Acción |
|---|---|---|
| iOS no lista la impresora (sin error) | Falta `URF` no vacío o el subtipo `_universal._sub._ipp._tcp` | Paso 7; `sudo ./scripts/30-airprint.sh` |
| Impresora duplicada en macOS | Anuncio de CUPS **y** archivo manual de Avahi a la vez | Borrar `/etc/avahi/services/airprint-*.service` y recargar avahi |
| Job "completed" pero no sale papel | PPD/driver equivocado (flujo XL2HB inválido descartado) | Paso 4 y 6; probar PPD `DCP-1510` o `PPD_OVERRIDE` |
| Sale papel con caracteres basura | PPD equivocado | Paso 4; cambiar de PPD |
| Job atascado en la cola | Impresora apagada/desconectada, o cola en pausa | Paso 1; `sudo cupsenable` + `sudo cupsaccept` |
| `Filter failed` en CUPS | Falta ghostscript o cups-filters | `sudo ./scripts/10-install-packages.sh` |
| `lpinfo -v` no muestra `usb://Brother` | Cable/alimentación, o CUPS arrancó antes de conectarla | Paso 1 y 3; `sudo systemctl restart cups` |
| Funcionaba y dejó de aparecer en iOS | avahi-daemon caído o cambio de red/VLAN | `systemctl status avahi-daemon`; misma red que el iPhone |
| `lpadmin: Unable to connect` | CUPS parado | `sudo systemctl start cups` |
| Quiere escanear | **Fuera de alcance**: requiere `brscan` propietario, no verificado en ARM | Sin acción en este proyecto (limitación conocida) |

## Rollback

Deshace todo lo que hace el proyecto, en orden inverso:

```bash
# 1. Quitar el anuncio manual de Avahi (si existe)
sudo rm -f /etc/avahi/services/airprint-Brother_DCP1602.service
sudo systemctl reload-or-restart avahi-daemon

# 2. Eliminar la cola CUPS
sudo lpadmin -x Brother_DCP1602

# 3. Dejar de compartir impresoras (si no hay otras colas compartidas)
sudo cupsctl --no-share-printers

# 4. (Opcional) Desinstalar los paquetes
sudo apt-get purge -y cups cups-filters printer-driver-brlaser avahi-daemon avahi-utils ghostscript
sudo apt-get autoremove -y

# 5. Borrar el estado del proyecto
sudo rm -f /var/lib/pi-airprint-brother/state
sudo rmdir --ignore-fail-on-non-empty /var/lib/pi-airprint-brother
```

Si usaste un `QUEUE_NAME` distinto, sustitúyelo en los pasos 1 y 2.
