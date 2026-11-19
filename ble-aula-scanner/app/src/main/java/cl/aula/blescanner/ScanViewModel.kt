package cl.aula.blescanner

import android.app.Application
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

/**
 * Estado compartido por las tres pestañas: lista, radar y mapa sobre foto.
 */
class ScanViewModel(app: Application) : AndroidViewModel(app) {

    private val scanner = BleScanner(app.applicationContext)
    private val heading = HeadingSensor(app.applicationContext)

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

    fun start(): Boolean = scanner.start()
    fun stop() = scanner.stop()
    fun clear() = scanner.clear()

    // ---------------------------------------------------------------- Radar

    private val _selectedAddress = MutableStateFlow<String?>(null)
    val selectedAddress: StateFlow<String?> = _selectedAddress

    /** Últimas lecturas de RSSI del dispositivo elegido en el radar. */
    private val _history = MutableStateFlow<List<Int>>(emptyList())
    val history: StateFlow<List<Int>> = _history

    fun select(address: String?) {
        _selectedAddress.value = address
        _history.value = emptyList()
    }

    // --------------------------------------------------------------- Barrido

    val azimuth: StateFlow<Float?> = heading.azimuth
    val hasHeadingSensor: Boolean get() = heading.isAvailable

    private val sweepSamples = HashMap<String, MutableList<SweepSample>>()
    private val visitedSectors = HashSet<Int>()

    private val _sweepActive = MutableStateFlow(false)
    val sweepActive: StateFlow<Boolean> = _sweepActive

    /** Sectores de 20° ya recorridos (de 18). */
    private val _sweepCoverage = MutableStateFlow(0)
    val sweepCoverage: StateFlow<Int> = _sweepCoverage

    private val _sweepDone = MutableStateFlow(false)
    val sweepDone: StateFlow<Boolean> = _sweepDone

    private val _estimates = MutableStateFlow<Map<String, BearingEstimator.Estimate>>(emptyMap())
    val estimates: StateFlow<Map<String, BearingEstimator.Estimate>> = _estimates

    init {
        scanner.onSample = { address, rssi -> onSample(address, rssi) }
        viewModelScope.launch {
            heading.azimuth.collect { az ->
                if (az != null && _sweepActive.value) {
                    if (visitedSectors.add(BearingEstimator.sectorOf(az))) {
                        _sweepCoverage.value = visitedSectors.size
                    }
                }
            }
        }
    }

    private fun onSample(address: String, rssi: Int) {
        if (address == _selectedAddress.value) {
            _history.value = (_history.value + rssi).takeLast(HISTORY_MAX)
        }
        if (_sweepActive.value) {
            val az = heading.azimuth.value ?: return
            sweepSamples.getOrPut(address) { mutableListOf() }.add(SweepSample(az, rssi))
        }
    }

    fun startHeading() = heading.start()

    fun stopHeading() {
        if (_sweepActive.value) stopSweep()
        heading.stop()
    }

    fun startSweep() {
        sweepSamples.clear()
        visitedSectors.clear()
        _sweepCoverage.value = 0
        _sweepDone.value = false
        _estimates.value = emptyMap()
        heading.start()
        _sweepActive.value = true
    }

    fun stopSweep() {
        _sweepActive.value = false
        val result = HashMap<String, BearingEstimator.Estimate>()
        for ((address, samples) in sweepSamples) {
            val estimate = BearingEstimator.estimate(samples)
            if (estimate != null) result[address] = estimate
        }
        _estimates.value = result
        _sweepDone.value = true
        rebuildAutoPins()
    }

    // ------------------------------------------------------------ Foto y mapa

    private val _photo = MutableStateFlow<Bitmap?>(null)
    val photo: StateFlow<Bitmap?> = _photo

    private val _pins = MutableStateFlow<List<MapPin>>(emptyList())
    val pins: StateFlow<List<MapPin>> = _pins

    private val _outOfFrame = MutableStateFlow<List<OutOfFrame>>(emptyList())
    val outOfFrame: StateFlow<List<OutOfFrame>> = _outOfFrame

    /** Rumbo de la cámara al pulsar "Tomar foto" (null si no hay sensor). */
    private var pendingAzimuth: Float? = null
    private var photoAzimuth: Float? = null

