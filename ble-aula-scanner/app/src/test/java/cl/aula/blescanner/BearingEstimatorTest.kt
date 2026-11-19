package cl.aula.blescanner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.math.cos

class BearingEstimatorTest {

    /** Barrido sintético: señal máxima al mirar hacia [peakDeg]. */
    private fun sweep(peakDeg: Double, amplitudeDb: Double): List<SweepSample> =
        (0 until 360 step 5).map { az ->
            val rssi = -75.0 + amplitudeDb * cos(Math.toRadians(az - peakDeg))
            SweepSample(az.toFloat(), Math.round(rssi).toInt())
        }

    @Test
    fun estima_el_rumbo_del_maximo() {
        val e = BearingEstimator.estimate(sweep(90.0, 10.0))
        assertNotNull(e)
        assertEquals(90f, e!!.bearingDeg, 10f)
    }

    @Test
    fun estima_bien_cerca_del_cruce_por_cero() {
        val e = BearingEstimator.estimate(sweep(350.0, 10.0))
        assertNotNull(e)
        assertEquals(0f, BearingEstimator.angleDiff(e!!.bearingDeg, 350f), 10f)
    }

    @Test
    fun senal_pareja_no_da_estimacion() {
        assertNull(BearingEstimator.estimate(sweep(90.0, 1.0)))
    }

    @Test
    fun vuelta_incompleta_no_da_estimacion() {
        val partial = sweep(90.0, 10.0).filter { it.azimuthDeg < 60f }
        assertNull(BearingEstimator.estimate(partial))
    }

    @Test
    fun diferencia_de_angulos_con_signo() {
        assertEquals(20f, BearingEstimator.angleDiff(10f, 350f), 0.001f)
        assertEquals(-20f, BearingEstimator.angleDiff(350f, 10f), 0.001f)
    }

    @Test
    fun proyeccion_sobre_la_foto() {
        assertEquals(0.5f, BearingEstimator.photoX(90f, 90f, 60f)!!, 0.001f)
        assertEquals(0.5f + 10f / 60f, BearingEstimator.photoX(100f, 90f, 60f)!!, 0.001f)
        assertEquals(0.5f - 15f / 60f, BearingEstimator.photoX(355f, 10f, 60f)!!, 0.001f)
        assertNull(BearingEstimator.photoX(200f, 90f, 60f))
    }
}
