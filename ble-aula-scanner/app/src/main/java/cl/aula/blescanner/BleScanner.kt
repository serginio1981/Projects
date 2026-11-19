package cl.aula.blescanner

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * Envuelve el escaneo BLE pasivo del sistema y expone el conjunto de dispositivos
 * vistos como un StateFlow observable desde Compose.
 *
 * LIMITACIÓN IMPORTANTE: un auricular/dispositivo que YA está emparejado y
 * conectado a menudo deja de emitir anuncios (advertising) y NO aparecerá aquí.
 * El escaneo pasivo detecta dispositivos que se están anunciando, no todo lo
 * que hay encendido en la sala. Es un indicio, no una prueba.
 */
class BleScanner(private val context: Context) {

    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private var leScanner: BluetoothLeScanner? = null

    private val _devices = MutableStateFlow<Map<String, BleDevice>>(emptyMap())
    val devices: StateFlow<Map<String, BleDevice>> = _devices

    private val _isScanning = MutableStateFlow(false)
    val isScanning: StateFlow<Boolean> = _isScanning

    val isBluetoothOn: Boolean
        get() = adapter?.isEnabled == true

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result ?: return
            val device = result.device ?: return
            val now = System.currentTimeMillis()
            val address = device.address ?: return
            val name = safeDeviceName(result)

            _devices.update { current ->
                val existing = current[address]
                val entry = BleDevice(
                    address = address,
                    name = name ?: existing?.name,
                    rssi = result.rssi,
                    firstSeen = existing?.firstSeen ?: now,
                    lastSeen = now,
                )
                current + (address to entry)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            _isScanning.value = false
        }
    }

    /** Devuelve el nombre solo si tenemos permiso para leerlo; si no, null. */
    @SuppressLint("MissingPermission")
    private fun safeDeviceName(result: ScanResult): String? {
        val canRead = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        } else true
        return try {
            if (canRead) result.scanRecord?.deviceName ?: result.device?.name else null
        } catch (_: SecurityException) {
            null
        }
    }

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (_isScanning.value) return true
        if (!hasScanPermission()) return false
        val scanner = adapter?.bluetoothLeScanner ?: return false
        leScanner = scanner

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        return try {
            // filtros = null -> todos los dispositivos que se anuncian.
            scanner.startScan(null, settings, scanCallback)
            _isScanning.value = true
            true
        } catch (_: SecurityException) {
            false
        }
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        if (!_isScanning.value) return
        try {
            leScanner?.stopScan(scanCallback)
        } catch (_: SecurityException) {
            // Ignorado: si perdimos el permiso, el escaneo ya se detuvo.
        }
        _isScanning.value = false
    }

    fun clear() {
        _devices.value = emptyMap()
    }

    private fun hasScanPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    companion object {
        /** Permisos en tiempo de ejecución según la versión de Android. */
        fun requiredPermissions(): Array<String> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            } else {
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }
    }
}
