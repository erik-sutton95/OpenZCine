package com.opencapture.openzcine

import java.awt.image.BufferedImage
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BrandResourcesTest {
    private val repositoryRoot =
        Path.of(
            requireNotNull(System.getProperty("openzcine.repositoryRoot")) {
                "Gradle must expose the OpenZCine repository root to brand resource tests"
            },
        )

    @Test
    fun launcherResourcesCannotFallBackToTheHandDrawnVector() {
        val canonicalIcon =
            repositoryRoot.resolve(
                "ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
            )
        assertEquals(CANONICAL_APP_ICON_SHA256, canonicalIcon.sha256())
        assertSize(canonicalIcon, width = 1_024, height = 1_024)

        val resources = repositoryRoot.resolve("Apps/Android/app/src/main/res")
        val adaptiveForeground =
            resources.resolve("drawable-xxxhdpi/openzcine_launcher_foreground.png")
        assertSize(adaptiveForeground, width = 432, height = 432)
        assertEquals(ADAPTIVE_FOREGROUND_SHA256, adaptiveForeground.sha256())

        val oldVector = resources.resolve("drawable/ic_openzcine_launcher_foreground.xml")
        assertFalse(Files.exists(oldVector), "The Android-specific launcher redraw must stay deleted")

        listOf("ic_launcher.xml", "ic_launcher_round.xml").forEach { fileName ->
            val adaptiveConfig =
                resources.resolve("mipmap-anydpi-v26/$fileName").readText()
            assertTrue(
                adaptiveConfig.contains("@drawable/openzcine_launcher_foreground"),
                "$fileName must use the raster derived from the canonical AppIcon",
            )
            assertFalse(adaptiveConfig.contains("ic_openzcine_launcher_foreground"))
        }

        LEGACY_LAUNCHERS.forEach { (density, expected) ->
            val normal = resources.resolve("mipmap-$density/ic_launcher.png")
            val round = resources.resolve("mipmap-$density/ic_launcher_round.png")
            assertSize(normal, width = expected.size, height = expected.size)
            assertSize(round, width = expected.size, height = expected.size)
            assertEquals(expected.sha256, normal.sha256())
            assertContentEquals(
                Files.readAllBytes(normal),
                Files.readAllBytes(round),
                "Normal and round fallbacks must come from the same AppIcon transform",
            )
        }
    }

    @Test
    fun splashUsesSolidSystemHoldAndFullBleedComposeLogo() {
        val canonicalLogo =
            repositoryRoot.resolve("ios/Runner/Assets.xcassets/AppLogo.imageset/AppLogo.png")
        assertEquals(CANONICAL_APP_LOGO_SHA256, canonicalLogo.sha256())
        assertSize(canonicalLogo, width = 512, height = 512)

        // Compose splash marks: edge-to-edge AppLogo so RoundedCornerShape
        // actually rounds the logo (not the transparent padding of the old
        // system splash icon).
        val composeLogo =
            repositoryRoot.resolve(
                "Apps/Android/app/src/main/res/drawable-xxxhdpi/openzcine_app_logo.png",
            )
        assertContentEquals(
            Files.readAllBytes(canonicalLogo),
            Files.readAllBytes(composeLogo),
            "Compose splash logo must remain the byte-exact canonical AppLogo",
        )

        // System SplashScreen is solid-only (transparent icon) — no second logo.
        val theme =
            repositoryRoot.resolve("Apps/Android/app/src/main/res/values/themes.xml").readText()
        assertTrue(theme.contains("parent=\"Theme.SplashScreen\""))
        assertTrue(theme.contains("@drawable/openzcine_splash_empty"))
        assertTrue(theme.contains("postSplashScreenTheme"))
        assertTrue(
            !theme.contains("@drawable/openzcine_splash_icon"),
            "System splash must not flash the padded square logo",
        )
    }

    @Test
    fun wearResourcesStayDerivedFromTheCanonicalIconAndLogo() {
        val canonicalIcon =
            repositoryRoot.resolve(
                "ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
            )
        val canonicalLogo =
            repositoryRoot.resolve("ios/Runner/Assets.xcassets/AppLogo.imageset/AppLogo.png")
        assertEquals(CANONICAL_APP_ICON_SHA256, canonicalIcon.sha256())
        assertEquals(CANONICAL_APP_LOGO_SHA256, canonicalLogo.sha256())

        val resources = repositoryRoot.resolve("Apps/Android/wear/src/main/res")
        WEAR_LAUNCHERS.forEach { (density, expected) ->
            val launcher = resources.resolve("mipmap-$density/ic_launcher.png")
            assertSize(launcher, width = expected.size, height = expected.size)
            assertEquals(expected.sha256, launcher.sha256())
        }
        WEAR_LOGOS.forEach { (density, expected) ->
            val logo = resources.resolve("drawable-$density/openzcine_app_logo.png")
            assertSize(logo, width = expected.size, height = expected.size)
            assertEquals(expected.sha256, logo.sha256())
        }
        assertContentEquals(
            Files.readAllBytes(canonicalLogo),
            Files.readAllBytes(resources.resolve("drawable-xxxhdpi/openzcine_app_logo.png")),
            "The full-density Wear launch logo must remain the byte-exact canonical AppLogo",
        )
    }

    private fun assertCenteredPixelsMatch(sourcePath: Path, canvasPath: Path) {
        val source = sourcePath.readImage()
        val canvas = canvasPath.readImage()
        val offsetX = (canvas.width - source.width) / 2
        val offsetY = (canvas.height - source.height) / 2

        for (y in 0 until source.height) {
            for (x in 0 until source.width) {
                assertEquals(
                    source.getRGB(x, y),
                    canvas.getRGB(offsetX + x, offsetY + y),
                    "AppLogo pixel changed at ($x, $y)",
                )
            }
        }
        assertEquals(0, canvas.getRGB(0, 0) ushr 24, "Splash padding must stay transparent")
    }

    private fun assertSize(path: Path, width: Int, height: Int) {
        val image = path.readImage()
        assertEquals(width, image.width, "$path width")
        assertEquals(height, image.height, "$path height")
    }

    private fun Path.readImage(): BufferedImage =
        requireNotNull(ImageIO.read(toFile())) { "$this must remain a readable raster image" }

    private fun Path.readText(): String =
        String(Files.readAllBytes(this), Charsets.UTF_8)

    private fun Path.sha256(): String =
        MessageDigest.getInstance("SHA-256")
            .digest(Files.readAllBytes(this))
            .joinToString(separator = "") { byte ->
                Integer.toHexString(byte.toInt() and 0xFF).padStart(2, '0')
            }

    private companion object {
        data class ExpectedLauncher(val size: Int, val sha256: String)

        const val CANONICAL_APP_ICON_SHA256 =
            "3ef97441266fe12fd57fa0613845127be80eff6c476abcc557bcfcc5a17a12b0"
        const val CANONICAL_APP_LOGO_SHA256 =
            "8d5ca89f9eecdd3162b9788b6fb938eac4396fd5078f0c193953c5c5bfd51e01"
        const val ADAPTIVE_FOREGROUND_SHA256 =
            "7d7bf13a0da1e415b4a4983de39f1fece940989beff030caf9ff14b4b8087667"

        val LEGACY_LAUNCHERS =
            mapOf(
                "mdpi" to
                    ExpectedLauncher(
                        size = 48,
                        sha256 =
                            "cd0f1e09a67de0883af446785fc982b59436740892ddba3b9492fdb5f3f7f146",
                    ),
                "hdpi" to
                    ExpectedLauncher(
                        size = 72,
                        sha256 =
                            "bb13714205988447e2a0a03c0544f2a9bd39bf30c2513f51600a446eeb83d46c",
                    ),
                "xhdpi" to
                    ExpectedLauncher(
                        size = 96,
                        sha256 =
                            "f442fe31a17bfb0d28fb44d666e62599f5fa8e283b6ffae61934fcc13b1d9bf4",
                    ),
                "xxhdpi" to
                    ExpectedLauncher(
                        size = 144,
                        sha256 =
                            "425473c9b2e25bedee107ebc1d3bca7047028bf0c9649e3b7e44a395a4c0690b",
                    ),
                "xxxhdpi" to
                    ExpectedLauncher(
                        size = 192,
                        sha256 =
                            "0040688f9f686d5d96a8a0a09196cf86893a97d5dd5c39bcd6440c6a43e2205c",
                    ),
            )

        val WEAR_LAUNCHERS =
            mapOf(
                "mdpi" to
                    ExpectedLauncher(
                        size = 48,
                        sha256 =
                            "cd0f1e09a67de0883af446785fc982b59436740892ddba3b9492fdb5f3f7f146",
                    ),
                "hdpi" to
                    ExpectedLauncher(
                        size = 72,
                        sha256 =
                            "bb13714205988447e2a0a03c0544f2a9bd39bf30c2513f51600a446eeb83d46c",
                    ),
                "xhdpi" to
                    ExpectedLauncher(
                        size = 96,
                        sha256 =
                            "f442fe31a17bfb0d28fb44d666e62599f5fa8e283b6ffae61934fcc13b1d9bf4",
                    ),
                "xxhdpi" to
                    ExpectedLauncher(
                        size = 144,
                        sha256 =
                            "425473c9b2e25bedee107ebc1d3bca7047028bf0c9649e3b7e44a395a4c0690b",
                    ),
                "xxxhdpi" to
                    ExpectedLauncher(
                        size = 192,
                        sha256 =
                            "0040688f9f686d5d96a8a0a09196cf86893a97d5dd5c39bcd6440c6a43e2205c",
                    ),
            )

        val WEAR_LOGOS =
            mapOf(
                "mdpi" to
                    ExpectedLauncher(
                        size = 128,
                        sha256 =
                            "75131eb01714717765465f26876e19f0503416eb3ba38a77d53dc66504f28134",
                    ),
                "hdpi" to
                    ExpectedLauncher(
                        size = 192,
                        sha256 =
                            "0040688f9f686d5d96a8a0a09196cf86893a97d5dd5c39bcd6440c6a43e2205c",
                    ),
                "xhdpi" to
                    ExpectedLauncher(
                        size = 256,
                        sha256 =
                            "14bbedf2fb944444b65d2adb0f96c606d7f3cbd177915b73e158e76ff4f5178c",
                    ),
                "xxhdpi" to
                    ExpectedLauncher(
                        size = 384,
                        sha256 =
                            "10689347eed6311d21e98be4ba30fe5669576ea260a5bcea5c1218eca8e88a37",
                    ),
                "xxxhdpi" to
                    ExpectedLauncher(
                        size = 512,
                        sha256 = CANONICAL_APP_LOGO_SHA256,
                    ),
            )
    }
}
