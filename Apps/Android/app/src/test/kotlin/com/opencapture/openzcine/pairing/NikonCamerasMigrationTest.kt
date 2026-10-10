package com.opencapture.openzcine.pairing

import com.opencapture.opencine.appkit.AppIntegration
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.nikon.NikonConnectPort
import com.opencapture.opencine.nikon.NikonConnectRequest
import com.opencapture.opencine.nikon.NikonConnection
import com.opencapture.opencine.nikon.NikonConnectionPhase
import com.opencapture.opencine.nikon.NikonIntegration
import com.opencapture.opencine.nikon.NikonSighting
import com.opencapture.openzcine.TestSharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The saved setups across the upgrade to the shared document (SHELL-02 design 4), wired as
 * MainActivity wires them: the document in "openzcine.cameras", this app's records left where
 * every older build reads them and mirrored, Wi-Fi keys never touched by the migration.
 */
class NikonCamerasMigrationTest {
    private val at = 1_759_307_200_250L

    /** Body A on its access point and on Studio Wi-Fi (renamed "A-cam"); body B on the phone's hotspot. */
    private fun appRecords(): List<SavedCameraRecord> {
        var records = emptyList<SavedCameraRecord>()
        records = SavedCameraRecords.upserting(
            "192.168.1.1", "ZR_3001234", SavedCameraTransport.CAMERA_ACCESS_POINT, at, "NIKON_ZR_3001234", records,
        )
        records = SavedCameraRecords.upserting(
            "192.168.50.23", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, at + 200_000, null, records,
            networkName = "Studio",
        )
        for (host in listOf("192.168.1.1", "192.168.50.23")) {
            records = SavedCameraRecords.updatingCustomName(host, "A-cam", records)
        }
        return SavedCameraRecords.upserting(
            "192.168.43.20", "ZR_4005678", SavedCameraTransport.PHONE_HOTSPOT, at + 300_000, null, records,
        )
    }

    /** One install: its preferences, the app's own store and the keys the app dropped. */
    private class Phone {
        val document = TestSharedPreferences()
        val records = TestSharedPreferences()
        val wifi = TestSharedPreferences()
        val app = SharedPreferencesSavedCameraStore(records)
        val removedKeys = mutableListOf<String>()
        var appList: List<SavedCameraRecord> = emptyList()

        fun store() = nikonCamerasStore(document, records) { appList = recordsAfterSharedEdit(appList, app, removedKeys::add) }

        fun documentJson(): String? = document.getString("document", null)

        fun legacyJson(): String? = records.getString(SharedPreferencesSavedCameraStore.RECORDS_KEY, null)
    }

    /** The app's port as far as saved cameras go: forget runs the app's own forget rule. */
    private class Port(val phone: Phone) : NikonConnectPort {
        override val sightings = MutableStateFlow<List<NikonSighting>>(emptyList())
        override val phase = MutableStateFlow<Pair<NikonConnectionPhase, String?>?>(null)

        override fun savedRecords(): String? = phone.legacyJson()

        override fun startDiscovery(mode: DiscoveryMode) = Unit

        override fun stopDiscovery() = Unit

        override suspend fun connect(request: NikonConnectRequest): NikonConnection = error("not in these tests")

        override fun cancel() = Unit

        override fun forget(hosts: List<String>) {
            phone.appList = recordsForgetting(hosts, phone.appList, phone.removedKeys::add)
            phone.app.replace(phone.appList)
        }
    }

    private fun Phone.model(scope: kotlinx.coroutines.CoroutineScope): CamerasModel {
        appList = app.records()
        return CamerasModel(listOf(AppIntegration(NikonIntegration(Port(this)))), store(), scope)
            .also { model -> app.onReplaced = model::reloadSaved }
    }

    @Test
    fun `upgrade reads every camera and setup and leaves the records and keys alone`() {
        val phone = Phone()
        phone.app.replace(appRecords())
        phone.wifi.edit().putString("ssid:NIKON_ZR_3001234", "sealed").apply()
        val legacy = phone.legacyJson()

        val cameras = phone.store().also { it.load() }.cameras

        assertEquals(legacy, phone.legacyJson(), "the read never rewrites what older builds read")
        assertNotNull(phone.documentJson())
        assertEquals(2, cameras.size)
        val a = cameras.single { it.name == "A-cam" }
        assertEquals(
            setOf(RouteKind.CAMERA_ACCESS_POINT to "NIKON_ZR_3001234", RouteKind.INFRASTRUCTURE_NETWORK to "Studio"),
            a.routes.map { it.kind to it.network }.toSet(),
        )
        val b = cameras.single { it.name == null }
        assertEquals("ZR_4005678", b.advertisedName)
        assertEquals(listOf(RouteKind.PHONE_HOTSPOT), b.routes.map { it.kind })
        assertEquals(mapOf("ssid:NIKON_ZR_3001234" to "sealed"), phone.wifi.all.toMap())
        assertTrue(phone.removedKeys.isEmpty())
    }

