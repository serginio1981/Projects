package cl.aula.blescanner

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Modo radar: sigue la intensidad de UN dispositivo para localizarlo caminando.
 * La señal sube al acercarse y baja al alejarse.
 */
@Composable
fun RadarScreen(viewModel: ScanViewModel) {
    val devices by viewModel.devices.collectAsState()
    val selected by viewModel.selectedAddress.collectAsState()
    val history by viewModel.history.collectAsState()
    val scanning by viewModel.isScanning.collectAsState()
    val device = devices.firstOrNull { it.address == selected }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (!scanning) ScanStoppedHint(viewModel)

        if (device == null) {
            Text("Elige el dispositivo que quieres localizar", style = MaterialTheme.typography.titleMedium)
            Text(
                "Luego camina despacio por la sala: la señal sube cuando te acercas.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (devices.isEmpty()) {
                Text("Todavía no hay dispositivos detectados.", style = MaterialTheme.typography.bodyMedium)
            }
            devices.forEach { d ->
                Card(
                    Modifier
                        .fillMaxWidth()
                        .clickable { viewModel.select(d.address) }
                ) {
                    Column(Modifier.padding(12.dp)) {
                        Text(d.displayName, fontWeight = FontWeight.SemiBold)
                        Text(
                            "${d.address}  ·  ${d.rssi} dBm",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace
                        )
                    }
                }
            }
        } else {
            val recent = history.takeLast(5)
            val level = if (recent.isEmpty()) device.rssi else recent.sum() / recent.size
            val color = Color(PhotoUtils.colorFor(level))
            // -100 dBm = vacío, -40 dBm = lleno.
            val fraction = ((level + 100) / 60f).coerceIn(0f, 1f)

            Text(device.displayName, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(device.address, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)

            Text("$level dBm", fontSize = 56.sp, fontWeight = FontWeight.Bold, color = color)
            Text(trendText(history), style = MaterialTheme.typography.titleMedium)

            Box(
                Modifier
                    .fillMaxWidth()
                    .height(28.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
            ) {
                Box(
                    Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(fraction)
                        .background(color)
                )
            }

            Text("Últimas lecturas", style = MaterialTheme.typography.labelLarge)
            Sparkline(history, color)

            Text(
                "La intensidad varía con obstáculos y con tu propio cuerpo. Guíate por la tendencia, no por una lectura suelta.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(4.dp))
            OutlinedButton(onClick = { viewModel.select(null) }) { Text("Cambiar dispositivo") }
        }
    }
}

private fun trendText(history: List<Int>): String {
    if (history.size < 8) return "Reuniendo lecturas…"
    val recent = history.takeLast(4).average()
    val previous = history.takeLast(8).take(4).average()
    val diff = recent - previous
    return when {
        diff >= 3.0 -> "▲ Te estás acercando"
        diff <= -3.0 -> "▼ Te estás alejando"
        else -> "● Señal estable"
    }
}

@Composable
private fun Sparkline(values: List<Int>, color: Color) {
    val background = MaterialTheme.colorScheme.surfaceVariant
    Canvas(
        Modifier
            .fillMaxWidth()
            .height(90.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(background)
    ) {
        if (values.size < 2) return@Canvas
        val stepX = size.width / (ScanViewModel.HISTORY_MAX - 1)
        fun y(v: Int): Float {
            val f = ((v + 100) / 60f).coerceIn(0f, 1f)
            return size.height * (1f - f)
        }
        for (i in 1 until values.size) {
            drawLine(
                color = color,
                start = Offset((i - 1) * stepX, y(values[i - 1])),
                end = Offset(i * stepX, y(values[i])),
                strokeWidth = 4f
            )
        }
    }
}
