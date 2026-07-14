package com.opencapture.openzcine.pairing

import android.content.Context
import android.content.SharedPreferences
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/**
 * The network route used when this camera was last paired.
 *
 * Camera-access-point records need Android to rejoin the remembered camera
 * network before reconnecting. Phone-hotspot records must never trigger a
 * phone-side Wi-Fi join: the camera joins the phone instead.
 */
public enum class SavedCameraTransport(
    internal val persistedValue: String,
    /** Operator-facing label for the saved connection topology. */
    public val displayName: String,
) {
    /** The phone connects to the camera's own Wi-Fi access point. */
    CAMERA_ACCESS_POINT("camera-access-point", "Camera access point"),

    /** The camera connects to the phone's Wi-Fi hotspot. */
    PHONE_HOTSPOT("phone-hotspot", "Phone hotspot");

    internal companion object {
        fun fromPersistedValue(value: String?): SavedCameraTransport =
            entries.firstOrNull { it.persistedValue == value } ?: PHONE_HOTSPOT
    }
}

/**
 * A durable, non-secret camera profile for Android startup and reconnect.
 *
 * Wi-Fi keys deliberately stay in [CameraWifiCredentialStore], which is
 * Keystore-encrypted. This record only stores the address and presentation
 * metadata needed to offer a reconnect action after the app relaunches.
 */
public data class SavedCameraRecord(
    /** Last reachable PTP-IP host, normalized to a stable lower-case key. */
    val host: String,
    /** Camera-reported name used when no operator nickname exists. */
    val cameraName: String,
    /** The pairing topology that owns reconnection. */
    val transport: SavedCameraTransport,
    /** Epoch milliseconds when this host last completed a connection, if known. */
    val lastSeenAtEpochMillis: Long?,
    /** Camera AP SSID; never a passphrase. Present only for AP records. */
    val wifiSsid: String?,
    /** Optional operator-facing nickname. */
    val customName: String? = null,
) {
    /** Stable profile identity. */
    public val id: String
        get() = host

    /** Operator-facing name, preferring a deliberate nickname. */
    public val displayTitle: String
        get() = customName?.trim()?.takeIf(String::isNotEmpty) ?: cameraName
}

/**
 * Platform-neutral saved-profile policy mirroring the shared Swift core's
 * canonicalization rules. Android storage is platform-owned, while this
 * policy keeps duplicate discovery results and stale hotspot addresses from
 * multiplying visible camera cards.
 */
public object SavedCameraRecords {
    /** Returns normalized, deduplicated records in their original card order. */
    public fun canonicalized(records: List<SavedCameraRecord>): List<SavedCameraRecord> {
        val output = mutableListOf<SavedCameraRecord>()
        for (record in records) {
            val normalized = normalized(record) ?: continue
            val existingIndex =
                output.indexOfFirst { existing ->
                    existing.host == normalized.host ||
                        cameraNamesMatch(existing.cameraName, normalized.cameraName)
                }
            if (existingIndex < 0) {
                output += normalized
            } else {
                output[existingIndex] = preferred(output[existingIndex], normalized)
            }
        }
        return output
    }

    /**
     * Adds or refreshes a profile after a successful connection. Existing
     * nickname and remembered AP SSID metadata survive a dynamic-host refresh.
     */
    public fun upserting(
        host: String,
        cameraName: String,
        transport: SavedCameraTransport,
        lastSeenAtEpochMillis: Long?,
        wifiSsid: String?,
        records: List<SavedCameraRecord>,
    ): List<SavedCameraRecord> {
        val candidate =
            SavedCameraRecord(
                host = host,
                cameraName = cameraName,
                transport = transport,
                lastSeenAtEpochMillis = lastSeenAtEpochMillis,
                wifiSsid = wifiSsid,
            )
        return canonicalized(records + candidate)
    }

    /** Updates the operator nickname for [host], preserving all camera metadata. */
    public fun updatingCustomName(
        host: String,
        customName: String?,
        records: List<SavedCameraRecord>,
    ): List<SavedCameraRecord> {
        val normalizedHost = normalizedHost(host) ?: return canonicalized(records)
        val normalizedName = normalizedTag(customName)
        return canonicalized(records).map { record ->
            if (record.host == normalizedHost) record.copy(customName = normalizedName) else record
        }
    }

    /** Removes the profile identified by [host]. Wi-Fi credentials remain private to their store. */
    public fun removing(host: String, records: List<SavedCameraRecord>): List<SavedCameraRecord> {
        val normalizedHost = normalizedHost(host) ?: return canonicalized(records)
        return canonicalized(records).filterNot { it.host == normalizedHost }
    }

    /** True when two camera-assigned names are trustworthy identity matches. */
    public fun cameraNamesMatch(lhs: String, rhs: String): Boolean {
        val normalizedLhs = normalizedAssignedCameraName(lhs) ?: return false
        val normalizedRhs = normalizedAssignedCameraName(rhs) ?: return false
        return normalizedLhs == normalizedRhs
    }

