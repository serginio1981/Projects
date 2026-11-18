# Detector BLE Aula

App Android (Kotlin + Jetpack Compose) que **detecta la presencia de dispositivos
Bluetooth Low Energy (BLE) que se anuncian** cerca de la tablet, con su nombre
(si lo exponen), dirección MAC e intensidad de señal (RSSI) como indicio de
cercanía.

Pensada como **ayuda de supervisión en exámenes**: ver si aparece un dispositivo
BLE junto a un alumno. Es un **indicio para investigar, no una prueba**.

---

## Qué hace y qué NO hace

**Hace:**
- Escaneo BLE pasivo: lista dispositivos que emiten *advertising*.
- Muestra nombre, MAC, RSSI y barras de señal; ordena por señal más fuerte.

**NO hace (y por qué):**
- **No intercepta ni transcribe audio Bluetooth.** El enlace Bluetooth está
  cifrado y el sistema operativo no expone ese tráfico a las apps. Interceptar
  comunicaciones ajenas además es, con alta probabilidad, ilegal.
- **No capta por micrófono lo que se le "sopla" al alumno.** Un auricular
  intraauricular acopla el sonido dentro del oído; la fuga acústica al aire es
  diminuta y queda bajo el piso de ruido. Más ganancia o cancelación de ruido
  **no recupera** una señal que no llegó al micrófono con nivel suficiente.

### Limitación clave de la detección BLE
Un auricular/dispositivo **ya emparejado y conectado** a menudo **deja de
anunciarse** y entonces **no aparece** en el escaneo. La detección pasiva ve lo
que se anuncia, no todo lo encendido en la sala. Trátala como indicio parcial.

---

## Requisitos
- Android Studio (Hedgehog/Iguana o posterior recomendado).
- Tablet/teléfono con Android 8.0+ (minSdk 26) y hardware BLE.
- JDK 17 (lo trae Android Studio).

## Compilar e instalar
1. Abre la carpeta `ble-aula-scanner/` en Android Studio.
2. Deja que sincronice Gradle. Si pide **crear el Gradle wrapper**, acéptalo
   (o desde terminal, con Gradle instalado: `gradle wrapper`).
3. Conecta la tablet con **depuración USB** activada.
4. Pulsa **Run ▶**. O por terminal: `./gradlew installDebug`.

## Uso
1. Abre la app y pulsa **Escanear**.
2. Acepta los permisos que pida:
   - Android 12+: *Dispositivos cercanos* (BLUETOOTH_SCAN / BLUETOOTH_CONNECT).
   - Android 8–11: *Ubicación* (el sistema la **exige** para escanear BLE; la app
     no la guarda ni la usa).
3. Verás la lista en vivo, ordenada por intensidad de señal.

---

## Versiones
Combinación usada (estable y conocida): AGP 8.2.2 · Kotlin 1.9.22 ·
Compose Compiler 1.5.8 · Compose BOM 2024.02.00. Si Android Studio sugiere
actualizar algo al abrir, sigue su recomendación.

> Nota honesta: no verifiqué estas versiones contra el entorno exacto de tu
> máquina. Si una no resuelve, Android Studio te indicará la combinación
> compatible; conviene confirmarlas en la documentación oficial de AGP/Compose.

---

## Aviso legal y de privacidad
Detectar la presencia de señales de radio en tu propio espacio es una cosa;
**interceptar, grabar o transcribir comunicaciones o la voz de una persona es
otra** y suele estar regulado. Antes de usar esto como parte de un proceso
disciplinario, valida con el área legal de tu institución el reglamento interno
y la normativa de tu jurisdicción (protección de datos, grabación de personas,
debido proceso). Esta app solo lista dispositivos que se anuncian públicamente;
no capta audio ni contenido.
