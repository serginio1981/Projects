package cl.aula.blescanner

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Rumbo (0–360°) hacia el que apunta la cámara trasera con la tablet sostenida
 * en vertical. Usa el vector de rotación sin magnetómetro si existe (rumbo
 * relativo y estable en interiores); si no, el vector de rotación normal.
 * Solo se necesita un rumbo coherente entre el barrido y la foto, no el norte real.
 */
class HeadingSensor(context: Context) : SensorEventListener {

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val sensor: Sensor? =
        sensorManager?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?: sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    private val _azimuth = MutableStateFlow<Float?>(null)
    val azimuth: StateFlow<Float?> = _azimuth

    val isAvailable: Boolean get() = sensor != null

    private val rotation = FloatArray(9)
    private val remapped = FloatArray(9)
    private val orientation = FloatArray(3)
    private var running = false

    fun start() {
        val s = sensor ?: return
        if (running) return
        sensorManager?.registerListener(this, s, SensorManager.SENSOR_DELAY_UI)
        running = true
    }

    fun stop() {
        if (!running) return
        sensorManager?.unregisterListener(this)
        running = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        // Algunos equipos entregan 5 valores; la matriz solo admite hasta 4.
        val values = if (event.values.size > 4) event.values.copyOf(4) else event.values
        SensorManager.getRotationMatrixFromVector(rotation, values)
        // Tablet en vertical: el rumbo es el de la cámara trasera.
        SensorManager.remapCoordinateSystem(
            rotation, SensorManager.AXIS_X, SensorManager.AXIS_Z, remapped
        )
        SensorManager.getOrientation(remapped, orientation)
        _azimuth.value =
            BearingEstimator.normalize(Math.toDegrees(orientation[0].toDouble()).toFloat())
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
}
