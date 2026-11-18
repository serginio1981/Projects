package cl.aula.blescanner

import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScanScreen(viewModel: ScanViewModel) {
    val context = LocalContext.current
    val devices by viewModel.devices.collectAsState()
    val isScanning by viewModel.isScanning.collectAsState()

    var hasPermissions by remember {
        mutableStateOf(
            viewModel.requiredPermissions().all {
                ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
            }
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        hasPermissions = result.values.all { it }
        if (hasPermissions) viewModel.start()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Detector de dispositivos BLE") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer
                )
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = {
                    if (!hasPermissions) {
                        permissionLauncher.launch(viewModel.requiredPermissions())
                    } else {
                        viewModel.toggleScan()
                    }
                },
                icon = { Icon(Icons.Default.Bluetooth, contentDescription = null) },
                text = { Text(if (isScanning) "Detener" else "Escanear") }
            )
        }
    ) { padding ->
        Column(
            Modifier
                .padding(padding)
                .padding(horizontal = 16.dp)
                .fillMaxSize()
        ) {
            InfoBanner()

            if (!viewModel.isBluetoothOn) {
                WarningCard("El Bluetooth está apagado. Actívalo para escanear.")
            }
            if (!hasPermissions) {
                WarningCard("Faltan permisos. Pulsa “Escanear” y acepta los permisos.")
            }

            Spacer(Modifier.height(8.dp))
            Text(
                text = "Dispositivos detectados: ${devices.size}" +
                    if (isScanning) "  ·  escaneando…" else "",
                style = MaterialTheme.typography.labelLarge
            )
            Spacer(Modifier.height(8.dp))

            if (devices.isEmpty()) {
                EmptyState(isScanning)
            } else {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxSize()
                ) {
                    items(devices, key = { it.address }) { DeviceRow(it) }
                }
            }
        }
    }
}

@Composable
private fun InfoBanner() {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer
        ),
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp)
    ) {
        Text(
            "Indicio, no prueba. Un auricular ya emparejado y en uso puede NO " +
                "aparecer (deja de anunciarse). El RSSI estima cercanía de forma " +
                "aproximada, no distancia exacta.",
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(12.dp)
        )
    }
}

@Composable
private fun WarningCard(text: String) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer
        ),
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp)
    ) {
        Row(
            Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Default.Warning, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun EmptyState(isScanning: Boolean) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            if (isScanning) "Buscando dispositivos que se anuncian…"
            else "Pulsa “Escanear” para empezar.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun DeviceRow(device: BleDevice) {
    Card(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    device.displayName,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    device.address,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    "${device.proximity.label}  ·  ${device.rssi} dBm",
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            SignalBars(device.rssi)
        }
    }
}

/** Barras de intensidad de señal a partir del RSSI (indicio relativo). */
@Composable
private fun SignalBars(rssi: Int) {
    val active = when {
        rssi >= -55 -> 4
        rssi >= -70 -> 3
        rssi >= -85 -> 2
        rssi >= -100 -> 1
        else -> 0
    }
    Row(verticalAlignment = Alignment.Bottom) {
        val heights = listOf(10.dp, 16.dp, 22.dp, 28.dp)
        heights.forEachIndexed { index, h ->
            val on = index < active
            Box(
                Modifier
                    .padding(horizontal = 2.dp)
                    .width(6.dp)
                    .height(h)
                    .clip(RoundedCornerShape(2.dp))
                    .background(
                        if (on) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.surfaceVariant
                    )
            )
        }
    }
}
