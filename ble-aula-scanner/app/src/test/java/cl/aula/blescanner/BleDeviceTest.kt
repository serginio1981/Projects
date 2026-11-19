package cl.aula.blescanner

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pruebas unitarias de la lógica pura de BleDevice (corren en la JVM, sin
 * dispositivo Android ni Bluetooth). Verifican los umbrales de RSSI y el
 * nombre mostrado, que son determinísticos.
 */
class BleDeviceTest {

    private fun device(rssi: Int, name: String? = "x") =
        BleDevice(address = "AA:BB:CC:DD:EE:FF", name = name, rssi = rssi, firstSeen = 0L, lastSeen = 0L)

    @Test
    fun proximidad_en_los_limites_de_rssi() {
        // >= -55 -> MUY_CERCA
        assertEquals(Proximity.MUY_CERCA, device(-30).proximity)
        assertEquals(Proximity.MUY_CERCA, device(-55).proximity)
        // -56 .. -70 -> CERCA
        assertEquals(Proximity.CERCA, device(-56).proximity)
        assertEquals(Proximity.CERCA, device(-70).proximity)
        // -71 .. -85 -> MEDIO
        assertEquals(Proximity.MEDIO, device(-71).proximity)
        assertEquals(Proximity.MEDIO, device(-85).proximity)
        // < -85 -> LEJOS
        assertEquals(Proximity.LEJOS, device(-86).proximity)
        assertEquals(Proximity.LEJOS, device(-100).proximity)
    }

    @Test
    fun displayName_usa_placeholder_cuando_no_hay_nombre() {
        assertEquals("(sin nombre)", device(-60, name = null).displayName)
        assertEquals("(sin nombre)", device(-60, name = "").displayName)
        assertEquals("(sin nombre)", device(-60, name = "   ").displayName)
    }

    @Test
    fun displayName_conserva_el_nombre_real() {
        assertEquals("AirPods de Juan", device(-60, name = "AirPods de Juan").displayName)
    }
}
