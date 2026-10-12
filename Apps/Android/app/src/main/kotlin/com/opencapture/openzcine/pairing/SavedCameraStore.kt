package com.opencapture.openzcine.pairing

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.SavedCamerasStore
import com.opencapture.opencine.appkit.StoredString
import com.opencapture.opencine.appkit.stored
import com.opencapture.opencine.nikon.NikonSavedRecordsV0
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraRecords
import com.opencapture.opencine.nikon.SavedCameraTransport

/**
 * This app's saved setups and their one writer. The records stay where every older build reads
 * them (`openzcine.saved-cameras` / `records-json`), in their one codec ([NikonSavedRecordsV0]),
 * and the shared saved-camera document mirrors them ([camerasStore]).
 *
 * Two kinds of write reach the key, both here: the app's own save rules ([savePaired],
 * [saveStreamSettings], [discard], [forget], [replace]), each merged into the shared document at
 * once ([bind]); and the shared page's patch (a rename, a forgotten setup), which [records] reads
 * back, a removed access-point setup taking its Wi-Fi key. Confine it to the main thread.
 */
public class SharedPreferencesSavedCameraStore internal constructor(private val preferences: SharedPreferences) {
    public constructor(context: Context) : this(context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE))

    /** The canonical records, observable by Compose. */
    public var current: List<SavedCameraRecord> by mutableStateOf(records())
        private set

    private var merge: () -> Unit = {}
    private var removeKey: (String) -> Unit = {}

    /** The stored records, read now. */
    public fun records(): List<SavedCameraRecord> = NikonSavedRecordsV0.decode(recordsJson())

    /** The stored records exactly as written (the shared document's legacy source). */
    public fun recordsJson(): String? = preferences.getString(RECORDS_KEY, null)

    /** The shared saved-camera document ([document] holds it) over these records. */
    internal fun camerasStore(document: SharedPreferences): SavedCamerasStore =
        SavedCamerasStore(
            document.stored("document"),
            SavedCamerasStore.Legacy(
                object : StoredString {
                    override fun read(): String? = recordsJson()

                    override fun write(value: String) {
                        persist(value)
                        val before = current
                        current = records()
                        removedAccessPointSsids(before, current).forEach(removeKey)
                    }
                },
                NikonSavedRecordsV0(),
                "records",
            ),
        )

    /** Merges every save into [model]'s saved list at once; [removeKey] drops an access point's Wi-Fi key. */
    internal fun bind(model: CamerasModel, removeKey: (String) -> Unit) {
        merge = model::reloadSaved
        this.removeKey = removeKey
    }

    /** Persists canonical [records] and merges them into the shared document. */
    public fun replace(records: List<SavedCameraRecord>) {
        current = SavedCameraRecords.canonicalized(records)
        persist(NikonSavedRecordsV0.encode(current))
        merge()
    }

    /**
     * Saves a Nikon-confirmed profile ([networkName]: the Wi-Fi a router setup is on, read at save
     * time, the only moment this device is demonstrably on it). Returns the saved setup and the row
     * this save CREATED, null when it refreshed one already there: an abandoned pairing takes back
     * only its own row ([discard]), never a working setup it retried.
     */
    internal fun savePaired(saved: SavedCameraRecord, networkName: String?): Pair<SavedCameraRecord, SavedCameraRecord?> {
        val before = current
        replace(
            SavedCameraRecords.upserting(
                saved.host, saved.cameraName, saved.transport, saved.lastSeenAtEpochMillis, saved.wifiSsid, before, networkName,
            ),
        )
        val record = current.firstOrNull { candidate ->
            candidate.transport == saved.transport &&
                (candidate.host == saved.host || SavedCameraRecords.cameraNamesMatch(candidate.cameraName, saved.cameraName))
        } ?: saved
        return record to SavedCameraRecords.createdSetup(before, current)
    }

    /** The stream settings chosen while connected to [record]'s setup, by stored name; null keeps one. */
    internal fun saveStreamSettings(record: SavedCameraRecord, streamPreset: String?, qualityBias: String?) {
        replace(SavedCameraRecords.updatingStreamSettings(record.host, record.transport, streamPreset, qualityBias, current))
    }

    /** Takes back the row a pairing created and never finished. */
    internal fun discard(created: SavedCameraRecord) {
        replace(SavedCameraRecords.removing(created.host, created.cameraName, current, created.transport))
    }

    /** The app's forget: every setup at [hosts] goes, each access-point setup taking its own key. */
    internal fun forget(hosts: List<String>) {
        var remaining = current
        for (record in current.filter { r -> hosts.any { it.equals(r.host, ignoreCase = true) } }) {
            record.wifiSsid?.takeIf { record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT }?.let(removeKey)
            remaining = SavedCameraRecords.removing(record.host, record.cameraName, remaining)
        }
        replace(remaining)
    }

    private fun persist(value: String) {
        preferences.edit().putString(RECORDS_KEY, value).apply()
    }

    internal companion object {
        const val PREFERENCES_NAME = "openzcine.saved-cameras"
        const val RECORDS_KEY = "records-json"
    }
}
