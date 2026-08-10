# RUNBOOK — Validación manual de pi-scan-brother

Validación paso a paso de la cadena
**cliente → (mDNS/eSCL o web) → AirSane/scanservjs → SANE → backend brother → DCP-1602 (USB)**.

Cada paso indica el **resultado esperado** y la **acción correctiva**.

> Criterio de éxito del proyecto: **un archivo escaneado que se abre y se ve
> legible**. Que `scanimage -L` liste el dispositivo NO es éxito: solo prueba
> que el backend carga.

---

## Paso 1 — El escáner aparece en el bus USB

```bash
lsusb -d 04f9:
```

- **Resultado esperado:** una línea `Bus ... ID 04f9:xxxx Brother
  Industries, Ltd`. Apunta el product ID (`xxxx`): varía por modelo y es el
  que usan la regla udev y el diagnóstico.
- **Acción correctiva:** alimentación, cable, otro puerto USB de la Pi.
  `dmesg | tail -20` tras reconectar: si el kernel no registra nada, el
  problema es físico.

## Paso 2 — El backend brother está instalado y registrado

```bash
grep -n '^brother$' /etc/sane.d/dll.conf
find /usr /etc /opt -name 'Brsane.ini' 2>/dev/null
```

- **Resultado esperado:** la línea `brother` aparece exactamente una vez en
  `dll.conf`, y existe un `Brsane.ini` instalado.
- **Acción correctiva:** ejecuta `sudo ./scripts/10-driver.sh`. Si la línea
  aparece duplicada (instalación manual previa), deja solo una.

## Paso 3 — Perfil del modelo en Brsane.ini (incertidumbre conocida)

```bash
grep -i -e 'DCP-1602' -e 'DCP-1510' "$(find /usr /etc /opt -name 'Brsane.ini' 2>/dev/null | head -n1)"
```

- **Resultado esperado (ideal):** aparece `DCP-1602` → compatibilidad
  confirmada por el backend.
- **Resultado aceptable:** solo aparece `DCP-1510` (mismo motor, referencia
  `04f9:02d0`) → la compatibilidad es **probable, no confirmada**. El paso 6
  (escaneo real) es el que decide.
- **Acción correctiva:** si no aparece ninguno, el backend quizá no soporta
  este motor; revisa los issues del repo `dmikushin/brscan` antes de seguir.

## Paso 4 — Regla udev aplicada (permisos sin root)

```bash
cat /etc/udev/rules.d/60-brother-scanner.rules
```

- **Resultado esperado:** una regla con `ATTRS{idVendor}=="04f9"` y el
  `idProduct` igual al detectado en el paso 1. Tras instalarla hay que
  **reconectar el USB** (o apagar/encender la impresora) para que aplique.
- **Acción correctiva:** `sudo ./scripts/10-driver.sh` la regenera con el
  product ID actual. Después: `sudo udevadm control --reload-rules &&
  sudo udevadm trigger` y reconectar el dispositivo.

## Paso 5 — SANE lista el dispositivo (comprobación, NO éxito)

```bash
scanimage -L
```