    @Test
    fun `the migration is idempotent`() {
        val phone = Phone()
        phone.app.replace(appRecords())
        phone.store().load()
        val document = phone.documentJson()
        val legacy = phone.legacyJson()
        repeat(2) { phone.store().load() }
        assertEquals(document, phone.documentJson())
        assertEquals(legacy, phone.legacyJson())
    }

    @Test
    fun `an app write is merged at once and keeps the route ids`() = runTest {
        val phone = Phone()
        phone.app.replace(appRecords())
        val model = phone.model(backgroundScope)
        val routes = model.state.value.saved.flatMap { it.routes }.associate { it.extras["host"] to it.id }

        // The app's own connect saves a USB-C setup for body B.
        phone.appList = SavedCameraRecords.upserting(
            "usb:3f9a2c", "ZR_4005678", SavedCameraTransport.USB_C, at + 400_000, null, phone.appList,
        )
        phone.app.replace(phone.appList)

        val b = model.state.value.saved.single { it.advertisedName == "ZR_4005678" }
        assertEquals(setOf(RouteKind.PHONE_HOTSPOT, RouteKind.USB), b.routes.map { it.kind }.toSet())
        val after = model.state.value.saved.flatMap { it.routes }.associate { it.extras["host"] to it.id }
        assertEquals(routes, after.filterKeys { it in routes })
    }

    @Test
    fun `a rename and a forget on the shared page reach the app records and keys`() = runTest {
        val phone = Phone()
        phone.app.replace(appRecords())
        val model = phone.model(backgroundScope)
        val a = model.state.value.saved.single { it.name == "A-cam" }
        val b = model.state.value.saved.single { it.advertisedName == "ZR_4005678" }

        model.rename(b.id, "B-cam")
        assertEquals("B-cam", phone.app.records().single { it.cameraName == "ZR_4005678" }.customName)
        assertEquals(phone.app.records(), phone.appList, "the app reads the patch back")

        // Forgetting one setup (the access point) takes its key; the camera keeps its Wi-Fi.
        model.forgetRoute(a.routes.single { it.kind == RouteKind.CAMERA_ACCESS_POINT }.id, a.id)
        assertEquals(listOf("NIKON_ZR_3001234"), phone.removedKeys)
        assertEquals(
            listOf(SavedCameraTransport.INFRASTRUCTURE),
            phone.app.records().filter { it.cameraName == "ZR_3001234" }.map { it.transport },
        )

        // Forgetting the camera runs the app's forget.
        model.forget(a.id)
        assertTrue(phone.app.records().none { it.cameraName == "ZR_3001234" })
        assertEquals(listOf("B-cam"), model.state.value.saved.map { it.name })
        assertEquals(listOf("B-cam"), phone.store().also { it.load() }.cameras.map { it.name })
    }

    @Test
    fun `edits made by an older build after the upgrade merge back`() = runTest {
        val phone = Phone()
        phone.app.replace(appRecords())
        val routes = phone.store().also { it.load() }.cameras.flatMap { it.routes }.associate { it.extras["host"] to it.id }

        // The older build (no document): renames body B, forgets body A, adds body C.
        var old = phone.app.records()
        old = SavedCameraRecords.updatingCustomName("192.168.43.20", "B-cam", old)
        old = SavedCameraRecords.removing("192.168.1.1", "ZR_3001234", old)
        old = SavedCameraRecords.removing("192.168.50.23", "ZR_3001234", old)
        old = SavedCameraRecords.upserting("10.0.0.5", "Z_8_5009999", SavedCameraTransport.INFRASTRUCTURE, at + 500_000, null, old)
        phone.app.replace(old)

        val cameras = phone.store().also { it.load() }.cameras
        assertEquals(setOf("B-cam", null), cameras.map { it.name }.toSet())
        assertTrue(cameras.any { it.advertisedName == "Z_8_5009999" })
        assertEquals(routes["192.168.43.20"], cameras.single { it.name == "B-cam" }.routes.single().id, "route ids survive")
    }

    /** One record per setup: the app drops one setup of a body that keeps another (OpenCine be2da87). */
    @Test
    fun `a setup removed by an older build or the app leaves the document`() = runTest {
        val phone = Phone()
        phone.app.replace(appRecords())
        phone.store().load()
        phone.app.replace(SavedCameraRecords.removing("192.168.1.1", "ZR_3001234", phone.app.records()))

        val a = phone.store().also { it.load() }.cameras.single { it.name == "A-cam" }
        assertEquals(listOf(RouteKind.INFRASTRUCTURE_NETWORK), a.routes.map { it.kind })
    }

