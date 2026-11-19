package cl.aula.blescanner

/**
 * Representa un dispositivo BLE detectado durante el escaneo.
 *
 * @param address  Dirección MAC (identificador estable dentro de una sesión).
 * @param name     Nombre anunciado, si está disponible (puede ser null).
 * @param rssi     Última intensidad de señal recibida, en dBm (más cercano a 0 = más cerca).
 * @param firstSeen  Momento (ms) en que se vio por primera vez.
 * @param lastSeen   Momento (ms) de la última vez que se vio.
 */
data class BleDevice(
    val address: String,
    val name: String?,
    val rssi: Int,
    val firstSeen: Long,
    val lastSeen: Long,
) {
    /** Etiqueta amigable para la UI. */
    val displayName: String
        get() = name?.takeIf { it.isNotBlank() } ?: "(sin nombre)"

    /**
     * Estimación GRUESA de cercanía a partir del RSSI. NO es una medida fiable
     * de distancia: el RSSI varía mucho por obstáculos, orientación y modelo.
     * Solo sirve como indicio relativo (más barras = probablemente más cerca).
     */
    val proximity: Proximity
        get() = when {
            rssi >= -55 -> Proximity.MUY_CERCA
            rssi >= -70 -> Proximity.CERCA
            rssi >= -85 -> Proximity.MEDIO
            else -> Proximity.LEJOS
        }
}

enum class Proximity(val label: String) {
    MUY_CERCA("Muy cerca"),
    CERCA("Cerca"),
    MEDIO("Medio"),
    LEJOS("Lejos"),
}
