package cl.aula.blescanner

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/** Una muestra del barrido: hacia dónde apuntaba la tablet y qué RSSI se recibió. */
data class SweepSample(val azimuthDeg: Float, val rssi: Int)

/**
 * Estima el rumbo aproximado de un emisor BLE a partir de un barrido giratorio.
 *
 * Principio: al girar con la tablet pegada al cuerpo, el cuerpo atenúa la señal
 * que llega desde atrás, así que el RSSI tiende a ser mayor cuando se mira hacia
 * el emisor. Es una estimación GRUESA (del orden de ±30° o peor, y sensible a
 * rebotes en paredes): sirve como indicio de dirección, no como posición exacta.
 */
object BearingEstimator {
    const val SECTOR_DEG = 20
    const val SECTORS = 360 / SECTOR_DEG
    /** Sectores mínimos con muestras para aceptar una estimación. */
    const val MIN_SECTORS = 6
    /** Diferencia mínima (dB) entre la mejor y la peor dirección. */
    const val MIN_CONTRAST_DB = 6f
    /** Incertidumbre que se muestra al usuario (± grados). */
    const val UNCERTAINTY_DEG = 30f

    data class Estimate(val bearingDeg: Float, val contrastDb: Float, val coveredSectors: Int)

    fun normalize(deg: Float): Float {
        val m = deg % 360f
        return if (m < 0f) m + 360f else m
    }

    fun sectorOf(azimuthDeg: Float): Int =
        (normalize(azimuthDeg) / SECTOR_DEG).toInt().coerceIn(0, SECTORS - 1)

    /** Diferencia con signo a − b en (−180, 180]. Positivo = a está a la derecha de b. */
    fun angleDiff(a: Float, b: Float): Float {
        var d = normalize(a - b)
        if (d > 180f) d -= 360f
        return d
    }

    fun estimate(samples: List<SweepSample>): Estimate? {
        if (samples.isEmpty()) return null
        val sum = DoubleArray(SECTORS)
        val n = IntArray(SECTORS)
        for (s in samples) {
            val i = sectorOf(s.azimuthDeg)
            sum[i] += s.rssi.toDouble()
            n[i]++
        }
        val covered = (0 until SECTORS).filter { n[it] > 0 }
        if (covered.size < MIN_SECTORS) return null

        val mean = DoubleArray(SECTORS) { if (n[it] > 0) sum[it] / n[it] else 0.0 }
        // Suavizado circular con los sectores vecinos que tengan muestras.
        val smooth = DoubleArray(SECTORS) { i ->
            var acc = mean[i] * 2.0
            var w = 2.0
            for (k in intArrayOf(i - 1, i + 1)) {
                val j = (k + SECTORS) % SECTORS
                if (n[j] > 0) {
                    acc += mean[j]
                    w += 1.0
                }
            }
            acc / w
        }

        val best = covered.maxByOrNull { smooth[it] } ?: return null
        val minValue = covered.minOf { smooth[it] }
        val contrast = (smooth[best] - minValue).toFloat()
        if (contrast < MIN_CONTRAST_DB) return null

        // Media circular ponderada del mejor sector y sus vecinos.
        var sx = 0.0
        var sy = 0.0
        for (k in -1..1) {
            val j = (best + k + SECTORS) % SECTORS
            if (n[j] == 0) continue
            val weight = smooth[j] - minValue + 1.0
            val center = Math.toRadians(j * SECTOR_DEG + SECTOR_DEG / 2.0)
            sx += weight * cos(center)
            sy += weight * sin(center)
        }
        val bearing = normalize(Math.toDegrees(atan2(sy, sx)).toFloat())
        return Estimate(bearing, contrast, covered.size)
    }

    /**
     * Posición horizontal (0 = borde izquierdo, 1 = borde derecho) de un rumbo
     * dentro de una foto tomada mirando hacia [photoAzimuthDeg] con un campo de
     * visión horizontal [fovDeg]. Devuelve null si queda fuera del encuadre.
     */
    fun photoX(bearingDeg: Float, photoAzimuthDeg: Float, fovDeg: Float): Float? {
        val d = angleDiff(bearingDeg, photoAzimuthDeg)
        if (abs(d) > fovDeg / 2f) return null
        return 0.5f + d / fovDeg
    }
}