- **Resultado esperado:** `device 'brother...:bus...;dev...' is a Brother ...`.
- **Acción correctiva:**
  - Nada listado como usuario normal pero sí con `sudo scanimage -L`:
    permisos → paso 4, y comprueba tus grupos (`groups`; debe incluir `lp` o
    `scanner`; cierra sesión y vuelve a entrar tras añadirte).
  - Nada listado ni con sudo: paso 2 (backend) y paso 1 (USB). Reinicia
    también por si otra pila retiene el dispositivo (ver "Convivencia con
    CUPS" abajo).

## Paso 6 — ESCANEO REAL legible (el criterio de éxito)

```bash
sudo ./scripts/20-verify-sane.sh
```

- **Resultado esperado:** el script escanea una página real a
  `/var/lib/pi-scan-brother/test-scans/`, tú abres el archivo y **se ve
  completa y legible**, y respondes `s` a la confirmación visual.
- **Acción correctiva:**
  - Imagen negra, vacía, con franjas o cortada: perfil de modelo incorrecto
    (paso 3). Con perfil DCP-1510 "probable", esto es el síntoma de que no
    sirve para la DCP-1602: abre un issue en el repo del backend.
  - Error `Device busy`: otro proceso está usando el escáner (otro cliente,
    o la pila de impresión a mitad de trabajo). Espera y reintenta.
  - Error de E/S a mitad de escaneo: cable/alimentación USB (los hubs sin
    alimentación dan problemas).

**No sigas al paso 7 sin superar este paso**: si SANE no escanea en local,
los servidores de red solo añadirán capas al mismo fallo.

## Paso 7 — AirSane anuncia el servicio eSCL por mDNS

```bash
systemctl status avahi-daemon airsaned --no-pager
avahi-browse -rt _uscan._tcp
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8090/
```

- **Resultado esperado:** ambos servicios activos, un registro `_uscan._tcp`
  con el nombre del escáner, y un código HTTP (200) del puerto 8090.
- **Acción correctiva:**
  - `journalctl -u airsaned -n 50`. Un **"Bad State (-2)"** significa que
    avahi-daemon no está activo: `sudo systemctl enable --now avahi-daemon`
    y reinicia airsaned.
  - Sin anuncio mDNS pero airsaned vivo: reinicia avahi
    (`sudo systemctl restart avahi-daemon airsaned`).

## Paso 8 — scanservjs responde

```bash
systemctl status scanservjs --no-pager
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
```

- **Resultado esperado:** servicio activo y respuesta HTTP en el 8080.
- **Acción correctiva:** `journalctl -u scanservjs -n 50`. Si el fallo es de
  nodejs demasiado viejo (Raspberry Pi OS antiguo), actualiza nodejs según
  la documentación de scanservjs y reinstala.

## Paso 9 — Prueba desde cada cliente

Sigue [CLIENTES.md](CLIENTES.md) para iOS, Windows, Android y macOS.

- **Resultado esperado:** cada sistema descubre el escáner (o abre la web) y
  produce un archivo legible.
- **Acción correctiva:** si un cliente no descubre nada pero el paso 7 pasa,
  el problema está en la red (misma WiFi/VLAN; el mDNS no cruza redes sin un
  reflector).

## Paso 10 — Diagnóstico automatizado (en cualquier momento)

```bash
./scripts/90-verify.sh
```

Recorre los pasos 1-8 de forma automatizada y te ofrece lanzar el escaneo de
validación si aún no consta como superado.

---

## Convivencia con CUPS (impresión en la misma Pi)

La DCP-1602 es **un solo dispositivo USB multifunción**. Si en la misma Pi
corre CUPS para imprimir, ambas pilas hablan al mismo `04f9:xxxx`.
Normalmente coexisten porque el dispositivo expone interfaces USB separadas
(impresora y escáner), pero hay dos acaparadores conocidos:

1. **Módulo de kernel `usblp`**: se engancha a la interfaz de impresora.
   Diagnóstico: `lsmod | grep usblp` y `dmesg | grep usblp`. Si el escáner
   falla solo cuando se ha impreso antes, prueba `sudo modprobe -r usblp` y
   repite `scanimage -L`; si eso lo cura, valora ponerlo en lista negra
   (`/etc/modprobe.d/`) sabiendo que CUPS moderno imprime por libusb sin
   `usblp`. **No lo hagas por defecto**: hazlo solo si observaste el
   conflicto.
2. **Backend `usb` de CUPS**: mantiene el dispositivo abierto mientras hay
   un trabajo de impresión activo. Un escaneo lanzado en ese momento da
   `Device busy`; espera a que termine el trabajo.

Los puertos no chocan: CUPS usa el 631; este proyecto usa 8080 (scanservjs)
y 8090 (AirSane). `00-preflight.sh` comprueba los tres escenarios y avisa.

## Contención SANE entre AirSane y scanservjs

Ambos servidores usan el mismo dispositivo SANE, que admite **un consumidor a
la vez**. Ninguno lo mantiene abierto en reposo, así que conviven; pero dos
escaneos simultáneos no son posibles: el segundo cliente recibe un error de
dispositivo ocupado y debe reintentar. No existe un mecanismo de cola entre
ambos servidores (mitigación posible: usar solo uno, con `--skip-airsane` o
`--skip-scanservjs`, si la contención fuera un problema real en tu uso).

## Tabla de troubleshooting

| Síntoma | Causa probable | Acción |
|---|---|---|
| `lsusb -d 04f9:` vacío | Cable/alimentación/puerto | Paso 1 |
| `scanimage -L` vacío | Backend sin registrar, o udev sin aplicar | Pasos 2, 4 y 5 |
| `scanimage -L` funciona solo con sudo | Permisos udev/grupos | Paso 4 |
| Imagen negra/franjas/cortada | Perfil de modelo incorrecto (DCP-1510 "probable" no válido) | Pasos 3 y 6 |
| `Device busy` al escanear | Otro escaneo en curso, o CUPS imprimiendo | Contención / Convivencia con CUPS |
| airsaned con "Bad State (-2)" | avahi-daemon caído | Paso 7 |
| Windows/Android/macOS no descubren nada | Sin anuncio mDNS o red distinta | Pasos 7 y 9 |
| iOS "no encuentra el escáner" | iOS no tiene cliente de red: es lo esperado | Usar la PWA (CLIENTES.md) |
| Puerto 8080/8090 ocupado | Otro servicio previo | `ss -tlnp` y cambiar puerto/servicio |
| scanservjs no arranca | nodejs demasiado viejo | Paso 8 |
| El escáner falla tras imprimir | `usblp`/backend usb de CUPS acaparando | Convivencia con CUPS |

## Rollback completo

Deshace todo lo que instala el proyecto, en orden inverso:

```bash
# 1. Parar y deshabilitar los servidores
sudo systemctl disable --now scanservjs 2>/dev/null || true
sudo systemctl disable --now airsaned 2>/dev/null || true

# 2. Desinstalar scanservjs (se instaló como paquete .deb)
sudo apt-get purge -y scanservjs

# 3. Desinstalar AirSane (se instaló con cmake --install desde el código
#    fuente). El build genera un install_manifest.txt con cada archivo
#    instalado; si conservas el directorio de build:
#      sudo xargs rm -f < <ruta-al-build>/install_manifest.txt
#    Si no lo conservas, los artefactos quedan bajo /usr/local
#    (busca: airsaned, unidad systemd airsaned.service y /etc/default/airsane).
sudo rm -f /etc/default/airsane

# 4. Quitar la regla udev y recargar
sudo rm -f /etc/udev/rules.d/60-brother-scanner.rules
sudo udevadm control --reload-rules && sudo udevadm trigger

# 5. Revertir dll.conf (quita SOLO la línea exacta 'brother')
sudo sed -i '/^brother$/d' /etc/sane.d/dll.conf

# 6. Desinstalar el backend brscan
#    - Si se instaló desde el .deb del release:  sudo apt-get purge -y brscan
#      (comprueba el nombre real con: dpkg -l | grep -i brscan)
#    - Si se compiló: usa el install_manifest.txt de su build, como en el
#      paso 3.

# 7. Borrar el estado y los escaneos de prueba del proyecto
sudo rm -rf /var/lib/pi-scan-brother

# 8. (Opcional) Paquetes base que quizá ya no quieras
sudo apt-get purge -y sane-utils
sudo apt-get autoremove -y
```

**Nota:** no purgues `avahi-daemon` a ciegas: otros servicios (por ejemplo un
servidor de impresión AirPrint en la misma Pi) pueden depender de él.
