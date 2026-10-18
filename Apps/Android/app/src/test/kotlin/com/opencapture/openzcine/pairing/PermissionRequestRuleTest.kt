package com.opencapture.openzcine.pairing

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Every runtime permission this app asks for goes through OpenCine's permission gate
 * ([rememberPermissionGate]), which remembers a denial across process death and sends the next ask
 * to Settings once Android stops showing the dialog (A4-21: three app routers kept denial in
 * memory or in ad hoc counters, so after process death a tap launched a dialog Android suppressed).
 */
class PermissionRequestRuleTest {
    @Test
    fun noScreenLaunchesItsOwnPermissionRequest() {
        val sources = Path.of(requireNotNull(System.getProperty("openzcine.repositoryRoot")))
            .resolve("Apps/Android/app/src/main/kotlin")
        val askers = Files.walk(sources).use { paths ->
            paths.filter { path ->
                path.name.endsWith(".kt") && path.readText().let {
                    "ActivityResultContracts.RequestPermission" in it ||
                        "RequestMultiplePermissions" in it ||
                        "shouldShowRequestPermissionRationale" in it
                }
            }.map(Path::name).sorted().toList()
        }
        assertEquals(emptyList(), askers)
    }
}
