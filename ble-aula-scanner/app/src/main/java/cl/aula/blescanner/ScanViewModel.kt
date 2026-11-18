package cl.aula.blescanner

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/**
 * Estado de la pantalla: lista ordenada de dispositivos + flag de escaneo.
 */
class ScanViewModel(app: Application) : AndroidViewModel(app) {

    private val scanner = BleScanner(app.applicationContext)

    val isScanning: StateFlow<Boolean> = scanner.isScanning

    /** Dispositivos ordenados por señal (más fuerte primero). */
    val devices: StateFlow<List<BleDevice>> =
        scanner.devices
            .map { map -> map.values.sortedByDescending { it.rssi } }
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val isBluetoothOn: Boolean get() = scanner.isBluetoothOn

    fun requiredPermissions(): Array<String> = BleScanner.requiredPermissions()

    fun toggleScan() {
        if (scanner.isScanning.value) scanner.stop() else scanner.start()
    }

    fun start() = scanner.start()
    fun stop() = scanner.stop()
    fun clear() = scanner.clear()

    override fun onCleared() {
        scanner.stop()
        super.onCleared()
    }
}