    private fun sharedDir(): File =
        File(getApplication<Application>().cacheDir, "shared").apply { mkdirs() }

    private fun photoFile(): File = File(sharedDir(), "aula.jpg")

    private fun uriFor(file: File): Uri {
        val ctx = getApplication<Application>()
        return FileProvider.getUriForFile(ctx, ctx.packageName + ".fileprovider", file)
    }

    /** Prepara el archivo de destino y recuerda hacia dónde apunta la tablet. */
    fun preparePhotoUri(): Uri {
        pendingAzimuth = heading.azimuth.value
        val file = photoFile()
        if (file.exists()) file.delete()
        return uriFor(file)
    }

    fun onPhotoResult(ok: Boolean) {
        if (!ok) return
        viewModelScope.launch {
            val bitmap = withContext(Dispatchers.IO) {
                PhotoUtils.loadScaled(photoFile(), MAX_PHOTO_SIDE)
            }
            if (bitmap != null) {
                photoAzimuth = pendingAzimuth
                _pins.value = emptyList()
                _photo.value = bitmap
                rebuildAutoPins()
            }
        }
    }

    /** Recalcula los pines estimados; los colocados a mano se respetan. */
    private fun rebuildAutoPins() {
        val bitmap = _photo.value ?: return
        val manual = _pins.value.filter { !it.auto }
        val auto = ArrayList<MapPin>()
        val out = ArrayList<OutOfFrame>()
        val az = photoAzimuth
        if (az != null) {
            val fov = if (bitmap.width >= bitmap.height) FOV_LANDSCAPE_DEG else FOV_PORTRAIT_DEG
            for ((address, estimate) in _estimates.value) {
                if (manual.any { it.address == address }) continue
                val x = BearingEstimator.photoX(estimate.bearingDeg, az, fov)
                if (x != null) {
                    auto += MapPin(
                        address = address, x = x, y = 0.5f, auto = true,
                        bandHalfWidth = BearingEstimator.UNCERTAINTY_DEG / fov,
                    )
                } else {
                    out += OutOfFrame(address, BearingEstimator.angleDiff(estimate.bearingDeg, az))
                }
            }
        }
        _pins.value = manual + auto
        _outOfFrame.value = out
    }

    fun placePin(address: String, x: Float, y: Float) {
        val pin = MapPin(address, x.coerceIn(0f, 1f), y.coerceIn(0f, 1f), auto = false)
        _pins.value = _pins.value.filter { it.address != address } + pin
        _outOfFrame.value = _outOfFrame.value.filter { it.address != address }
    }

    fun removePin(address: String) {
        _pins.value = _pins.value.filter { it.address != address }
    }

    fun pinText(pin: MapPin): String {
        val device = devices.value.firstOrNull { it.address == pin.address }
        val name = device?.displayName ?: pin.address
        val rssi = if (device != null) " · ${device.rssi} dBm" else ""
        val kind = if (pin.auto) "estimado ±30°" else "manual"
        return "$name$rssi · $kind"
    }

    fun pinColor(pin: MapPin): Int {
        val device = devices.value.firstOrNull { it.address == pin.address }
        return PhotoUtils.colorFor(device?.rssi ?: -100)
    }

    /** Genera la imagen anotada y devuelve un Intent para compartirla/guardarla. */
    fun buildShareIntent(): Intent? {
        val bitmap = _photo.value ?: return null
        val labels = _pins.value.mapIndexed { index, pin ->
            PinLabel(index + 1, pin, pinText(pin), pinColor(pin))
        }
        val annotated = PhotoUtils.renderAnnotated(bitmap, labels)
        val file = File(sharedDir(), "mapa-ble.jpg")
        FileOutputStream(file).use { annotated.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        val uri = uriFor(file)
        return Intent(Intent.ACTION_SEND).apply {
            type = "image/jpeg"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("mapa-ble", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    override fun onCleared() {
        scanner.onSample = null
        scanner.stop()
        heading.stop()
        super.onCleared()
    }

    companion object {
        const val HISTORY_MAX = 60
        const val MAX_PHOTO_SIDE = 1600
        /** Campo de visión horizontal aproximado de una cámara trasera típica. */
        const val FOV_LANDSCAPE_DEG = 65f
        const val FOV_PORTRAIT_DEG = 50f
    }
}
