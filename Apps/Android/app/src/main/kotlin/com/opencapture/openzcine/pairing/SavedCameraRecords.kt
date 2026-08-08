package com.opencapture.openzcine.pairing

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.openzcine.settings.LiveViewQualityBias
import com.opencapture.openzcine.settings.LiveViewStreamPreset
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
    PHONE_HOTSPOT("phone-hotspot", "Phone hotspot"),

    /**
     * Both devices on somebody's network — a set router, house Wi-Fi. Like
     * [PHONE_HOTSPOT] the app joins and hosts nothing; the case exists so the
     * operator's Router choice survives persistence instead of collapsing into
     * "hotspot" (the Android twin of iOS's old "Wi-Fi" string collapse).
     */
    INFRASTRUCTURE("infrastructure", "Wi-Fi"),

    /** A physically attached and permissioned USB PTP camera. */
    USB_C("usb-c", "USB-C");

    internal companion object {
        // Unknown/legacy values land on PHONE_HOTSPOT: behaviorally identical for
        // reconnect (passive discovery), and every record saved before
        // INFRASTRUCTURE existed carries the collapsed value anyway. New saves
        // persist the operator's actual choice.
        fun fromPersistedValue(value: String?): SavedCameraTransport =
            entries.firstOrNull { it.persistedValue == value } ?: PHONE_HOTSPOT
    }
}

/**
 * A durable, non-secret camera profile for Android startup and reconnect.
 *
 * Wi-Fi keys deliberately stay in [CameraWifiCredentialStore], which is
 * Keystore-encrypted. USB records store a privacy-safe digest rather than a
 * raw hardware serial. This record only stores the route key and presentation
 * metadata needed to offer a reconnect action after the app relaunches.
 */
