package cl.aula.blescanner

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Mapa sobre foto:
 *  1) Barrido giratorio -> dirección estimada de cada dispositivo.
 *  2) Foto del aula -> los estimados se proyectan como franja vertical.
 *  3) Cualquier pin se puede colocar o corregir a mano tocando la foto.
 */
@Composable
fun MapScreen(viewModel: ScanViewModel) {
    val context = LocalContext.current
    val devices by viewModel.devices.collectAsState()
    val scanning by viewModel.isScanning.collectAsState()
    val azimuth by viewModel.azimuth.collectAsState()
    val sweepActive by viewModel.sweepActive.collectAsState()
    val coverage by viewModel.sweepCoverage.collectAsState()
    val sweepDone by viewModel.sweepDone.collectAsState()
    val estimates by viewModel.estimates.collectAsState()
    val photo by viewModel.photo.collectAsState()
    val pins by viewModel.pins.collectAsState()
    val outOfFrame by viewModel.outOfFrame.collectAsState()

    var placing by remember { mutableStateOf<String?>(null) }
    var message by remember { mutableStateOf<String?>(null) }

    DisposableEffect(Unit) {
        viewModel.startHeading()
        onDispose { viewModel.stopHeading() }
    }

    val camera = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicture()
    ) { ok -> viewModel.onPhotoResult(ok) }

    fun nameOf(address: String): String =
        devices.firstOrNull { it.address == address }?.displayName ?: address

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (!scanning) ScanStoppedHint(viewModel)

        // ---------------------------------------------------- Paso 1: barrido
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("1 · Barrido de dirección (opcional)", fontWeight = FontWeight.SemiBold)
                Text(
                    "Sostén la tablet en vertical pegada al pecho y gira despacio una vuelta completa " +
                        "(unos 40 segundos). Tu cuerpo atenúa la señal que viene de atrás; con eso se " +
                        "estima hacia dónde está cada dispositivo. Es aproximado: ±30° o peor.",
                    style = MaterialTheme.typography.bodySmall
                )
                if (!viewModel.hasHeadingSensor) {
                    Text(
                        "Esta tablet no tiene sensor de rotación: solo podrás colocar pines a mano.",
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall
                    )
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Button(onClick = {
                            if (sweepActive) viewModel.stopSweep() else viewModel.startSweep()
                        }) { Text(if (sweepActive) "Terminar barrido" else "Iniciar barrido") }
                        Text(
                            "  Rumbo: " + (azimuth?.roundToInt()?.toString()?.plus("°") ?: "—"),
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                    if (sweepActive) {
                        Text(
                            "Vuelta recorrida: $coverage de ${BearingEstimator.SECTORS} sectores",
                            style = MaterialTheme.typography.bodyMedium
                        )
                    } else if (sweepDone) {
                        Text(
                            if (estimates.isEmpty())
                                "Sin dirección clara para ningún dispositivo (señal muy pareja o vuelta incompleta). Coloca los pines a mano."
                            else "Dirección estimada para ${estimates.size} dispositivo(s).",
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                }
            }
        }

        // ------------------------------------------------------- Paso 2: foto
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("2 · Foto del entorno", fontWeight = FontWeight.SemiBold)
                Text(
                    "Apunta la tablet a la sala desde el mismo punto del barrido y pulsa el botón. " +
                        "Se guarda el rumbo de ese momento para proyectar las direcciones estimadas.",
                    style = MaterialTheme.typography.bodySmall
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = {
                        message = null
                        try {
                            camera.launch(viewModel.preparePhotoUri())
                        } catch (_: ActivityNotFoundException) {
                            message = "No se encontró una app de cámara en este equipo."
                        }
                    }) { Text(if (photo == null) "Tomar foto" else "Repetir foto") }
                    if (photo != null) {
                        OutlinedButton(onClick = {
                            val intent = viewModel.buildShareIntent()
                            if (intent != null) {
                                context.startActivity(Intent.createChooser(intent, "Guardar o compartir mapa"))
                            }
                        }) { Text("Guardar / compartir") }
                    }
                }
                message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        }

        // ------------------------------------------------------- Paso 3: mapa
        val bitmap = photo
        if (bitmap != null) {
            placing?.let { address ->
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.primaryContainer
                    ),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        "Toca la foto donde está: ${nameOf(address)}",
                        Modifier.padding(12.dp),
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }

            val image = remember(bitmap) { bitmap.asImageBitmap() }
            BoxWithConstraints(
                Modifier
                    .fillMaxWidth()
                    .aspectRatio(bitmap.width.toFloat() / bitmap.height.toFloat())
            ) {
                val boxWidth = maxWidth
                val boxHeight = maxHeight
                Image(
                    bitmap = image,
                    contentDescription = "Foto del entorno",
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.FillBounds
                )
                // Franjas de incertidumbre de los pines estimados.
                pins.forEach { pin ->
                    if (pin.auto && pin.bandHalfWidth > 0f) {
                        val left = (pin.x - pin.bandHalfWidth).coerceAtLeast(0f)
                        val right = (pin.x + pin.bandHalfWidth).coerceAtMost(1f)
                        Box(
                            Modifier
                                .offset(x = boxWidth * left)
                                .width(boxWidth * (right - left))
                                .fillMaxHeight()
                                .background(Color(viewModel.pinColor(pin)).copy(alpha = 0.22f))
                        )
                    }
                }
                // Capa que recibe el toque para colocar un pin.
                Box(
                    Modifier
                        .fillMaxSize()
                        .pointerInput(Unit) {
                            detectTapGestures { position ->
                                val address = placing
                                if (address != null) {
                                    viewModel.placePin(
                                        address,
                                        position.x / size.width,
                                        position.y / size.height
                                    )
                                    placing = null
                                }
                            }
                        }
                )
                // Pines numerados.
                pins.forEachIndexed { index, pin ->
                    Box(
                        Modifier
                            .offset(x = boxWidth * pin.x - 14.dp, y = boxHeight * pin.y - 14.dp)
                            .size(28.dp)
                            .clip(CircleShape)
                            .background(Color(viewModel.pinColor(pin)))
                            .border(2.dp, Color.White, CircleShape),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "${index + 1}",
                            color = Color.White,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }

            Text("Dispositivos en el mapa", style = MaterialTheme.typography.titleMedium)
            if (pins.isEmpty()) {
                Text(
                    "Aún no hay pines. Usa “Colocar” en la lista de abajo y toca la foto.",
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            pins.forEachIndexed { index, pin ->
                Card(Modifier.fillMaxWidth()) {
                    Row(
                        Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            "${index + 1}. ${viewModel.pinText(pin)}",
                            Modifier.weight(1f),
                            style = MaterialTheme.typography.bodyMedium
                        )
                        TextButton(onClick = { placing = pin.address }) { Text("Mover") }
                        TextButton(onClick = { viewModel.removePin(pin.address) }) { Text("Quitar") }
                    }
                }
            }

            if (outOfFrame.isNotEmpty()) {
                Text("Fuera del encuadre (dirección estimada)", style = MaterialTheme.typography.titleMedium)
                outOfFrame.forEach { item ->
                    val side = if (item.deltaDeg > 0) "a la derecha" else "a la izquierda"
                    Text(
                        "• ${nameOf(item.address)}: unos ${abs(item.deltaDeg).roundToInt()}° $side del centro de la foto",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }

            val unplaced = devices.filter { d -> pins.none { it.address == d.address } }
            if (unplaced.isNotEmpty()) {
                Text("Sin ubicar", style = MaterialTheme.typography.titleMedium)
                unplaced.forEach { d ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "${d.displayName} · ${d.rssi} dBm",
                            Modifier.weight(1f),
                            style = MaterialTheme.typography.bodyMedium
                        )
                        TextButton(onClick = { placing = d.address }) { Text("Colocar") }
                    }
                }
            }

            Text(
                "Los pines “estimado” indican una dirección aproximada, no un lugar exacto ni una " +
                    "persona. La altura del pin no se puede estimar. Corrige a mano lo que observes.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
