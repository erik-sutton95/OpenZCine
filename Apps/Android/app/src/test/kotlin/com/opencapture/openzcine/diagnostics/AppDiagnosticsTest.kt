package com.opencapture.openzcine.diagnostics

import com.opencapture.openzcine.BuildConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The holder wires this app's host values into OpenCine's reporting and its Sentry adapter. */
class AppDiagnosticsTest {
    @Test
    fun holderWiresThisAppsNamesRedactionAndSourceIdentity() {
        val host = AppDiagnostics.host
        assertEquals("OpenZCine", host.product)
        // The release naming Pocket and Insta use: <package>@<version>+<build>, dist = build.
        assertEquals("com.opencapture.openzcine@0.2.0+200", host.release("0.2.0", "200"))
        assertEquals(
            "com.opencapture.openzcine@${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}",
            host.currentRelease,
        )
        assertEquals(if (BuildConfig.DEBUG) "development" else "production", host.environment)
        assertEquals(BuildConfig.SENTRY_DSN_ANDROID, host.reportingDsn)
        assertEquals("openzcine-android", host.reportingClient)
        // Nikon keeps no network readable (A6-10); iOS redacts the same table identically.
        for (ssid in listOf("NIKON_Z_8_12345678", "OsmoPocket3-A1B2", "EdgeRouter-5G", "CafeWiFi")) {
            assertEquals("ssid=<redacted>", host.redact("ssid=$ssid"))
        }
        // The build stamps its source identity (A6-07).
        assertEquals(BuildConfig.SOURCE_REVISION, host.sourceRevision)
        assertNotEquals("unknown", host.sourceRevision)
        assertTrue(BuildConfig.BUILD_IDENTITY.startsWith("android-"))
        assertEquals(BuildConfig.BUILD_IDENTITY, AppDiagnostics.origin.currentBuildIdentity())
        assertSame(AppDiagnostics.gate, AppDiagnostics.reporting.gate)
        assertSame(AppDiagnostics.consent, AppDiagnostics.reporting.consent)
        assertSame(AppDiagnostics.origin, AppDiagnostics.reporting.origin)
    }
}
