# CLIENTES — cómo escanear desde cada sistema operativo

En todos los casos, el dispositivo debe estar en la **misma red** que la
Raspberry Pi. Sustituye `raspberrypi.local` por el hostname real de tu Pi si
lo cambiaste (compruébalo con `hostname` en la Pi).

---

## iOS (iPhone / iPad)

**Importante:** iOS **no tiene cliente de escáner de red**. El botón
"Escanear documentos" de Notas y de Archivos usa la **cámara** del teléfono,
no busca escáneres en la LAN, y no existe un equivalente de AirPrint para
escanear. La vía es la interfaz web de scanservjs, instalada como PWA:

1. Abre **Safari** (tiene que ser Safari, no Chrome) y entra en
   `http://raspberrypi.local:8080`.
2. Se abre la interfaz de scanservjs. Prueba un escaneo: coloca un papel en
   el cristal, pulsa **Scan** y descarga el resultado (PDF o imagen).
3. Para dejarla como "app": botón **Compartir** (el cuadrado con flecha) →
   **Añadir a pantalla de inicio** → nómbrala (p. ej. "Escáner").
4. A partir de ahí, escaneas tocando ese icono como si fuera una app nativa.
   Los archivos quedan en **Archivos** (carpeta Descargas) al descargarlos.

## Windows 10 / 11

Windows trae cliente eSCL integrado y descubre el escáner por mDNS:

1. **Configuración → Bluetooth y dispositivos → Impresoras y escáneres**
   (en Windows 10: **Dispositivos → Impresoras y escáneres**).
2. Pulsa **Agregar dispositivo** y espera: debe aparecer el escáner publicado
   por AirSane (nombre tipo "Brother ...").
3. Agrégalo y escanea con la app **Escáner de Windows** (si no la tienes,
   está gratis en la Microsoft Store como "Windows Scan").
4. Alternativa sin instalar nada: abre `http://raspberrypi.local:8090` en el
   navegador (interfaz web de AirSane) o `http://raspberrypi.local:8080`
   (scanservjs).

## Android

1. Instala **Mopria Scan** desde Google Play (gratuita, de Mopria Alliance;
   habla eSCL).
2. Ábrela con el teléfono en la misma WiFi: detecta sola el escáner
   anunciado por AirSane.
3. Selecciónalo, elige resolución/color y pulsa escanear; el resultado queda
   en el almacenamiento del teléfono.
4. Alternativa: el navegador con `http://raspberrypi.local:8080`
   (scanservjs), que también funciona como en iOS.

## macOS

macOS habla AirScan/eSCL de serie:

1. Abre **Captura de Imagen** (Image Capture, en Aplicaciones): el escáner
   debe aparecer en la barra lateral, sección **Compartidos**.
2. Alternativa: **Ajustes del Sistema → Impresoras y escáneres → Añadir**;
   el escáner aparece descubierto por Bonjour.
3. Escanea desde Captura de Imagen, Vista Previa (menú Archivo → Importar
   desde escáner) o cualquier app que use ImageKit.
4. Alternativa web: `http://raspberrypi.local:8080` (scanservjs).

---

## Si dos personas escanean a la vez

El escáner físico admite **un consumidor a la vez**. Si alguien lanza un
escaneo mientras otro está en curso (da igual desde qué cliente), el segundo
recibirá un error de dispositivo ocupado. No es una avería: espera a que
termine el primero y reintenta.