    @Test
    fun `a single setup rename and clear reach the legacy store`() = runTest {
        val phone = Phone()
        phone.app.replace(appRecords())
        val model = phone.model(backgroundScope)
        val camera = model.state.value.saved.single { it.routes.size == 1 }
        val route = camera.routes.single()
        val original = phone.app.records()

        model.renameRoute(route.id, camera.id, "  Shoulder camera  ")

        assertEquals("Shoulder camera", model.state.value.saved.single { it.id == camera.id }.routes.single().title)
        val expected = SavedCameraRecords.updatingSetupName(
            "192.168.43.20", SavedCameraTransport.PHONE_HOTSPOT, "Shoulder camera", original,
        )
        assertEquals(expected, phone.app.records(), "only this setup changes, including on older builds")
        assertEquals(expected, phone.appList)

        model.renameRoute(route.id, camera.id, " \n ")

        assertNull(model.state.value.saved.single { it.id == camera.id }.routes.single().title)
        assertEquals(original, phone.app.records())
        assertEquals(route.id, phone.store().also { it.load() }.cameras.single { it.id == camera.id }.routes.single().id)
        assertTrue(phone.removedKeys.isEmpty())
    }

    @Test
    fun `old build setup rename and clear survive repeated upgrades`() = runTest {
        val phone = Phone()
        phone.app.replace(appRecords())
        phone.wifi.edit().putString("ssid:NIKON_ZR_3001234", "sealed").apply()
        val initial = phone.store().also { it.load() }.cameras
        val routeIDs = initial.flatMap { it.routes }.map { it.id }

        for (name in listOf("Old build setup", null)) {
            phone.app.replace(SavedCameraRecords.updatingSetupName(
                "192.168.50.23", SavedCameraTransport.INFRASTRUCTURE, name, phone.app.records(),
            ))
            val legacy = phone.legacyJson()
            val reloaded = phone.store().also { it.load() }.cameras
            val camera = reloaded.single { it.name == "A-cam" }
            assertEquals(name, camera.routes.single { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }.title)
            assertEquals(routeIDs, reloaded.flatMap { it.routes }.map { it.id })
            assertEquals(legacy, phone.legacyJson())
            assertEquals(reloaded, phone.store().also { it.load() }.cameras, "repeat launch keeps the old build's clear")
        }
        assertEquals(mapOf("ssid:NIKON_ZR_3001234" to "sealed"), phone.wifi.all.toMap())
        assertTrue(phone.removedKeys.isEmpty())
    }

    @Test
    fun `a record the app cannot read is kept`() = runTest {
        val phone = Phone()
        phone.app.replace(appRecords())
        val withBad = phone.legacyJson()!!.removeSuffix("]") + ",\"not a record\"]"
        phone.records.edit().putString(SharedPreferencesSavedCameraStore.RECORDS_KEY, withBad).apply()

        val model = phone.model(backgroundScope)
        assertEquals(2, model.state.value.saved.size)
        model.rename(model.state.value.saved.single { it.name == "A-cam" }.id, "A-prime")

        assertTrue(phone.legacyJson()!!.contains("\"not a record\""), "an undecodable record is never overwritten")
        assertTrue(phone.app.records().filter { it.cameraName == "ZR_3001234" }.all { it.customName == "A-prime" })
    }

    @Test
    fun `missing setup kinds offer exactly what the camera lacks`() {
        fun record(host: String, transport: SavedCameraTransport) =
            SavedCameraRecord(host = host, cameraName = "ZR_6002199", transport = transport, lastSeenAtEpochMillis = 1L, wifiSsid = null)
        val group = listOf(record("10.99.0.20", SavedCameraTransport.INFRASTRUCTURE), record("usb:zr", SavedCameraTransport.USB_C))
        // Router stays on offer even though this camera already has one: a body can live on a
        // studio network, a home one and a location's, and each is its own setup keyed by the
        // network's name. Every other kind is singular by definition.
        assertEquals(
            listOf(SavedCameraTransport.CAMERA_ACCESS_POINT, SavedCameraTransport.INFRASTRUCTURE, SavedCameraTransport.PHONE_HOTSPOT),
            missingSetupKinds(group),
        )
        assertEquals(
            listOf(SavedCameraTransport.INFRASTRUCTURE),
            missingSetupKinds(
                group + listOf(record("192.168.1.1", SavedCameraTransport.CAMERA_ACCESS_POINT), record("172.20.10.8", SavedCameraTransport.PHONE_HOTSPOT)),
            ),
        )
    }
}
