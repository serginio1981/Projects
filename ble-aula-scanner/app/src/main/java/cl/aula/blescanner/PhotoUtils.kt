package cl.aula.blescanner

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import java.io.File
import java.io.IOException

/** Un pin sobre la foto. x,y van de 0 a 1 respecto del ancho/alto de la imagen. */
data class MapPin(
    val address: String,
    val x: Float,
    val y: Float,
    /** true = posición estimada por el barrido; false = colocada a mano. */
    val auto: Boolean,
    /** Mitad del ancho de la franja de incertidumbre, como fracción del ancho. */
    val bandHalfWidth: Float = 0f,
)

/** Dispositivo con rumbo estimado que cae fuera del encuadre de la foto. */
data class OutOfFrame(val address: String, val deltaDeg: Float)

/** Texto y color ya resueltos para dibujar un pin en la imagen exportada. */
data class PinLabel(val number: Int, val pin: MapPin, val text: String, val color: Int)

object PhotoUtils {

    /** Color ARGB según intensidad: más cálido = más cerca. */
    fun colorFor(rssi: Int): Int = when {
        rssi >= -55 -> 0xFFD32F2F.toInt()
        rssi >= -70 -> 0xFFF57C00.toInt()
        rssi >= -85 -> 0xFFB8860B.toInt()
        else -> 0xFF1976D2.toInt()
    }

    /** Carga la foto reducida (lado mayor <= maxSide) y la endereza según EXIF. */
    fun loadScaled(file: File, maxSide: Int): Bitmap? {
        if (!file.exists() || file.length() == 0L) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > maxSide) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = BitmapFactory.decodeFile(file.absolutePath, options) ?: return null

        val degrees = try {
            when (
                ExifInterface(file.absolutePath).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
                )
            ) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: IOException) {
            0f
        }
        if (degrees == 0f) return bitmap
        val matrix = Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    /** Dibuja la foto con franjas, pines numerados y una leyenda debajo. */
    fun renderAnnotated(photo: Bitmap, labels: List<PinLabel>): Bitmap {
        val u = photo.width / 100f
        val lineHeight = 4.2f * u
        val legendHeight = (lineHeight * (labels.size + 2) + 2f * u).toInt()
        val out = Bitmap.createBitmap(
            photo.width, photo.height + legendHeight, Bitmap.Config.ARGB_8888
        )
        val canvas = Canvas(out)
        canvas.drawColor(Color.WHITE)
        canvas.drawBitmap(photo, 0f, 0f, null)

        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 0.5f * u
            color = Color.WHITE
        }
        val number = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 2.6f * u
            textAlign = Paint.Align.CENTER
            isFakeBoldText = true
        }
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK
            textSize = 2.5f * u
        }

        for (label in labels) {
            val pin = label.pin
            if (pin.auto && pin.bandHalfWidth > 0f) {
                fill.color = label.color
                fill.alpha = 56
                val left = (pin.x - pin.bandHalfWidth).coerceAtLeast(0f) * photo.width
                val right = (pin.x + pin.bandHalfWidth).coerceAtMost(1f) * photo.width
                canvas.drawRect(left, 0f, right, photo.height.toFloat(), fill)
            }
        }
        val radius = 2.6f * u
        for (label in labels) {
            val cx = label.pin.x * photo.width
            val cy = label.pin.y * photo.height
            fill.color = label.color
            fill.alpha = 255
            canvas.drawCircle(cx, cy, radius, fill)
            canvas.drawCircle(cx, cy, radius, stroke)
            canvas.drawText(label.number.toString(), cx, cy + 0.9f * u, number)
        }

        var y = photo.height + lineHeight
        for (label in labels) {
            fill.color = label.color
            fill.alpha = 255
            canvas.drawCircle(3f * u, y - 0.9f * u, 1.3f * u, fill)
            canvas.drawText("${label.number}. ${label.text}", 6f * u, y, text)
            y += lineHeight
        }
        text.color = Color.DKGRAY
        text.textSize = 2.1f * u
        canvas.drawText(
            "Indicio, no prueba. \"Estimado\" = dirección aproximada (±30°) por barrido de RSSI.",
            2f * u, y + 0.5f * u, text
        )
        return out
    }
}