    private fun normalized(record: SavedCameraRecord): SavedCameraRecord? {
        val host = normalizedHost(record.host) ?: return null
        val cameraName = normalizedCameraName(record.cameraName, host)
        return record.copy(
            host = host,
            cameraName = cameraName,
            wifiSsid = normalizedTag(record.wifiSsid),
            customName = normalizedTag(record.customName),
        )
    }

    private fun preferred(
        existing: SavedCameraRecord,
        candidate: SavedCameraRecord,
    ): SavedCameraRecord {
        val candidateIsNewer =
            when {
                existing.lastSeenAtEpochMillis == null -> candidate.lastSeenAtEpochMillis != null
                candidate.lastSeenAtEpochMillis == null -> false
                else -> candidate.lastSeenAtEpochMillis >= existing.lastSeenAtEpochMillis
            }
        val preferred = if (candidateIsNewer) candidate else existing
        val fallback = if (candidateIsNewer) existing else candidate
        return preferred.copy(
            wifiSsid = preferred.wifiSsid ?: fallback.wifiSsid,
            customName = preferred.customName ?: fallback.customName,
        )
    }

    private fun normalizedHost(host: String): String? =
        host.trim().lowercase(Locale.ROOT).takeIf(String::isNotEmpty)

    private fun normalizedCameraName(cameraName: String, host: String): String =
        cameraName.trim().takeIf(String::isNotEmpty) ?: "Camera $host"

    private fun normalizedTag(value: String?): String? = value?.trim()?.takeIf(String::isNotEmpty)

    private fun normalizedAssignedCameraName(value: String): String? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return null
        val folded = trimmed.lowercase(Locale.ROOT)
        if (
            folded in
                setOf(
                    "camera",
                    "nikon camera",
                    "nikon zr",
                    "nikon corporation zr",
                    "ptp-ip camera",
                )
        ) {
            return null
        }
        if (folded.startsWith("camera ")) return null
        return folded
    }
}

/** Reads and writes saved camera profiles. */
public interface SavedCameraStore {
    /** Returns the canonical saved-profile list. */
    public fun records(): List<SavedCameraRecord>

    /** Replaces the persisted list with canonical [records]. */
    public fun replace(records: List<SavedCameraRecord>)
}

/**
 * App-private durable storage for [SavedCameraRecord] metadata.
 *
 * This is intentionally a tiny platform adapter rather than a second source
 * of connection policy. It tolerates malformed legacy blobs by dropping only
 * the bad entry, so one corrupt profile cannot block first-run pairing.
 */
public class SharedPreferencesSavedCameraStore(context: Context) : SavedCameraStore {
    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun records(): List<SavedCameraRecord> {
        val encoded = preferences.getString(RECORDS_KEY, null) ?: return emptyList()
        val array = runCatching { JSONArray(encoded) }.getOrNull() ?: return emptyList()
        return buildList {
                for (index in 0 until array.length()) {
                    parse(array.optJSONObject(index))?.let(::add)
                }
            }
            .let(SavedCameraRecords::canonicalized)
    }

    override fun replace(records: List<SavedCameraRecord>) {
        val encoded = JSONArray()
        for (record in SavedCameraRecords.canonicalized(records)) {
            encoded.put(
                JSONObject()
                    .put(HOST_KEY, record.host)
                    .put(CAMERA_NAME_KEY, record.cameraName)
                    .put(TRANSPORT_KEY, record.transport.persistedValue)
                    .put(LAST_SEEN_KEY, record.lastSeenAtEpochMillis)
                    .put(WIFI_SSID_KEY, record.wifiSsid)
                    .put(CUSTOM_NAME_KEY, record.customName),
            )
        }
        preferences.edit().putString(RECORDS_KEY, encoded.toString()).apply()
    }

    private fun parse(value: JSONObject?): SavedCameraRecord? {
        value ?: return null
        val host = value.optString(HOST_KEY).trim()
        if (host.isEmpty()) return null
        return SavedCameraRecord(
            host = host,
            cameraName = value.optString(CAMERA_NAME_KEY),
            transport = SavedCameraTransport.fromPersistedValue(value.optString(TRANSPORT_KEY)),
            lastSeenAtEpochMillis =
                if (value.has(LAST_SEEN_KEY) && !value.isNull(LAST_SEEN_KEY)) {
                    value.optLong(LAST_SEEN_KEY)
                } else {
                    null
                },
            wifiSsid = value.optString(WIFI_SSID_KEY).takeIf(String::isNotBlank),
            customName = value.optString(CUSTOM_NAME_KEY).takeIf(String::isNotBlank),
        )
    }

    private companion object {
        const val PREFERENCES_NAME = "openzcine.saved-cameras"
        const val RECORDS_KEY = "records-json"
        const val HOST_KEY = "host"
        const val CAMERA_NAME_KEY = "camera-name"
        const val TRANSPORT_KEY = "transport"
        const val LAST_SEEN_KEY = "last-seen-at"
        const val WIFI_SSID_KEY = "wifi-ssid"
        const val CUSTOM_NAME_KEY = "custom-name"
    }
}