public data class SavedCameraRecord(
    /** PTP-IP host or privacy-safe USB host digest, normalized to a stable lower-case key. */
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
    /**
     * Durable saved-profile identity. Legacy records default to their original
     * host, then retain that value when a dynamic hotspot address changes.
     */
    val profileID: String = host,
    /**
     * What the camera is asked to SEND on this setup, chosen by the operator while connected to
     * it. `null` means never chosen here, which is not the same as a value — see
     * [com.opencapture.openzcine.settings.SetupStreamSettings]. Per setup rather than per app
     * because the constraint they answer to belongs to the path: the camera's own access point is
     * a different link from a cable, and one global key meant a bias dropped for the AP followed
     * the operator onto USB-C.
     */
    /**
     * The Wi-Fi network an INFRASTRUCTURE setup lives on, when the operator let us read it.
     *
     * The key that separates a camera's studio router from its home one. Never the address: the
     * cross-host merge below absorbs a DHCP move on purpose, so keying on the address would fork
     * one setup every lease and still not tell two networks apart. Null when unreadable — no
     * permission, not Wi-Fi, or the OS redacted it — and an unnamed network joins whatever router
     * setup is already there, which is what every operator had before this existed.
     */
    val networkName: String? = null,
    /**
     * The operator's own name for THIS setup — "Studio", "Van". Distinct from [customName], which
     * names the CAMERA and titles its whole row: naming one of a body's setups must not rename
     * the body.
     */
    val setupName: String? = null,
    val streamPreset: LiveViewStreamPreset? = null,
    /** The compression grade this setup runs at; `null` means never chosen here. See [streamPreset]. */
    val qualityBias: LiveViewQualityBias? = null,
) {
    /**
     * The chip label for this setup, distinguished when the camera has more than one router.
     *
     * Only routers repeat — the access point is the camera's own network, the hotspot is this
     * phone, the cable is the cable — and two chips both reading "Router" say nothing about which
     * is the studio and which is the one in the bag. The qualifier is whatever the records are
     * KEYED on, so a label can never claim a difference the store does not make: the network's
     * name when we have one, otherwise its subnet. Twin of the core's `pathChipLabel`.
     */
    public fun chipLabel(group: List<SavedCameraRecord>): String {
        setupName?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
        val base = transport.displayName
        if (transport != SavedCameraTransport.INFRASTRUCTURE) return base
        val siblings = group.filter { it.transport == SavedCameraTransport.INFRASTRUCTURE }
        if (siblings.size < 2) return base
        // A NUMBER, not the address: this is a chip row on a phone and four addresses is a swipe
        // to read. Ordered by SUBNET rather than the group's own order, which is sorted by
        // recency — numbering by position would renumber every chip on connecting to another.
        val ordered = siblings.sortedBy { subnetBase(it.host) ?: it.host }
        val index = ordered.indexOfFirst { it.id == id }
        if (index < 0) return base
        return "$base (${index + 1})"
    }

    /**
     * What names this setup's network to a person: its SSID, else its subnet as "192.168.1.x".
     *
     * Not the chip — that stays short — but the honest answer to "which network IS this", for a
     * row subtitle or the placeholder when renaming.
     */
    public val networkQualifier: String?
        get() {
            networkName?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
            return subnetBase(host)?.plus(".x")
        }

    private fun subnetBase(value: String): String? {
        val octets = value.trim().split(".")
        if (octets.size != 4) return null
        if (octets.any { part -> part.toIntOrNull()?.let { it in 0..255 } != true }) return null
        return octets.take(3).joinToString(".")
    }

    /** Stable profile identity. */
    public val id: String
        get() = profileID

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
    /** Every Nikon camera access point hands out this address to itself. */
    public const val CAMERA_ACCESS_POINT_HOST: String = "192.168.1.1"

    /**
     * Pins a camera-AP setup to the access point's fixed address.
     *
     * An access-point setup lives at that address by definition, so an AP stamp on any other host
     * describes a session that was never on the camera's own network. Such a record dials an
     * address the camera does not answer on, and cannot be rescued by a join — the app believes it
     * already holds the AP setup it needs. "+ Add setup -> Camera access point" builds its record
     * by copying the row it was invoked from, which is exactly how a router address gets an AP
     * stamp.
     */
    public fun pinnedToAccessPoint(record: SavedCameraRecord): SavedCameraRecord =
        if (record.host == CAMERA_ACCESS_POINT_HOST) {
            record
        } else {
            record.copy(host = CAMERA_ACCESS_POINT_HOST)
        }

    /**
     * Repairs an access-point record that carries a foreign host, returning the one or two setups
     * it actually described.
     *
     * An AP setup lives at the access point's fixed address by definition, so an AP stamp on some
     * other address describes a session that was never on the camera's own network. Pinning the
     * host alone — which is all this used to do — threw that address away, and with it the router
     * setup it always was. The shared core splits instead (`splittingAccessPoint`), and so does
     * this: the access point keeps the AP's address, the foreign host becomes its own
     * infrastructure row.
     *
     * The two halves must not share a [SavedCameraRecord.profileID]: it is the row's identity, and
     * two rows answering to one id collide in the card list and in reconnect targeting.
     */
    internal fun splitAccessPoint(record: SavedCameraRecord): List<SavedCameraRecord> {
        if (record.host == CAMERA_ACCESS_POINT_HOST) return listOf(record)
        val accessPoint =
            record.copy(
                host = CAMERA_ACCESS_POINT_HOST,
                profileID = CAMERA_ACCESS_POINT_HOST,
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
            )
        // Keeps the host AND the identity it has always answered to; only its claim changes.
        val infrastructure =
            record.copy(
                transport = SavedCameraTransport.INFRASTRUCTURE,
                wifiSsid = null,
                networkName = null,
            )
        return listOf(accessPoint, infrastructure)
    }

    /** Returns normalized, deduplicated records in their original card order. */
    public fun canonicalized(records: List<SavedCameraRecord>): List<SavedCameraRecord> {
        val output = mutableListOf<SavedCameraRecord>()
        for (rawRecord in records) {
            // NORMALIZE first, then repair, then dedupe. The order matters: the repair decides
            // whether a host is foreign by comparing it to the access point's address, and a
            // stored host with stray whitespace only equals that address after trimming. Judging
            // it raw made every untrimmed AP record look foreign and manufactured a router row
            // out of nothing.
            val normalizedRaw = normalized(rawRecord) ?: continue
            val repaired =
                if (normalizedRaw.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                    splitAccessPoint(normalizedRaw)
                } else {
                    listOf(normalizedRaw)
                }
            for (normalized in repaired) {
                val existingIndex =
                    output.indexOfFirst { existing ->
                        // TRANSPORT FIRST, and that is the whole point: a record IS one camera
                        // SETUP, keyed by (camera, path). One body's access-point and router
                        // setups are two rows forever — they routinely share an address, since
                        // every camera-AP Nikon answers on 192.168.1.1, and matching on the
                        // address alone swallowed one into the other (the shared core's
                        // `describesSameSetup`, carried across at last).
                        if (existing.transport != normalized.transport) {
                            false
                        } else if (
                            existing.transport == SavedCameraTransport.INFRASTRUCTURE &&
                            !sameInfrastructureNetwork(existing, normalized)
                        ) {
                            // Within infrastructure the NETWORK is part of the key — see
                            // `sameInfrastructureNetwork`, and the shared core's
                            // `describesSameSetup` it mirrors.
                            false
                        } else if (
                            existing.profileID == normalized.profileID ||
                            existing.host == normalized.host
                        ) {
                            // A shared address only means "same camera" when the names don't
                            // contradict it: the bare host match let a newly paired second body
                            // swallow the first one's record (#293).
                            namesCompatible(existing.cameraName, normalized.cameraName)
                        } else {
                            // Different address, same transport: the cross-host merge that absorbs
                            // a DHCP move within one setup.
                            cameraNamesMatch(existing.cameraName, normalized.cameraName)
                        }
                    }
                if (existingIndex < 0) {
                    output += normalized
                } else {
                    output[existingIndex] = preferred(output[existingIndex], normalized)
                }
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
        /**
         * The network an infrastructure setup is on; null when unreadable, and ignored on every
         * other transport, which has no network to be told apart by.
         */
        networkName: String? = null,
    ): List<SavedCameraRecord> {
        val candidate =
            SavedCameraRecord(
                host = host,
                cameraName = cameraName,
                transport = transport,
                lastSeenAtEpochMillis = lastSeenAtEpochMillis,
                wifiSsid = wifiSsid,
                networkName =
                    networkName.takeIf { transport == SavedCameraTransport.INFRASTRUCTURE },
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

    /**
     * Records the stream settings an operator chose while connected to ONE setup.
     *
     * Keyed by (host, transport), never host alone: one body's access-point and router setups
     * legitimately share an address, and so do two camera-AP Nikons (all of them answer on
     * 192.168.1.1). Matching on the host would write the cable's choice onto the AP's record.
     *
     * A `null` argument leaves that setting untouched rather than clearing it, so a caller that
     * knows only one of the two does not have to read the other back first. Twin of the shared
     * core's `PTPIPSavedCameraRecords.updatingStreamSettings`.
     */
    public fun updatingStreamSettings(
        host: String,
        transport: SavedCameraTransport,
        streamPreset: LiveViewStreamPreset?,
        qualityBias: LiveViewQualityBias?,
        records: List<SavedCameraRecord>,
    ): List<SavedCameraRecord> {
        val normalizedHost = normalizedHost(host) ?: return canonicalized(records)
        return canonicalized(records).map { record ->
            if (record.host != normalizedHost || record.transport != transport) {
                record
            } else {
                record.copy(
                    streamPreset = streamPreset ?: record.streamPreset,
                    qualityBias = qualityBias ?: record.qualityBias,
                )
            }
        }
    }

    /**
     * Names one setup, keyed by (host, transport) like the stream settings — a body's setups share
     * a camera, and renaming the studio Wi-Fi must not rename the one in the van. A blank name
     * clears back to the generated label.
     */
    public fun updatingSetupName(
        host: String,
        transport: SavedCameraTransport,
        setupName: String?,
        records: List<SavedCameraRecord>,
    ): List<SavedCameraRecord> {
        val normalizedHost = normalizedHost(host) ?: return canonicalized(records)
        return canonicalized(records).map { record ->
            if (record.host != normalizedHost || record.transport != transport) {
                record
            } else {
                record.copy(setupName = normalizedTag(setupName))
            }
        }
    }

    /** Removes the profile identified by [host]. Wi-Fi credentials remain private to their store. */
    public fun removing(
        host: String,
        cameraName: String? = null,
        records: List<SavedCameraRecord>,
    ): List<SavedCameraRecord> {
        val normalizedHost = normalizedHost(host) ?: return canonicalized(records)
        return canonicalized(records).filterNot {
            it.host == normalizedHost &&
                // Two bodies legitimately share an address (camera-AP): the name narrows the
                // removal to the one the operator forgot — else forgetting one deletes both.
                (cameraName.isNullOrBlank() || namesCompatible(it.cameraName, cameraName))
        }
    }

    /** True when two camera-assigned names are trustworthy identity matches. */
    /** The phone-hotspot subnet is fixed (172.20.10.x) — the host shape names the network. */
    public fun isPhoneHotspotHost(host: String): Boolean {
        val octets = host.trim().split(".").mapNotNull { it.toIntOrNull() }
        return octets.size == 4 && octets[0] == 172 && octets[1] == 20 && octets[2] == 10
    }

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
            profileID = normalizedProfileID(record.profileID) ?: host,
            cameraName = cameraName,
            wifiSsid = normalizedTag(record.wifiSsid),
            networkName = normalizedTag(record.networkName),
            setupName = normalizedTag(record.setupName),
            customName = normalizedTag(record.customName),
        )
    }

    /**
     * Whether two names could describe one body. Same normalization as [cameraNamesMatch]: a
     * generic or placeholder name carries no identity, so it contradicts nothing — only two
     * *assigned* names that differ prove two different bodies.
     */
    /**
     * Whether two router records describe the same network.
     *
     * Two things can name one, and the good one is usually unavailable: the SSID needs a location
     * permission the operator may never grant, so a home router and a portable one commonly both
     * arrive unnamed — and keying on the name alone merged them, which is the field report this
     * exists for.
     *
     * The SUBNET is always available and is the right shape besides. A different router is a
     * different subnet in practice (192.168.1.x at home, 192.168.129.x on a portable), while a
     * DHCP lease moving within one router stays inside its own — so this separates two setups
     * without forking one every time its address changes. Two routers that both hand out
     * 192.168.1.x still merge; that is genuinely ambiguous, and merging is what happens today.
     */
    private fun sameInfrastructureNetwork(
        lhs: SavedCameraRecord,
        rhs: SavedCameraRecord,
    ): Boolean {
        val lhsName = lhs.networkName
        val rhsName = rhs.networkName
        if (lhsName != null && rhsName != null) return lhsName == rhsName
        return subnetBase(lhs.host) == subnetBase(rhs.host)
    }

    /** The /24 base of an IPv4 address, or null when it is not one (a USB device key). */
    private fun subnetBase(host: String): String? {
        val octets = host.trim().split(".")
        if (octets.size != 4) return null
        if (octets.any { part -> part.toIntOrNull()?.let { it in 0..255 } != true }) return null
        return octets.take(3).joinToString(".")
    }

    private fun namesCompatible(lhs: String, rhs: String): Boolean {
        val left = normalizedAssignedCameraName(lhs) ?: return true
        val right = normalizedAssignedCameraName(rhs) ?: return true
        return left == right
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
            // Load-bearing: every reconnect upserts a record that knows nothing about stream
            // settings, so without this the operator's choice for this setup would survive
            // exactly until the next time they connected to it.
            networkName = preferred.networkName ?: fallback.networkName,
            setupName = preferred.setupName ?: fallback.setupName,
            streamPreset = preferred.streamPreset ?: fallback.streamPreset,
            qualityBias = preferred.qualityBias ?: fallback.qualityBias,
            // The existing card owns reconnect state and any offline-media
            // bucket. A refreshed route must not silently create a new owner.
            profileID = existing.profileID,
        )
    }

    private fun normalizedHost(host: String): String? =
        host.trim().lowercase(Locale.ROOT).takeIf(String::isNotEmpty)

    private fun normalizedProfileID(profileID: String): String? =
        profileID.trim().lowercase(Locale.ROOT).takeIf(String::isNotEmpty)

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

/**
 * Groups per-setup records of the SAME physical body for presentation — the Android twin of the
 * shared core's `SavedCameraPathGroups`. iOS keys on the body serial; Android records carry no
 * serial, so identity is the ASSIGNED camera name (`cameraNamesMatch`): a generic or placeholder
 * name carries no identity and stays a singleton row, exactly like an iOS record that predates
 * the serial stamp. Grouping is presentation-only — records stay one-per-setup on disk.
 */
public object SavedCameraGroups {
    /** Same-camera groups, members most-recently-seen first; group order follows first sight. */
    public fun group(records: List<SavedCameraRecord>): List<List<SavedCameraRecord>> {
        val groups = mutableListOf<MutableList<SavedCameraRecord>>()
        for (record in records) {
            val existing =
                groups.firstOrNull { group ->
                    SavedCameraRecords.cameraNamesMatch(group[0].cameraName, record.cameraName)
                }
            if (existing == null) {
                groups += mutableListOf(record)
            } else {
                existing += record
            }
        }
        return groups.map { group ->
            group.sortedByDescending { it.lastSeenAtEpochMillis ?: Long.MIN_VALUE }
        }
    }

    /**
     * The setup whose record drives the group's row: a discovered/attached one beats an offline
     * one; ties go to the most recently seen (the group's own order).
     */
    public fun activeRecord(
        group: List<SavedCameraRecord>,
        isDiscovered: (SavedCameraRecord) -> Boolean,
    ): SavedCameraRecord = group.firstOrNull(isDiscovered) ?: group.first()
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
                    .put(CUSTOM_NAME_KEY, record.customName)
                    .put(PROFILE_ID_KEY, record.profileID)
                    // Persisted by NAME, not ordinal: the wire ordinals belong to the Swift
                    // bridge and reordering an enum there must not silently re-read every
                    // operator's saved setups as a different setting.
                    .put(NETWORK_NAME_KEY, record.networkName)
                    .put(SETUP_NAME_KEY, record.setupName)
                    .put(STREAM_PRESET_KEY, record.streamPreset?.name)
                    .put(QUALITY_BIAS_KEY, record.qualityBias?.name),
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
            profileID =
                value.optString(PROFILE_ID_KEY).takeIf(String::isNotBlank)
                    ?: host,
            // An unreadable value reads as "never chosen" rather than dropping the whole record:
            // a setting is not worth losing a paired camera over.
            networkName = value.optString(NETWORK_NAME_KEY).takeIf(String::isNotBlank),
            setupName = value.optString(SETUP_NAME_KEY).takeIf(String::isNotBlank),
            streamPreset =
                value.optString(STREAM_PRESET_KEY).takeIf(String::isNotBlank)?.let { name ->
                    LiveViewStreamPreset.entries.firstOrNull { it.name == name }
                },
            qualityBias =
                value.optString(QUALITY_BIAS_KEY).takeIf(String::isNotBlank)?.let { name ->
                    LiveViewQualityBias.entries.firstOrNull { it.name == name }
                },
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
        const val PROFILE_ID_KEY = "profile-id"
        const val NETWORK_NAME_KEY = "network-name"
        const val SETUP_NAME_KEY = "setup-name"
        const val STREAM_PRESET_KEY = "stream-preset"
        const val QUALITY_BIAS_KEY = "quality-bias"
    }
}
